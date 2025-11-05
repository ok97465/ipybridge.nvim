-- This plugin requires Neovim 0.11 or newer.
-- Fail fast on older versions to prevent undefined behavior.
if vim.fn.has("nvim-0.11") ~= 1 then
	error("ipybridge.nvim requires Neovim 0.11 or newer")
end

local vim = vim
local api = vim.api
local fn = vim.fn
local term_helper = require("ipybridge.term_ipy")
local dispatch = require("ipybridge.dispatch")
-- Refactored internal modules (utilities, keymaps, kernel manager)
local utils = require("ipybridge.utils")
local keymaps = require("ipybridge.keymaps")
local kernel = require("ipybridge.kernel")
local py_module = require("ipybridge.py_module")
local debug_vars = require("ipybridge.debug.vars")
local breakpoints = require("ipybridge.debug.breakpoints")
local cmp_bridge = require("ipybridge.cmp_bridge")
local debug_completion = require("ipybridge.debug.completion")
local debug_sign = require("ipybridge.debug.sign")
local Executor = require("ipybridge.executor")
local SessionManager = require("ipybridge.session")
local inspect = vim.inspect
local fs = vim.fs
local uv = vim.uv
local is_windows = uv.os_uname().sysname == "Windows_NT"
-- Use LF newline by default; Windows-specific cases are handled explicitly.
local newline = "\n"
local prompt_buffer = ""

local queue_exec_request
local after_helpers
local exec_with_pipeline
local session_manager

-- Emit user-facing warnings on the main loop to avoid tearing.
local function warn_user(message)
	if not message then
		return
	end
	vim.schedule(function()
		vim.notify(tostring(message), vim.log.levels.WARN)
	end)
end

local function normalize_newlines(text)
	if type(text) ~= "string" then
		return text
	end
	if not is_windows then
		return text
	end
	-- Collapse CRLF so downstream logic can reason about a single kind of newline.
	return text:gsub("\r\n", "\n")
end

local function has_escape_byte(text)
	if type(text) ~= "string" then
		return false
	end
	return text:find("\27", 1, true) ~= nil
end

local function should_use_windows_multiline(text, opts)
	if not is_windows then
		return false
	end
	if type(text) ~= "string" or text == "" then
		return false
	end
	opts = type(opts) == "table" and opts or {}
	if opts.raw or opts.mode == "ipdb" then
		return false
	end
	if opts.force_multiline then
		return true
	end
	if has_escape_byte(text) then
		return false
	end
	local _, newline_count = text:gsub("\n", "")
	if newline_count == 0 then
		return false
	end
	if newline_count > 1 then
		return true
	end
	-- Single LF that is not the terminal newline means we have embedded content.
	return text:sub(-1) ~= "\n"
end

local function apply_windows_multiline(text)
	if type(text) ~= "string" or text == "" then
		return text
	end
	local has_final_lf = text:sub(-1) == "\n"
	local body = has_final_lf and text:sub(1, -2) or text
	if body ~= "" then
		body = body:gsub("\n", "\r")
	end
	if has_final_lf then
		return body .. "\n"
	end
	return body
end

-- Core state for the plugin. Comments are in English; see README for usage.
local M = {
	term_instance = nil,
	_helpers_sent = false,
	_helpers_path = nil,
	_helpers_pending = false,
	_runcell_sent = false,
	_runcell_path = nil,
	_debug_active = false,
	_debug_status_active = false,
	_debug_generation = 0,
	_debug_generation_complete = 0,
	_latest_vars = {},
	_debug_locals_snapshot = nil,
	_debug_globals_snapshot = nil,
	_debug_scope = "globals",
	_debug_window = nil,
	_last_filters_signature = nil,
	_pending_exec = {},
	_helpers_waiters = {},
	-- Guard against double-cleanup when the user types `exit` inside IPython.
	_term_exit_expected = false,
}

local function trigger_cmp_completion()
	if not M._debug_active then
		return false
	end
	if not cmp_bridge.ensure() then
		return false
	end
	return cmp_bridge.trigger()
end

-- Always try to surface nvim-cmp when TAB is pressed inside the terminal.
local function handle_terminal_tab()
	if trigger_cmp_completion() then
		return
	end
	local literal_tab = api.nvim_replace_termcodes("<Tab>", true, false, true)
	api.nvim_feedkeys(literal_tab, "tn", false)
end

---Reset debugger bookkeeping so UI can return to normal execution state.
---@param opts? table
local function clear_debug_state(opts)
	opts = type(opts) == "table" and opts or {}
	local restore_signcolumn = opts.restore_signcolumn
	if restore_signcolumn == nil then
		restore_signcolumn = true
	end
	if type(M._debug_generation) == "number" and M._debug_generation > 0 then
		M._debug_generation_complete = M._debug_generation
	end
	M._debug_active = false
	M._debug_status_active = false
	M._debug_window = nil
	debug_sign.clear({ restore_signcolumn = restore_signcolumn })
	prompt_buffer = ""
