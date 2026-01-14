-- Coordinates user-facing execution commands (files, cells, selections) so
-- init.lua only wires dependencies together. This controller owns cursor math,
-- buffer validation, helper bootstrapping, and debug session transitions.

local ExecutionController = {}
ExecutionController.__index = ExecutionController

local CELL_PATTERN = [[^# %%\+]]
local CELL_RE = vim.regex(CELL_PATTERN)

-- Find the start of the current cell by scanning upwards for a cell marker.
local function get_start_line_cell(api, idx_seed)
	local lines = api.nvim_buf_get_lines(0, 0, idx_seed, false)
	for idx = #lines, 1, -1 do
		if CELL_RE:match_str(lines[idx]) then
			return idx
		end
	end
	return 1
end

-- Find the end of the current cell by scanning downwards for a cell marker.
local function get_stop_line_cell(api, idx_offset)
	local n_lines = api.nvim_buf_line_count(0)
	local lines = api.nvim_buf_get_lines(0, idx_offset - 1, n_lines, false)
	for idx, line in ipairs(lines) do
		if CELL_RE:match_str(line) then
			return idx + idx_offset - 1, true
		end
	end
	return n_lines, false
end

-- Count how many cell markers appear before the given line.
local function count_cells_before(api, line_start)
	local upper = math.max((line_start or 1) - 1, 0)
	local pre_lines = api.nvim_buf_get_lines(0, 0, upper, false)
	local idx = 0
	for _, ln in ipairs(pre_lines) do
		if CELL_RE:match_str(ln) then
			idx = idx + 1
		end
	end
	return idx
end

---Create a new ExecutionController instance.
---@param opts table
---@return table
function ExecutionController.new(opts)
	local self = setmetatable({}, ExecutionController)
	self.state = assert(opts.state, "execution controller: state is required")
	self.api = assert(opts.api, "execution controller: api is required")
	self.fn = assert(opts.fn, "execution controller: fn is required")
	self.utils = assert(opts.utils, "execution controller: utils dependency is required")
	self.breakpoints = assert(opts.breakpoints, "execution controller: breakpoints dependency is required")
	self.warn_user = opts.warn_user or function() end
	self.resolve_exec_cwd = assert(opts.resolve_exec_cwd, "execution controller: resolve_exec_cwd is required")
	self.with_terminal = assert(opts.with_terminal, "execution controller: with_terminal is required")
	self.term_send = assert(opts.term_send, "execution controller: term_send is required")
	self.clear_debug_state = assert(opts.clear_debug_state, "execution controller: clear_debug_state is required")
	self.ensure_runcell_helpers = assert(opts.ensure_runcell_helpers, "execution controller: ensure_runcell_helpers is required")
	self.exec_with_pipeline = assert(opts.exec_with_pipeline, "execution controller: exec_with_pipeline is required")
	self.sync_debugfile_imports = assert(opts.sync_debugfile_imports, "execution controller: sync_debugfile_imports is required")
	self.sync_var_filters = assert(opts.sync_var_filters, "execution controller: sync_var_filters is required")
	self.is_open = assert(opts.is_open, "execution controller: is_open checker is required")
	self.send_helpers = opts.send_helpers or function() end
	return self
end

---Get an option value from the current config table.
---@param key string
---@return any
function ExecutionController:_config_value(key)
	local cfg = self.state.config or {}
	return cfg[key]
end

---Ensure a file is saved before running a command that needs it.
---@param path string
---@param action_label string
---@return boolean
function ExecutionController:_ensure_saved_file(path, action_label)
	if vim.bo.modified or not self.utils.file_exists(path) then
		self.warn_user(string.format("ipybridge: file must be saved before %s can run", action_label))
		return false
	end
	return true
end

---Check if a buffer is a valid, loaded Python file buffer.
---@param bufnr integer
---@return boolean
function ExecutionController:_is_python_buffer(bufnr)
	if not (bufnr and self.api.nvim_buf_is_valid(bufnr)) then
		return false
	end
	if not self.api.nvim_buf_is_loaded(bufnr) then
		return false
	end
	local bt = (vim.bo[bufnr] and vim.bo[bufnr].buftype) or ""
	if bt ~= "" then
		return false
	end
	local ft = (vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
	if ft ~= "python" then
		return false
	end
	local name = self.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return false
	end
	return true
end

---Resolve the current or most recent Python buffer.
---@return integer|nil
function ExecutionController:_resolve_python_buffer()
	local current = self.api.nvim_get_current_buf()
	if self:_is_python_buffer(current) then
		return current
	end
	local last = self.state._last_python_buf
	if self:_is_python_buffer(last) then
		return last
	end
	for _, buf in ipairs(self.api.nvim_list_bufs()) do
		if self:_is_python_buffer(buf) then
			return buf
		end
	end
	return nil
end

---Resolve a buffer's absolute path.
---@param bufnr integer
---@return string|nil
function ExecutionController:_buffer_path(bufnr)
	local name = self.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return nil
	end
	local abs = self.fn.fnamemodify(name, ":p")
	if not abs or abs == "" then
		return nil
	end
	return abs
end

---Find a window that is displaying the buffer.
---@param bufnr integer
---@return integer|nil
function ExecutionController:_find_window_for_buf(bufnr)
	for _, win in ipairs(self.api.nvim_list_wins()) do
		if self.api.nvim_win_is_valid(win) and self.api.nvim_win_get_buf(win) == bufnr then
			return win
		end
	end
	return nil
end

---Save the target buffer if the relevant config flag allows it.
---@param option_key string
---@param bufnr integer|nil
function ExecutionController:_save_buffer_if_requested(option_key, bufnr)
	if self:_config_value(option_key) == false then
		return
	end
	local target = bufnr or 0
	if target ~= 0 and not self.api.nvim_buf_is_valid(target) then
		return
	end
	if not (vim.bo[target] and vim.bo[target].modified) then
		return
	end
	if target == 0 then
		pcall(vim.cmd, "write")
		return
	end
	local win = self:_find_window_for_buf(target)
	if win and self.api.nvim_win_is_valid(win) then
		self.api.nvim_win_call(win, function()
			pcall(vim.cmd, "write")
		end)
		return
	end
	self.api.nvim_buf_call(target, function()
		pcall(vim.cmd, "write")
	end)
end

---Move the cursor to the target line, clamped to the buffer size.
---@param target integer
function ExecutionController:_move_cursor_to_line(target)
	local total = self.api.nvim_buf_line_count(0)
	local idx_line = math.min(target, total)
	self.api.nvim_win_set_cursor(0, { idx_line, 0 })
end

---Mark the session as active for debugging and refresh filters if needed.
function ExecutionController:_activate_debug_session()
	local st = self.state
	local was_debug = st._debug_active
	st._debug_generation = (st._debug_generation or 0) + 1
	if st._debug_generation > 0 then
		st._debug_generation_complete = st._debug_generation - 1
	end
	st._debug_active = true
	st._debug_status_active = true
	if not was_debug then
		self.sync_var_filters()
	end
end

---Reset the debug baseline in the kernel.
---@param on_success function
---@param context_label string|nil
function ExecutionController:_reset_debug_baseline(on_success, context_label)
	self.exec_with_pipeline("_myipy_reset_debug_baseline()", {
		require_helpers = true,
		on_success = on_success,
		on_error = function(reason)
			local r = tostring(reason or "")
			local label = context_label or "debug action"
			self.warn_user(
				string.format(
					"ipybridge: failed to reset debug baseline via ZMQ for %s (%s)",
					label,
					r ~= "" and r or "unknown"
				)
			)
		end,
	})
end

---Send a range of lines into the REPL using the configured mode.
---@param line_start integer
---@param line_stop integer
function ExecutionController:send_lines(line_start, line_stop)
	local lines = self.api.nvim_buf_get_lines(0, line_start, line_stop, false)
	if not lines or #lines == 0 then
		return
	end
	if not self.state._debug_active then
		self.clear_debug_state()
	end
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		local mode = tostring(self:_config_value("multiline_send_mode") or "exec")
		if mode == "paste" then
			local payload = self.utils.paste_block(lines)
			self.term_send(payload)
		else
			local block = table.concat(lines, "\n")
			local payload = self.utils.send_exec_block(block)
			self.term_send(payload)
		end
	end)
end

---Run the currently selected visual lines.
function ExecutionController:run_lines()
	local line_start0, line_end_excl0 = self.utils.selection_line_range()
	if not line_start0 then
		return
	end
	self:send_lines(line_start0, line_end_excl0)
end

---Run the current line and advance the cursor by one line.
function ExecutionController:run_line()
	local n_lines = self.api.nvim_buf_line_count(0)
	local line = self.api.nvim_get_current_line()
	local idx_line_cursor = self.api.nvim_win_get_cursor(0)[1]
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		self.term_send(line)
		if idx_line_cursor < n_lines then
			self.api.nvim_win_set_cursor(0, { idx_line_cursor + 1, 0 })
		end
		if not self.state._debug_active then
			self.clear_debug_state()
		end
	end)
end

---Send a raw command line to the REPL.
---@param cmd string
function ExecutionController:run_cmd(cmd)
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		self.term_send(cmd)
	end)
