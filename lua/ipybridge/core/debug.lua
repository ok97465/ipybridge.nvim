-- Debug helper routines extracted from the main module to keep init.lua lean.
-- Handles cmp integration, terminal prompt observation, and debug status events.

local Debug = {}

function Debug.new(ctx)
	local state = assert(ctx.state, "debug: state table is required")
	local cmp_bridge = assert(ctx.cmp_bridge, "debug: cmp_bridge is required")
	local debug_sign = assert(ctx.debug_sign, "debug: debug_sign is required")
	local debug_vars = assert(ctx.debug_vars, "debug: debug_vars is required")
	local normalize_path = assert(ctx.normalize_path, "debug: normalize_path is required")
	local warn_user = ctx.warn_user or function() end
	local fn = ctx.fn or vim.fn
	local is_open = ctx.is_open or function()
		return state.term_instance ~= nil and type(state.term_instance.job_id) == "number" and state.term_instance.job_id > 0
	end

	local term_send = nil
	local term_send_debug = nil
	local sync_handler = function() end
	local prompt_buffer = ""

	local function trigger_cmp_completion()
		if not state._debug_active then
			return false
		end
		if not cmp_bridge.ensure() then
			return false
		end
		return cmp_bridge.trigger()
	end

	local function handle_terminal_tab()
		if trigger_cmp_completion() then
			return
		end
		local literal_tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
		vim.api.nvim_feedkeys(literal_tab, "tn", false)
	end

	local function clear_state(opts)
		opts = type(opts) == "table" and opts or {}
		local restore_signcolumn = opts.restore_signcolumn
		if restore_signcolumn == nil then
			restore_signcolumn = true
		end
		if type(state._debug_generation) == "number" and state._debug_generation > 0 then
			state._debug_generation_complete = state._debug_generation
		end
		state._debug_active = false
		state._debug_status_active = false
		state._debug_window = nil
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
			if state._debug_active then
				clear_state()
			end
			prompt_buffer = ""
		elseif #prompt_buffer > 256 then
			prompt_buffer = prompt_buffer:sub(-256)
		end
	end

	local function send_command(cmd, opts)
		if not state._debug_active then
			vim.notify("ipybridge: Debugger is not active", vim.log.levels.WARN)
			return
		end
		if not is_open() then
			vim.notify("ipybridge: IPython terminal is not open", vim.log.levels.WARN)
			return
		end
		if type(term_send_debug) ~= "function" then
			warn_user("ipybridge: terminal debug sender unavailable")
			return
		end
		term_send_debug(cmd)
		if opts and opts.deactivate then
			clear_state({ restore_signcolumn = opts.restore_signcolumn })
		end
	end

	local function clamp_cursor_line(bufnr, line)
		local max_line = vim.api.nvim_buf_line_count(bufnr)
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

	local function on_status(info)
		if type(info) ~= "table" then
			return
		end
		local active = info.active
		if active == nil then
			return
		end
		if active == true then
			if state._debug_status_active ~= true then
				state._debug_generation = (state._debug_generation or 0) + 1
			end
			state._debug_status_active = true
			local was_debug = state._debug_active
			state._debug_active = true
			if not was_debug then
				sync_handler()
			end
			return
		end
		clear_state()
	end

	local function on_location(info)
		if type(info) ~= "table" then
			return
		end
		local generation = tonumber(state._debug_generation) or 0
		local completed = tonumber(state._debug_generation_complete) or 0
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
		if vim.api.nvim_buf_is_valid(bufnr) then
			pcall(vim.api.nvim_buf_set_option, bufnr, "buflisted", true)
			pcall(vim.api.nvim_buf_set_option, bufnr, "bufhidden", "hide")
		end
		line = clamp_cursor_line(bufnr, line)
		local col = calc_column_from_source(info.source)
		local preferred = state._debug_window
		if preferred and not vim.api.nvim_win_is_valid(preferred) then
			preferred = nil
		end
		local target_win = preferred
		if not target_win then
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
					target_win = win
					break
				end
			end
			if not target_win then
				target_win = vim.api.nvim_get_current_win()
			end
		end
		if not target_win or not vim.api.nvim_win_is_valid(target_win) then
			return
		end
		if vim.api.nvim_win_get_buf(target_win) ~= bufnr then
			pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
		end
		if vim.api.nvim_get_current_win() ~= target_win then
			pcall(vim.api.nvim_set_current_win, target_win)
		end
		vim.api.nvim_win_call(target_win, function()
			pcall(vim.api.nvim_win_set_cursor, target_win, { line, col })
			pcall(vim.cmd, "normal! zv")
			pcall(vim.cmd, "normal! zz")
		end)
		debug_sign.place(bufnr, line, target_win)
		state._debug_window = target_win
		local was_debug = state._debug_active
		state._debug_active = true
		state._debug_status_active = true
		if not was_debug then
			sync_handler()
		end
		local func_name = info["function"] or info.func
		if type(func_name) == "string" and func_name ~= "" and func_name ~= "<module>" then
			state._debug_scope = "locals"
		else
			state._debug_scope = "globals"
		end
		if state._debug_active then
			state._latest_vars = debug_vars.current_scope(state, state._debug_scope == "locals")
			debug_vars.push_to_explorer(state)
		end
	end

	return {
		clear_state = clear_state,
		handle_terminal_tab = handle_terminal_tab,
		observe_terminal_chunk = observe_terminal_chunk,
		send_command = send_command,
		on_status = on_status,
		on_location = on_location,
		set_terminal_senders = function(term_fn, debug_fn)
			term_send = term_fn
			term_send_debug = debug_fn
		end,
		set_sync_handler = function(cb)
			if type(cb) == "function" then
				sync_handler = cb
			else
				sync_handler = function() end
			end
		end,
	}
end

return Debug