end

local function strip_ansi_sequences(text)
	if type(text) ~= "string" then
		return ""
	end
	return text:gsub("\27%[[%d;?]*[%a~]", "")
end

local function observe_terminal_chunk(chunk)
	if type(chunk) ~= "string" or chunk == "" then
		return
	end
	local cleaned = strip_ansi_sequences(chunk):gsub("\r", "")
	if cleaned == "" then
		return
	end
	prompt_buffer = prompt_buffer .. cleaned
	local idx = prompt_buffer:match(".*\n()")
	if idx then
		prompt_buffer = prompt_buffer:sub(idx)
	end
	local trimmed = prompt_buffer:gsub("^%s+", "")
	if trimmed:match("^In %[[0-9]+%]:%s*$") then
		if M._debug_active then
			clear_debug_state()
		end
		prompt_buffer = ""
	elseif #prompt_buffer > 256 then
		prompt_buffer = prompt_buffer:sub(-256)
	end
end

-- Ensure the IPython terminal exists before executing the provided callback.
local function with_terminal(go_back, cb)
	if type(cb) ~= "function" then
		return
	end
	if M.is_open() then
		cb(true)
		return
	end
	M.open(go_back, function(ok)
		if ok then
			cb(true)
		end
	end)
end

local function term_send(payload, opts)
	if not M.term_instance then
		return
	end
	if type(payload) ~= "string" then
		return
	end
	local options = {}
	if type(opts) == "table" then
		for k, v in pairs(opts) do
			options[k] = v
		end
	end
	if is_windows and not options.mode and not options.raw and M._debug_active then
		options.mode = "ipdb"
	end
	if payload == "" and not options.append_newline then
		return
	end
	local text = payload
	if options.append_newline then
		text = text .. newline
	end
	text = normalize_newlines(text)
	if is_windows then
		if options.mode == "ipdb" then
			local sanitized = text:gsub("[\r\n]+$", "")
			if sanitized == "" then
				return
			end
			M.term_instance:send(sanitized .. "\r")
			return
		end
		if should_use_windows_multiline(text, options) then
			text = apply_windows_multiline(text)
		end
	end
	M.term_instance:send(text)
end

local function term_send_line(payload)
	term_send(payload or "", { append_newline = true })
end

local function term_send_debug(payload)
	if is_windows then
		term_send(payload, { mode = "ipdb" })
	else
		term_send(payload, { append_newline = true })
	end
end