end

---Run the current Python file through the runcell helpers.
function ExecutionController:run_file()
	local bufnr = self:_resolve_python_buffer()
	if not bufnr then
		self.warn_user("ipybridge: unable to resolve file path for runfile; run aborted")
		return
	end
	local abs_path = self:_buffer_path(bufnr)
	if not (abs_path and #abs_path > 0) then
		self.warn_user("ipybridge: unable to resolve file path for runfile; run aborted")
		return
	end
	self:_save_buffer_if_requested("runfile_save_before_run", bufnr)
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		local cwd_arg = self.resolve_exec_cwd(abs_path)
		local function send_runfile()
			local safe = self.utils.py_quote_single(abs_path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = self.utils.py_quote_single(cwd_arg)
				self.term_send(string.format("runfile('%s','%s')", safe, safecwd))
			else
				self.term_send(string.format("runfile('%s')", safe))
			end
			if not self.state._debug_active then
				self.clear_debug_state()
			end
		end
		self.ensure_runcell_helpers(function(ok)
			if not ok then
				self.warn_user("ipybridge: failed to prepare runfile helpers; run aborted")
				return
			end
			send_runfile()
		end)
	end)
end

---Debug the current Python file using debugfile helpers.
function ExecutionController:debug_file()
	local bufnr = self:_resolve_python_buffer()
	if not bufnr then
		self.warn_user("ipybridge: unable to resolve file path for debugfile; run aborted")
		return
	end
	local abs_path = self:_buffer_path(bufnr)
	if not (abs_path and #abs_path > 0) then
		self.warn_user("ipybridge: unable to resolve file path for debugfile; run aborted")
		return
	end
	local win = self:_find_window_for_buf(bufnr)
	if win and self.api.nvim_win_is_valid(win) then
		self.state._debug_window = win
	else
		self.state._debug_window = nil
	end
	self:_save_buffer_if_requested("debugfile_save_before_run", bufnr)
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		local function start_debugfile()
			self.send_helpers()
			self.ensure_runcell_helpers(function(ok)
				if not ok then
					self.warn_user("ipybridge: debug helpers unavailable; debugfile aborted")
					return
				end
				self.breakpoints.push()
				local cwd_arg = self.resolve_exec_cwd(abs_path)
				local safe = self.utils.py_quote_single(abs_path)
				local safecwd = nil
				if cwd_arg and #cwd_arg > 0 then
					safecwd = self.utils.py_quote_single(cwd_arg)
				end
				-- Guard against double-dispatch if the baseline reset callback runs twice.
				local dispatched = false
				local function dispatch_debugfile()
					if dispatched then
						return
					end
					dispatched = true
					if safecwd then
						self.term_send(string.format("debugfile('%s','%s')", safe, safecwd))
					else
						self.term_send(string.format("debugfile('%s')", safe))
					end
					self:_activate_debug_session()
				end
				self:_reset_debug_baseline(dispatch_debugfile, "debugfile")
			end)
		end
		self.sync_debugfile_imports(function(ok)
			if not ok and vim.trim(self.state.config.debugfile_auto_imports or "") ~= "" then
				self.warn_user("ipybridge: debugfile auto imports unavailable; continuing without them")
			end
			start_debugfile()
		end)
	end)
end

---Run the current cell delimited by Jupyter-style markers.
function ExecutionController:run_cell()
	local idx_line_cursor = self.api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(self.api, idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(self.api, idx_line_cursor + 1)
	local path = self.fn.expand("%:p")
	if not (path and #path > 0) then
		self.warn_user("ipybridge: unable to resolve file path for runcell; run aborted")
		return
	end
	self:_save_buffer_if_requested("runcell_save_before_run")
	if not self:_ensure_saved_file(path, "runcell") then
		return
	end
	local idx = count_cells_before(self.api, line_start)
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		local cwd_arg = self.resolve_exec_cwd(path)
		self.ensure_runcell_helpers(function(ok)
			if not ok then
				self.warn_user("ipybridge: failed to prepare runcell helpers; run aborted")
				return
			end
			local safe = self.utils.py_quote_single(path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = self.utils.py_quote_single(cwd_arg)
				self.term_send(string.format("runcell(%d, '%s', '%s')", idx, safe, safecwd))
			else
				self.term_send(string.format("runcell(%d, '%s')", idx, safe))
			end
			self.clear_debug_state()
			if has_next_cell then
				self:_move_cursor_to_line(math.min(line_stop + 1, self.api.nvim_buf_line_count(0)))
			end
		end)
	end)
end

---Debug the current cell delimited by Jupyter-style markers.
function ExecutionController:debug_cell()
	local abs_path = self.fn.expand("%:p")
	if not (abs_path and #abs_path > 0) then
		self.warn_user("ipybridge: unable to resolve file path for debugcell; run aborted")
		return
	end
	local idx_line_cursor = self.api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(self.api, idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(self.api, idx_line_cursor + 1)
	self:_save_buffer_if_requested("debugcell_save_before_run")
	if not self:_ensure_saved_file(abs_path, "debugcell") then
		return
	end
	local win = self.api.nvim_get_current_win()
	if win and self.api.nvim_win_is_valid(win) then
		self.state._debug_window = win
	else
		self.state._debug_window = nil
	end
	local idx = count_cells_before(self.api, line_start)
	self.with_terminal(true, function()
		if not self.is_open() then
			return
		end
		self.send_helpers()
		self.ensure_runcell_helpers(function(ok)
			if not ok then
				self.warn_user("ipybridge: debug helpers unavailable; debugcell aborted")
				return
			end
			self.breakpoints.push()
			local cwd_arg = self.resolve_exec_cwd(abs_path)
			local safe = self.utils.py_quote_single(abs_path)
			local safecwd = nil
			if cwd_arg and #cwd_arg > 0 then
				safecwd = self.utils.py_quote_single(cwd_arg)
			end
			-- Guard against double-dispatch if the baseline reset callback runs twice.
			local dispatched = false
			local function dispatch_debugcell()
				if dispatched then
					return
				end
				dispatched = true
				if safecwd then
					self.term_send(string.format("debugcell(%d, '%s','%s')", idx, safe, safecwd))
				else
					self.term_send(string.format("debugcell(%d, '%s')", idx, safe))
				end
				self:_activate_debug_session()
				if has_next_cell then
					self:_move_cursor_to_line(math.min(line_stop + 1, self.api.nvim_buf_line_count(0)))
				end
			end
			self:_reset_debug_baseline(dispatch_debugcell, "debugcell")
		end)
	end)
end

---Move the cursor to the start of the previous cell.
function ExecutionController:up_cell()
	local idx_line_cursor = self.api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(self.api, idx_line_cursor - 2)
	self:_move_cursor_to_line(math.min(line_start + 1, self.api.nvim_buf_line_count(0)))
end

---Move the cursor to the start of the next cell.
function ExecutionController:down_cell()
	local idx_line_cursor = self.api.nvim_win_get_cursor(0)[1]
	local line_stop, has_next_cell = get_stop_line_cell(self.api, idx_line_cursor + 1)
	if has_next_cell then
		self:_move_cursor_to_line(math.min(line_stop + 1, self.api.nvim_buf_line_count(0)))
	end
end

return ExecutionController