-- Cell markers must be exactly: start of line '#', one space, then at least '%%'.
-- Examples matched: '# %%', '# %% Import'. Examples NOT matched: '  # %%', '#%%'.
local CELL_PATTERN = [[^# %%\+]]
local CELL_RE = vim.regex(CELL_PATTERN)

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end
	local abs = fn.fnamemodify(path, ":p")
	if not abs or abs == "" then
		return nil
	end
	return abs:gsub("\\", "/")
end

local function resolve_exec_cwd(path)
	local mode = M.config.exec_cwd_mode or "pwd"
	if mode == "file" then
		if path and #path > 0 then
			return fn.fnamemodify(path, ":p:h")
		end
		return nil
	end
	if mode == "pwd" then
		return fn.getcwd()
	end
	return nil
end

local queue_exec_request -- forward declaration for deferred ZMQ exec
local after_helpers -- forward declaration for helper gating
local exec_with_pipeline -- forward declaration for unified execution path

---Toggle a breakpoint at the current cursor line for the active Python buffer.
function M.toggle_breakpoint()
	breakpoints.toggle_current_line()
end

---Prompt for a conditional breakpoint at the current cursor line.
function M.set_conditional_breakpoint()
	breakpoints.set_conditional_current_line()
end

M.config = {
	profile_name = "vim",
	startup_script = "import_in_console.py",
	sleep_ms_after_open = 5000,
	set_default_keymaps = true,
	viewer_max_rows = 30,
	viewer_max_cols = 20,
	var_repr_limit = 120,
	python_cmd = "python3",
	-- Matplotlib backend for the interactive console; applied via `%matplotlib`.
	-- Recommended values include 'qt', 'inline', 'macosx', 'tk', or 'agg'.
	matplotlib_backend = nil,
	-- Save buffer before calling runcell to ensure the file content is current
	runcell_save_before_run = true,
	-- Save buffer before calling runfile to ensure the file content is current
	runfile_save_before_run = true,
	-- Save buffer before calling debugfile to ensure the file content is current
	debugfile_save_before_run = true,
	-- Working directory mode for executing run_cell/run_file: 'file' | 'pwd' | 'none'
	--  - 'file': cd to the current file's directory before executing
	--  - 'pwd' : cd to Neovim's current working directory before executing
	--  - 'none': do not change directory
	exec_cwd_mode = "pwd",
	-- Console prompt/color options
	-- Use a rich prompt (colors, toolbar) by default; set true to simplify.
	simple_prompt = false,
	-- Optional color scheme for ZMQTerminalInteractiveShell (e.g., 'Linux', 'LightBG', 'NoColor').
	ipython_colors = "Linux",
	-- Variable explorer: hide variables by exact name or type name (supports '*' suffix as prefix wildcard)
	hidden_var_names = { "pi", "newaxis", "MODULE_B64" },
	hidden_type_names = { "ZMQInteractiveShell", "Axes", "Figure", "AxesSubplot" },
	-- ZMQ backend debug logs (Python client prints to stderr)
	zmq_debug = false,
	-- IPython autoreload: 1, 2, or 'disable' (default 2)
	--  - 1: Reload modules imported with %aimport
	--  - 2: Reload all modules (except those excluded)
	--  - 'disable': Do not configure autoreload
	autoreload = 2,
	-- How to send multi-line selections/cells to IPython.
	-- 'exec'  : send as hex-encoded Python and exec() it (robust, default)
	-- 'paste' : send as plain text using bracketed paste so the console shows
	--           the code exactly as if it was typed (Spyder-like echo).
	multiline_send_mode = "paste",
	-- Extra terminal-mode keymaps applied after the IPython console buffer is created.
	terminal_keymaps = nil,
}

local function get_start_line_cell(idx_seed)
	local lines = api.nvim_buf_get_lines(0, 0, idx_seed, false)
	for idx, line in vim.iter(lines):enumerate():rev() do
		local s, e = CELL_RE:match_str(line)
		if s ~= nil then
			return idx
		end
	end
	return 1
end

-- Return the last line index of the current cell
-- and whether there is a next cell following it.
---@param idx_offset number
---@return number, boolean
local function get_stop_line_cell(idx_offset)
	local n_lines = api.nvim_buf_line_count(0)
	local lines = api.nvim_buf_get_lines(0, idx_offset - 1, n_lines, false)
	for idx, line in vim.iter(lines):enumerate() do
		local s, e = CELL_RE:match_str(line)
		if s ~= nil then
			return idx + idx_offset - 1, true
		end
	end
	return n_lines, false
end

M.setup = function(config)
	if config ~= nil then
		vim.validate({
			profile_name = { config.profile_name, "s", true },
			startup_script = { config.startup_script, "s", true },
			sleep_ms_after_open = { config.sleep_ms_after_open, "n", true },
			set_default_keymaps = { config.set_default_keymaps, "b", true },
			viewer_max_rows = { config.viewer_max_rows, "n", true },
			viewer_max_cols = { config.viewer_max_cols, "n", true },
			var_repr_limit = { config.var_repr_limit, "n", true },
			python_cmd = { config.python_cmd, "s", true },
			debugfile_save_before_run = { config.debugfile_save_before_run, "b", true },
			terminal_keymaps = { config.terminal_keymaps, "function", true },
		})
	end
	M.config = vim.tbl_deep_extend("force", M.config, config or {})

	breakpoints.ensure_support()

	if M.config.set_default_keymaps then
		M.apply_default_keymaps()
		-- Also apply to any already-open Python buffers
		for _, b in ipairs(api.nvim_list_bufs()) do
			if api.nvim_buf_is_loaded(b) then
				local ft = (vim.bo[b] and vim.bo[b].filetype) or ""
				if ft == "python" then
					M.apply_buffer_keymaps(b)
					breakpoints.refresh_signs(b)
				end
			end
		end
	end

	if M.is_open() then
		M._sync_var_filters()
	end
end

---Apply a set of sensible default keymaps.
M.apply_default_keymaps = function()
	keymaps.apply_defaults()
end

---Apply buffer-local keymaps for Python files.
---@param bufnr integer
M.apply_buffer_keymaps = function(bufnr)
	keymaps.apply_buffer(bufnr)
end

---Return whether the IPython terminal is currently open.
---@return boolean
M.is_open = function()
	return M.term_instance ~= nil and type(M.term_instance.job_id) == "number" and M.term_instance.job_id > 0
end

local executor = Executor.new(M, {
	fn = fn,
	term_send = term_send,
	ensure_conn_file = function(cb)
		M._ensure_conn_file(cb)
	end,
	is_open = function()
		return M.is_open()
	end,
})

-- IPython terminal exit handler invoked by term_ipy.lua callback.
-- Distinguish between plugin-initiated shutdown (jobstop) and in-REPL `exit`.
function M._handle_term_exit()
	if M._term_exit_expected then
		M._term_exit_expected = false
		M.term_instance = nil
		return
	end
	M.term_instance = nil
	M.close()
end

---Open the IPython terminal split.
---@param go_back boolean|nil # if true, jump back to previous window after init
M.open = function(go_back, cb)
	if not session_manager then
		error("ipybridge: session manager not initialised")
	end
	session_manager:open(M, go_back, cb)
end

queue_exec_request = function(code, opts)
	return executor:queue_exec(code, opts)
end

after_helpers = function(cb)
	executor:after_helpers(cb)
end

exec_with_pipeline = function(code, opts)
	executor:exec_with_pipeline(code, opts)
end

session_manager = SessionManager.new({
	fn = fn,
	kernel = kernel,
	term_helper = term_helper,
	dispatch = dispatch,
	observe_terminal_chunk = observe_terminal_chunk,
	handle_terminal_tab = handle_terminal_tab,
	cmp_bridge = cmp_bridge,
	breakpoints = breakpoints,
	fs = fs,
	utils = utils,
	py_module = py_module,
	exec_with_pipeline = exec_with_pipeline,
	term_send = term_send,
	warn_user = warn_user,
	keymaps = keymaps,
	is_windows = is_windows,
})

function M._flush_pending_exec()
	executor:flush_pending_exec()
end

function M._fail_pending_exec(reason)
	executor:fail_pending_exec(reason)
end

function M._ensure_runcell_helpers(cb)
	executor:ensure_runcell_helpers(cb)
end

function M._send_helpers_if_needed()
	executor:ensure_helpers()
end

local function encode_json(value)
	local ok, encoded = pcall(vim.json.encode, value)
	if not ok or not encoded then
		return "[]"
	end
	return encoded
end

function M._sync_var_filters()
	if not M.is_open() then
		return
	end
	M._send_helpers_if_needed()
	local names = M.config.hidden_var_names
	if type(names) ~= "table" then
		names = {}
	end
	local types = M.config.hidden_type_names
	if type(types) ~= "table" then
		types = {}
	end
	local max_repr = tonumber(M.config.var_repr_limit) or 120
	if max_repr <= 0 then
		max_repr = 120
	end
	local enable_logs = M.config.zmq_debug and true or false
	local names_json = encode_json(names)
	local types_json = encode_json(types)
	local signature =
		table.concat({ names_json, "\0", types_json, "\0", tostring(max_repr), "\0", enable_logs and "1" or "0" })
	if M._last_filters_signature == signature then
		return
	end
	local template = py_module.source("sync_filters.py")
	local script = template
		:gsub("__NAMES_JSON__", names_json)
		:gsub("__TYPES_JSON__", types_json)
		:gsub("__MAX_REPR__", tostring(max_repr))
		:gsub("__ENABLE_LOGS__", enable_logs and "True" or "False")
	exec_with_pipeline(script, {
		require_helpers = true,
		on_error = function(reason)
			local r = tostring(reason or "")
			if M._last_filters_signature == signature then
				M._last_filters_signature = nil
			end
			if r == "helpers_failed" or r == "zmq_unavailable" or r == "conn_file_unavailable" then
				vim.defer_fn(function()
					if M.is_open() then
						M._sync_var_filters()
					end
				end, 150)
				return
			end
			warn_user("ipybridge: failed to sync variable filters via ZMQ (" .. (r ~= "" and r or "unknown") .. ")")
		end,
	})
	M._last_filters_signature = signature
end

function M._digest_vars_snapshot(snapshot)
	return debug_vars.digest_snapshot(M, snapshot)
end

function M._update_latest_vars(data)
	return debug_vars.digest_snapshot(M, data)
end

-- Request the kernel connection file path once and cache it.
function M._ensure_conn_file(cb)
	-- Delegate to kernel manager: it owns the lifecycle of the kernel process.
	kernel.ensure_conn_file(M.config.python_cmd, cb)
end

---Close the IPython terminal if running.
M.close = function()
	if M.is_open() then
		M._term_exit_expected = true
		fn.jobstop(M.term_instance.job_id)
	else
		M._term_exit_expected = false
	end
	clear_debug_state()
	M._zmq_ready = false
	pcall(function()
		require("ipybridge.zmq_client").stop()
	end)
	-- Stop the background kernel process
	pcall(kernel.stop)
	if M._helpers_path then
		pcall(os.remove, M._helpers_path)
		M._helpers_path = nil
	end
	M._helpers_pending = false
	M._helpers_sent = false
	if M._runcell_path then
		pcall(os.remove, M._runcell_path)
		M._runcell_path = nil
	end
	breakpoints.on_session_close()
	M._latest_vars = nil
	M._pending_exec = {}
	M._helpers_waiters = {}
end

---Toggle the IPython terminal split.
M.toggle = function()
	if M.is_open() then
		M.close()
	else
		with_terminal(false, function()
			if M.term_instance then
				M.term_instance:startinsert()
			end
		end)
	end
end

---Jump to the IPython terminal split and enter insert mode.
M.goto_ipy = function()
	if M.term_instance and api.nvim_win_get_buf(0) == M.term_instance.buf_id then
		return
	end
	with_terminal(false, function()
		if not M.term_instance then
			return
		end
		M.term_instance:show()
		api.nvim_set_current_win(M.term_instance.win_id)
		M.term_instance:scroll_to_bottom()
		M.term_instance:startinsert()
	end)
end

---Return focus from IPython split to previous window.
M.goto_vi = function()
	local curbuf = api.nvim_win_get_buf(0)
	local bt = vim.bo[curbuf] and vim.bo[curbuf].buftype or ""
	-- If we're in any terminal buffer, leave terminal-mode and jump back.
	if bt == "terminal" then
		vim.cmd("stopinsert!")
		vim.cmd("wincmd p")
		return
	end
	-- Fallback: handle explicitly for our IPython terminal buffer if matched.
	if M.term_instance and curbuf == M.term_instance.buf_id then
		M.term_instance:stopinsert()
		vim.cmd("wincmd p")
	end
end

---Run the current file in IPython via %run.
M.run_file = function()
	local abs_path = fn.expand("%:p")
	-- Save buffer before run if requested
	if vim.bo.modified and M.config.runfile_save_before_run ~= false then
		pcall(vim.cmd, "write")
	end
	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		local cwd_arg = resolve_exec_cwd(abs_path)
		local function send_runfile()
			local safe = utils.py_quote_single(abs_path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = utils.py_quote_single(cwd_arg)
				term_send(string.format("runfile('%s','%s')\n", safe, safecwd))
			else
				term_send(string.format("runfile('%s')\n", safe))
			end
			clear_debug_state()
		end
		M._ensure_runcell_helpers(function(ok)
			if not ok then
				warn_user("ipybridge: failed to prepare runfile helpers; run aborted")
				return
			end
			send_runfile()
		end)
	end)
end

---Run the current file under IPython debugger via %debugfile.
M.debug_file = function()
	local abs_path = fn.expand("%:p")
	local win = api.nvim_get_current_win()
	if win and api.nvim_win_is_valid(win) then
		M._debug_window = win
	else
		M._debug_window = nil
	end
	if vim.bo.modified and M.config.debugfile_save_before_run ~= false then
		pcall(vim.cmd, "write")
	end
	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		M._send_helpers_if_needed()
		M._ensure_runcell_helpers(function(ok)
			if not ok then
				warn_user("ipybridge: debug helpers unavailable; debugfile aborted")
				return
			end
			breakpoints.push()
			local cwd_arg = resolve_exec_cwd(abs_path)
			local safe = utils.py_quote_single(abs_path)
			local safecwd = nil
			if cwd_arg and #cwd_arg > 0 then
				safecwd = utils.py_quote_single(cwd_arg)
			end
			local debugfile_sent = false
			local function dispatch_debugfile()
				if debugfile_sent then
					return
				end
				debugfile_sent = true
				if safecwd then
					term_send(string.format("debugfile('%s','%s')\n", safe, safecwd))
				else
					term_send(string.format("debugfile('%s')\n", safe))
				end
				local was_debug = M._debug_active
				M._debug_generation = (M._debug_generation or 0) + 1
				if M._debug_generation > 0 then
					M._debug_generation_complete = M._debug_generation - 1
				end
				M._debug_active = true
				M._debug_status_active = true
				if not was_debug then
					M._sync_var_filters()
				end
			end
			exec_with_pipeline("_myipy_reset_debug_baseline()", {
				require_helpers = true,
				on_success = dispatch_debugfile,
				on_error = function(reason)
					local r = tostring(reason or "")
					warn_user(
						"ipybridge: failed to reset debug baseline via ZMQ; falling back to terminal call ("
							.. (r ~= "" and r or "unknown")
							.. ")"
					)
					term_send("_myipy_reset_debug_baseline()\n")
					dispatch_debugfile()
				end,
			})
		end)
	end)
end

---Send lines [line_start, line_stop) to IPython.
---@param line_start integer
---@param line_stop integer
M.send_lines = function(line_start, line_stop)
	local tb_lines = api.nvim_buf_get_lines(0, line_start, line_stop, false)
	if not tb_lines or #tb_lines == 0 then
		return
	end

	if not M._debug_active then
		clear_debug_state()
	end

	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		-- Choose how to deliver multi-line code to IPython.
		-- 'exec' ensures reliability across terminals; 'paste' mirrors typed input.
		local mode = tostring(M.config.multiline_send_mode or "exec")
		if mode == "paste" then
			-- Use bracketed paste so IPython displays the pasted block with prompts.
			local payload = utils.paste_block(tb_lines)
			term_send(payload, { raw = true })
		else
			-- Default: ship as hex-encoded Python and execute via exec().
			local block = table.concat(tb_lines, "\n") .. "\n"
			local payload = utils.send_exec_block(block)
			term_send(payload)
		end
	end)
end

---Send the current visual selection (linewise) to IPython.
M.run_lines = function()
	local line_start0, line_end_excl0 = utils.selection_line_range()
	if not line_start0 then
		return
	end
	M.send_lines(line_start0, line_end_excl0)
end

---Send the current line and move cursor down one line.
M.run_line = function()
	local n_lines = api.nvim_buf_line_count(0)
	local line = api.nvim_get_current_line()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]

	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		term_send_line(line)
		if idx_line_cursor < n_lines then
			api.nvim_win_set_cursor(0, { idx_line_cursor + 1, 0 })
		end
		if not M._debug_active then
			clear_debug_state()
		end
	end)
end

---Send an arbitrary command string to IPython.
---@param cmd string
M.run_cmd = function(cmd)
	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		if M._debug_active then
			term_send_debug(cmd)
		else
			term_send_line(cmd)
		end
	end)
end

local function send_debug_command(cmd, opts)
	if not M._debug_active then
		vim.notify("ipybridge: Debugger is not active", vim.log.levels.WARN)
		return
	end
	if not M.is_open() then
		vim.notify("ipybridge: IPython terminal is not open", vim.log.levels.WARN)
		return
	end
	term_send_debug(cmd)
	if opts and opts.deactivate then
		clear_debug_state({ restore_signcolumn = opts.restore_signcolumn })
	end
end

---Debugger step over (F10 equivalent).
M.debug_step_over = function()
	send_debug_command("!next")
end

---Debugger step into (F11 equivalent).
M.debug_step_into = function()
	send_debug_command("!step")
end

---Debugger step out (Shift-F11 equivalent).
M.debug_step_out = function()
	send_debug_command("!return")
end

---Debugger continue (F12 equivalent).
M.debug_continue = function()
	send_debug_command("!continue", { deactivate = true, restore_signcolumn = false })
end

local function clamp_cursor_line(bufnr, line)
	local max_line = api.nvim_buf_line_count(bufnr)
	if line < 1 then
		return 1
	end
	if line > max_line then
		return max_line
	end
	return line
end

local function calc_column_from_source(source)
	if type(source) ~= "string" or source == "" then
		return 0
	end
	local first = source:find("%S")
	if not first then
		return 0
	end
	return first - 1
end

---Handle explicit debugger status updates from the Python helpers.
---@param info table
function M.on_debug_status(info)
	if type(info) ~= "table" then
		return
	end
	local active = info.active
	if active == nil then
		return
	end
	if active == true then
		if M._debug_status_active ~= true then
			M._debug_generation = (M._debug_generation or 0) + 1
		end
		M._debug_status_active = true
		local was_debug = M._debug_active
		M._debug_active = true
		if not was_debug then
			M._sync_var_filters()
		end
		return
	end
	clear_debug_state()
end

---Handle debug location payload emitted from the embedded debugger.
---@param info table
function M.on_debug_location(info)
	if type(info) ~= "table" then
		return
	end
	local generation = tonumber(M._debug_generation) or 0
	local completed = tonumber(M._debug_generation_complete) or 0
	if generation <= completed then
		return
	end
	local file = info.file or info.filename
	local line = info.line
	if not file or not line then
		return
	end
	if type(line) ~= "number" then
		line = tonumber(line)
	end
	if not line then
		return
	end
	local abs = normalize_path(file)
	if not abs then
		return
	end
	local bufnr = fn.bufadd(abs)
	if bufnr <= 0 then
		return
	end
	fn.bufload(bufnr)
	-- Make sure the buffer stays listed so UI extensions can display it.
	if api.nvim_buf_is_valid(bufnr) then
		pcall(api.nvim_buf_set_option, bufnr, "buflisted", true)
		pcall(api.nvim_buf_set_option, bufnr, "bufhidden", "hide")
	end
	line = clamp_cursor_line(bufnr, line)
	local col = calc_column_from_source(info.source)
	local preferred = M._debug_window
	if preferred and not api.nvim_win_is_valid(preferred) then
		preferred = nil
	end
	local target_win = preferred
	if not target_win then
		for _, win in ipairs(api.nvim_list_wins()) do
			if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
				target_win = win
				break
			end
		end
		if not target_win then
			target_win = api.nvim_get_current_win()
		end
	end
	if not target_win or not api.nvim_win_is_valid(target_win) then
		return
	end
	if api.nvim_win_get_buf(target_win) ~= bufnr then
		pcall(api.nvim_win_set_buf, target_win, bufnr)
	end
	if api.nvim_get_current_win() ~= target_win then
		pcall(api.nvim_set_current_win, target_win)
	end
	api.nvim_win_call(target_win, function()
		pcall(api.nvim_win_set_cursor, target_win, { line, col })
		pcall(vim.cmd, "normal! zv")
		pcall(vim.cmd, "normal! zz")
	end)
	debug_sign.place(bufnr, line, target_win)
	M._debug_window = target_win
	local was_debug = M._debug_active
	M._debug_active = true
	M._debug_status_active = true
	if not was_debug then
		M._sync_var_filters()
	end
	local func_name = info["function"] or info.func
	if type(func_name) == "string" and func_name ~= "" and func_name ~= "<module>" then
		M._debug_scope = "locals"
	else
		M._debug_scope = "globals"
	end
	if M._debug_active then
		M._latest_vars = debug_vars.current_scope(M, M._debug_scope == "locals")
		debug_vars.push_to_explorer(M)
	end
end

local function deliver_vars_to_explorer(payload)
	local ok, vx = pcall(require, "ipybridge.var_explorer")
	if not ok or not vx or type(vx.on_vars) ~= "function" then
		return false
	end
	vim.schedule(function()
		vx.on_vars(payload or {})
	end)
	return true
end

-- Schedule a preview payload for the data viewer; return false when unsupported.
local function deliver_preview_payload(payload)
	local ok, dv = pcall(require, "ipybridge.data_viewer")
	if not ok or not dv or type(dv.on_preview) ~= "function" then
		return false
	end
	vim.schedule(function()
		dv.on_preview(payload)
	end)
	return true
end

-- Helper: push an error payload to the data viewer, warning when delivery fails.
local function deliver_preview_error(name, message)
	local delivered = deliver_preview_payload({ name = name, error = message })
	if not delivered then
		warn_user("ipybridge: data viewer module unavailable")
	end
end

-- Public: open the variable explorer window and refresh data.
M.var_explorer_open = function()
	local vx = require("ipybridge.var_explorer")
	vx.open()
	if M._debug_active then
		debug_vars.push_to_explorer(M)
		return
	end
	M.request_vars()
end

-- Public: refresh variable list.
M.var_explorer_refresh = function()
	if M._debug_active then
		debug_vars.push_to_explorer(M)
		return
	end
	M.request_vars()
end

-- Internal: request variable list from kernel.
function M.request_vars()
	M._sync_var_filters()
	if M._debug_active then
		return
	end
	local max_repr = tonumber(M.config.var_repr_limit) or 120
	if max_repr <= 0 then
		max_repr = 120
	end
	local payload = {
		max_repr = max_repr,
		hide_names = M.config.hidden_var_names,
		hide_types = M.config.hidden_type_names,
	}
	local function dispatch_vars_request()
		local z = require("ipybridge.zmq_client")
		local ok_req = z.request("vars", payload, function(msg)
			if msg and msg.ok and msg.tag == "vars" then
				if not deliver_vars_to_explorer(msg.data or {}) then
					warn_user("ipybridge: variable explorer module unavailable")
				end
				return
			end
			warn_user("ipybridge: ZMQ vars request failed")
		end)
		if not ok_req then
			warn_user("ipybridge: ZMQ request send failed")
		end
	end
	if M._zmq_ready then
		dispatch_vars_request()
		return
	end
	-- If ZMQ not ready, attempt to prepare once; do not fall back to typing helper calls.
	M.ensure_zmq(function(ok)
		if ok then
			dispatch_vars_request()
			return
		end
		warn_user("ipybridge: ZMQ backend not available; vars unavailable")
	end)
end

-- Internal: request preview for a variable name from kernel.
function M.request_preview(name, opts)
	if not name or #name == 0 then
		return
	end
	opts = opts or {}
	local row_offset = tonumber(opts.row_offset) or 0
	local col_offset = tonumber(opts.col_offset) or 0
	if row_offset < 0 then
		row_offset = 0
	end
	if col_offset < 0 then
		col_offset = 0
	end
	local max_rows = tonumber(M.config.viewer_max_rows) or 30
	local max_cols = tonumber(M.config.viewer_max_cols) or 20
	local debug_mode = M._debug_active == true
	if debug_mode then
		local use_cache = (row_offset == 0 and col_offset == 0)
		local payload = nil
		if use_cache then
			payload = debug_vars.preview_payload(M, name)
			if type(payload) == "table" then
				payload.row_offset = payload.row_offset or 0
				payload.col_offset = payload.col_offset or 0
			end
		end
		if payload then
			if not deliver_preview_payload(payload) then
				warn_user("ipybridge: data viewer module unavailable")
			end
			return
		end
		local function dispatch_response(msg)
			if msg and msg.ok and msg.tag == "preview" then
				if not deliver_preview_payload(msg.data or {}) then
					warn_user("ipybridge: data viewer module unavailable")
				end
				return
			end
			deliver_preview_error(name, "Debug preview request failed")
			if msg and msg.error then
				warn_user("ipybridge: ZMQ debug preview failed - " .. tostring(msg.error))
			else
				warn_user("ipybridge: ZMQ debug preview failed")
			end
		end
		local function send_debug_request()
			local z = require("ipybridge.zmq_client")
			local payload_dbg = {
				name = name,
				max_rows = max_rows,
				max_cols = max_cols,
				debug = true,
				row_offset = row_offset,
				col_offset = col_offset,
			}
			local ok_req = z.request("preview", payload_dbg, dispatch_response)
			if not ok_req then
				deliver_preview_error(name, "Failed to send debug preview request")
				warn_user("ipybridge: failed to send ZMQ debug preview request")
			end
		end
		if M._zmq_ready then
			send_debug_request()
		else
			M.ensure_zmq(function(ok)
				if ok then
					send_debug_request()
				else
					deliver_preview_error(name, "ZMQ backend unavailable in debug")
					warn_user("ipybridge: ZMQ backend not available; debug preview unavailable")
				end
			end)
		end
		return
	end

	M._sync_var_filters()
	local function dispatch_preview_request()
		local z = require("ipybridge.zmq_client")
		local payload_req = {
			name = name,
			max_rows = max_rows,
			max_cols = max_cols,
			row_offset = row_offset,
			col_offset = col_offset,
		}
		local ok_req = z.request("preview", payload_req, function(msg)
			if msg and msg.ok and msg.tag == "preview" then
				if not deliver_preview_payload(msg.data or {}) then
					warn_user("ipybridge: data viewer module unavailable")
				end
				return
			end
			warn_user("ipybridge: ZMQ preview request failed")
		end)
		if not ok_req then
			warn_user("ipybridge: ZMQ request send failed")
		end
	end
	if M._zmq_ready then
		dispatch_preview_request()
		return
	end
	-- Ensure ZMQ then retry once; do not fall back to typing helper calls.
	M.ensure_zmq(function(ok)
		if ok then
			dispatch_preview_request()
			return
		end
		warn_user("ipybridge: ZMQ backend not available; preview unavailable")
	end)
end

---Request an interrupt signal for the connected kernel.
function M.interrupt()
	local function dispatch_interrupt()
		local ok, z = pcall(require, "ipybridge.zmq_client")
		if not ok or not z then
			warn_user("ipybridge: ZMQ backend not available; interrupt failed")
			return
		end
		local sent = z.request("interrupt", {}, function(msg)
			if msg and msg.ok and msg.tag == "interrupt" then
				return
			end
			local err = (msg and msg.error) or "interrupt failed"
			warn_user("ipybridge: " .. err)
		end)
		if not sent then
			warn_user("ipybridge: failed to send interrupt request")
		end
	end
	if M._zmq_ready then
		dispatch_interrupt()
		return
	end
	M.ensure_zmq(function(ok)
		if ok then
			dispatch_interrupt()
			return
		end
		warn_user("ipybridge: ZMQ backend not available; interrupt failed")
	end)
end

function M.ensure_zmq(cb)
	executor:ensure_zmq(cb)
end

---Run the current cell delimited by lines starting with "# %%".
M.run_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	-- Prefer IPython runcell helper when viable.
	local path = fn.expand("%:p")
	if not (path and #path > 0) then
		warn_user("ipybridge: unable to resolve file path for runcell; run aborted")
		return
	end
	-- Save buffer before run if requested
	if vim.bo.modified and M.config.runcell_save_before_run ~= false then
		pcall(vim.cmd, "write")
	end
	if vim.bo.modified or not utils.file_exists(path) then
		warn_user("ipybridge: file must be saved before runcell can run")
		return
	end
	-- Determine working directory to pass into runcell (no global %cd)
	-- Count cell index by markers strictly matching '^# %%+'
	local pre_lines = api.nvim_buf_get_lines(0, 0, math.max(line_start - 1, 0), false)
	local idx = 0
	for _, ln in ipairs(pre_lines) do
		local s = CELL_RE:match_str(ln)
		if s ~= nil then
			idx = idx + 1
		end
	end
	with_terminal(true, function()
		if not M.is_open() then
			return
		end
		local cwd_arg = resolve_exec_cwd(path)
		M._ensure_runcell_helpers(function(ok)
			if not ok then
				warn_user("ipybridge: failed to prepare runcell helpers; run aborted")
				return
			end
			local safe = utils.py_quote_single(path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = utils.py_quote_single(cwd_arg)
				term_send(string.format("runcell(%d, '%s', '%s')\n", idx, safe, safecwd))
			else
				term_send(string.format("runcell(%d, '%s')\n", idx, safe))
			end
			clear_debug_state()
			if has_next_cell then
				local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
				api.nvim_win_set_cursor(0, { idx_line, 0 })
			end
		end)
	end)
end

---Move cursor to the start of the previous cell.
M.up_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor - 2)

	local idx_line = math.min(line_start + 1, api.nvim_buf_line_count(0))
	api.nvim_win_set_cursor(0, { idx_line, 0 })
end

---Move cursor to the start of the next cell.
M.down_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	if has_next_cell then
		local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
		api.nvim_win_set_cursor(0, { idx_line, 0 })
	end
end

return M
