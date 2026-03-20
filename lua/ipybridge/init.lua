-- Main entry point for ipybridge.nvim.
-- Wires together the terminal manager, ZMQ executor, debugger helpers,
-- completion bridge, execution controller, and the user command surface.
-- This plugin requires Neovim 0.11 or newer.
-- Fail fast on older versions to prevent undefined behavior.
if vim.fn.has("nvim-0.11") ~= 1 then
	error("ipybridge.nvim requires Neovim 0.11 or newer")
end

local vim = vim
local api = vim.api
local fn = vim.fn
local term_helper = require("ipybridge.term_ipy")
local dispatch = require("ipybridge.core.dispatch")
-- Refactored internal modules (utilities, keymaps, kernel manager)
local utils = require("ipybridge.utils")
local keymaps = require("ipybridge.keymaps")
local kernel = require("ipybridge.kernel")
local py_module = require("ipybridge.py_module")
local debug_vars = require("ipybridge.debug.vars")
local breakpoints = require("ipybridge.debug.breakpoints")
local debug_cursor_tooltip = require("ipybridge.debug.cursor_tooltip")
local cmp_bridge = require("ipybridge.cmp_bridge")
local cmp_constants = require("ipybridge.cmp_bridge.constants")
local debug_completion = require("ipybridge.debug.completion")
local debug_sign = require("ipybridge.debug.sign")
local Debug = require("ipybridge.core.debug")
local Terminal = require("ipybridge.core.terminal")
local Executor = require("ipybridge.executor")
local SessionManager = require("ipybridge.session")
local plot_viewer = require("ipybridge.viewer.plot")
local ExecutionController = require("ipybridge.controllers.execution")
local TerminalController = require("ipybridge.controllers.terminal")
local VariablesController = require("ipybridge.controllers.variables")
local SyncController = require("ipybridge.controllers.sync")
local DebuggerController = require("ipybridge.controllers.debugger")
local inspect = vim.inspect
local fs = vim.fs
local uv = vim.uv
local is_windows = uv.os_uname().sysname == "Windows_NT"

local queue_exec_request
local after_helpers
local exec_with_pipeline
local session_manager
local sync_controller
local variables_controller
local terminal_controller
local debugger_controller

-- Emit user-facing warnings on the main loop to avoid tearing.
local function warn_user(message)
	if not message then
		return
	end
	vim.schedule(function()
		vim.notify(tostring(message), vim.log.levels.WARN)
	end)
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
	_debug_location = nil,
	_debug_scope = "globals",
	_debug_window = nil,
	_prev_editor_win = nil,
	_last_python_buf = nil,
	_last_filters_signature = nil,
	_debugfile_imports_signature = nil,
	_pending_exec = {},
	_helpers_waiters = {},
	_runcell_waiters = {},
	_zmq_waiters = {},
	_zmq_bootstrap_pending = false,
	_zmq_warmup_done = false,
	_zmq_warmup_cmd = nil,
	-- Guard against double-cleanup when the user types `exit` inside IPython.
	_term_exit_expected = false,
}

local with_terminal
local term_send

local clear_debug_state
local handle_terminal_tab
local observe_terminal_chunk
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

local function track_python_buffer(bufnr)
	if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
		return
	end
	if not api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local bt = (vim.bo[bufnr] and vim.bo[bufnr].buftype) or ""
	if bt ~= "" then
		return
	end
	local ft = (vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
	if ft ~= "python" then
		return
	end
	local name = api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return
	end
	M._last_python_buf = bufnr
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

local debug = Debug.new({
	state = M,
	cmp_bridge = cmp_bridge,
	debug_sign = debug_sign,
	debug_vars = debug_vars,
	warn_user = warn_user,
	fn = fn,
	normalize_path = normalize_path,
	lookup_breakpoint_kind = function(bufnr, line)
		return breakpoints.get_line_sign_kind(bufnr, line)
	end,
	show_debug_overlay = function(bufnr, line)
		breakpoints.show_debug_overlay(bufnr, line)
	end,
	clear_debug_overlay = function()
		breakpoints.clear_debug_overlay()
	end,
	is_open = function()
		return M.term_instance ~= nil and type(M.term_instance.job_id) == "number" and M.term_instance.job_id > 0
	end,
})

local terminal = Terminal.new({
	state = M,
	warn_user = warn_user,
	open = function(go_back, cb)
		if type(M.open) == "function" then
			return M.open(go_back, cb)
		end
	end,
	is_open = function()
		return M.term_instance ~= nil and type(M.term_instance.job_id) == "number" and M.term_instance.job_id > 0
	end,
})

with_terminal = terminal.with_terminal
term_send = terminal.term_send

clear_debug_state = debug.clear_state
handle_terminal_tab = debug.handle_terminal_tab
observe_terminal_chunk = debug.observe_terminal_chunk
debug.set_terminal_senders(term_send)

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
	-- Save buffer before calling debugcell to ensure the file content is current
	debugcell_save_before_run = true,
	-- Working directory mode for executing run_cell/run_file: 'file' | 'pwd' | 'none'
	--  - 'file': cd to the current file's directory before executing
	--  - 'pwd' : cd to Neovim's current working directory before executing
	--  - 'none': do not change directory
	exec_cwd_mode = "pwd",
	-- Console prompt styling options.
	-- Optional color scheme for ZMQTerminalInteractiveShell (e.g., 'Linux', 'LightBG', 'NoColor').
	ipython_colors = "Linux",
	-- Variable explorer: hide variables by exact name or type name (supports '*' suffix as prefix wildcard)
	hidden_var_names = { "pi", "newaxis", "MODULE_B64" },
	hidden_type_names = { "ZMQInteractiveShell", "Axes", "Figure", "AxesSubplot" },
	-- Debug cursor tooltip: show floating variable preview on cursor move during debug.
	debug_cursor_tooltip = true,
	-- Import statements (single string) injected into the debugfile namespace before ipdb starts.
	debugfile_auto_imports = "",
	-- ZMQ backend debug logs (Python client prints to stderr)
	zmq_debug = false,
	-- IPython autoreload: 1, 2, or 'disable' (default 2)
	--  - 1: Reload modules imported with %aimport
	--  - 2: Reload all modules (except those excluded)
	--  - 'disable': Do not configure autoreload
	autoreload = 2,
	-- Extra terminal-mode keymaps applied after the IPython console buffer is created.
	terminal_keymaps = nil,
	-- Lock the terminal window to its buffer to prevent accidental replacement.
	terminal_winfixbuf = false,
	completion = {
		engine_priority = vim.deepcopy(cmp_constants.default_engine_priority),
	},
	plot_viewer = plot_viewer.defaults(),
}

local function normalize_plot_viewer_config(value)
	if value == nil then
		return nil
	end
	if type(value) == "string" then
		return { mode = value }
	end
	return value
end

M.setup = function(config)
	if config ~= nil then
		if config.debug_cursor_tooltip ~= nil then
			local t = type(config.debug_cursor_tooltip)
			if t ~= "boolean" and t ~= "table" then
				error("ipybridge: debug_cursor_tooltip must be a boolean or table")
			end
		end
		if config.plot_viewer ~= nil then
			local t = type(config.plot_viewer)
			if t ~= "string" and t ~= "table" then
				error("ipybridge: plot_viewer must be \"browser\", \"off\", or a table")
			end
		end
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
			debugcell_save_before_run = { config.debugcell_save_before_run, "b", true },
			debugfile_auto_imports = { config.debugfile_auto_imports, "s", true },
			terminal_keymaps = { config.terminal_keymaps, "function", true },
			terminal_winfixbuf = { config.terminal_winfixbuf, "b", true },
			completion = { config.completion, "table", true },
		})
		if config.completion and config.completion.engine_priority ~= nil then
			vim.validate({
				engine_priority = { config.completion.engine_priority, "table" },
			})
		end
	end
	local merged = config or {}
	if merged.plot_viewer ~= nil then
		merged = vim.deepcopy(merged)
		merged.plot_viewer = normalize_plot_viewer_config(merged.plot_viewer)
	end
	M.config = vim.tbl_deep_extend("force", M.config, merged)
	plot_viewer.configure(M.config.plot_viewer)
	cmp_bridge.configure(M.config.completion or {})
	debug_cursor_tooltip.setup(M.config.debug_cursor_tooltip)
	local tracker_group = api.nvim_create_augroup("IpybridgeBufferTracker", { clear = true })
	api.nvim_create_autocmd("FileType", {
		group = tracker_group,
		pattern = "python",
		callback = function(args)
			track_python_buffer(args.buf)
		end,
	})
	api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = tracker_group,
		callback = function(args)
			track_python_buffer(args.buf)
		end,
	})

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
		M._sync_debugfile_imports()
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

---Open the browser-based plot viewer.
function M.plot_open()
	plot_viewer.open_browser()
end

function M.plot_next()
	plot_viewer.next()
end

function M.plot_prev()
	plot_viewer.prev()
end

function M.plot_delete()
	plot_viewer.delete()
end

function M.plot_clear()
	plot_viewer.clear()
end

function M.plot_status()
	plot_viewer.status()
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
	terminal_controller:handle_term_exit()
end

---Open the IPython terminal split.
---@param go_back boolean|nil # if true, jump back to previous window after init
M.open = function(go_back, cb)
	terminal_controller:open(go_back, cb)
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

sync_controller = SyncController.new({
	state = M,
	py_module = py_module,
	exec_with_pipeline = function(code, opts)
		exec_with_pipeline(code, opts)
	end,
	ensure_helpers = function()
		M._send_helpers_if_needed()
	end,
	is_open = function()
		return M.is_open()
	end,
	warn_user = warn_user,
})

variables_controller = VariablesController.new({
	state = M,
	debug_vars = debug_vars,
	sync_var_filters = function()
		sync_controller:sync_var_filters()
	end,
	ensure_zmq = function(cb)
		executor:ensure_zmq(cb)
	end,
	warn_user = warn_user,
})

terminal_controller = TerminalController.new({
	state = M,
	fn = fn,
	kernel = kernel,
	breakpoints = breakpoints,
	clear_debug_state = clear_debug_state,
	session_manager = session_manager,
	api = api,
	with_terminal = with_terminal,
	is_open = function()
		return M.is_open()
	end,
})

debugger_controller = DebuggerController.new({
	state = M,
	term_send = term_send,
	clear_debug_state = clear_debug_state,
	is_open = function()
		return M.is_open()
	end,
})

function M._sync_var_filters()
	sync_controller:sync_var_filters()
end

function M._sync_debugfile_imports(cb)
	sync_controller:sync_debugfile_imports(cb)
end


debug.set_sync_handler(function()
	if type(M._sync_var_filters) == "function" then
		M._sync_var_filters()
	end
end)

local execution = ExecutionController.new({
	state = M,
	api = api,
	fn = fn,
	utils = utils,
	breakpoints = breakpoints,
	warn_user = warn_user,
	resolve_exec_cwd = resolve_exec_cwd,
	with_terminal = function(go_back, cb)
		with_terminal(go_back, cb)
	end,
	term_send = term_send,
	clear_debug_state = clear_debug_state,
	ensure_runcell_helpers = function(cb)
		M._ensure_runcell_helpers(cb)
	end,
	exec_with_pipeline = function(code, opts)
		exec_with_pipeline(code, opts)
	end,
	sync_debugfile_imports = function(cb)
		M._sync_debugfile_imports(cb)
	end,
	sync_var_filters = function()
		M._sync_var_filters()
	end,
	is_open = function()
		return M.is_open()
	end,
	send_helpers = function()
		M._send_helpers_if_needed()
	end,
})

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
	terminal_controller:close()
end

---Toggle the IPython terminal split.
M.toggle = function()
	terminal_controller:toggle()
end

---Restart the IPython terminal and kernel.
M.restart = function()
	terminal_controller:restart()
end

---Jump to the IPython terminal split and enter insert mode.
M.goto_ipy = function()
	terminal_controller:goto_ipy()
end

---Return focus from IPython split to previous window.
M.goto_vi = function()
	terminal_controller:goto_vi()
end

---Jump to the current debugger stop location in the editor.
M.goto_debug_location = function()
	debug.goto_current_location()
	debug_cursor_tooltip.clear()
end

---Run the current file in IPython via %run.
M.run_file = function()
	execution:run_file()
end

---Run the current file under IPython debugger via %debugfile.
M.debug_file = function()
	execution:debug_file()
end

---Send lines [line_start, line_stop) to IPython.
---@param line_start integer
---@param line_stop integer
M.send_lines = function(line_start, line_stop)
	execution:send_lines(line_start, line_stop)
end

---Send the current visual selection (linewise) to IPython.
M.run_lines = function()
	execution:run_lines()
end

---Send the current line and move cursor down one line.
M.run_line = function()
	execution:run_line()
end

---Send an arbitrary command string to IPython.
---@param cmd string
M.run_cmd = function(cmd)
	execution:run_cmd(cmd)
end

---Debugger step over (F10 equivalent).
M.debug_step_over = function()
	debugger_controller:step_over()
end

---Debugger step into (F11 equivalent).
M.debug_step_into = function()
	debugger_controller:step_into()
end

---Debugger step out (Shift-F11 equivalent).
M.debug_step_out = function()
	debugger_controller:step_out()
end

---Debugger continue (F12 equivalent).
M.debug_continue = function()
	debugger_controller:continue_exec()
end

---Exit the debugger and restore normal terminal input.
M.quit_debug = function()
	debugger_controller:quit()
end

---Handle explicit debugger status updates from the Python helpers.
---@param info table
function M.on_debug_status(info)
	debug.on_status(info)
	debug_cursor_tooltip.on_debug_status(info)
end

---Handle debug location payload emitted from the embedded debugger.
---@param info table
function M.on_debug_location(info)
	debug.on_location(info)
	debug_cursor_tooltip.clear()
end

---@param focus_terminal_on_close boolean|nil
M.var_explorer_open = function(focus_terminal_on_close)
	variables_controller:open(focus_terminal_on_close)
end

M.var_explorer_refresh = function()
	variables_controller:refresh()
end

---Open a preview for the variable under the cursor when available.
function M.preview_cursor()
	local extractor = debug_cursor_tooltip._extract_identifier
	local pos = api.nvim_win_get_cursor(0)
	local line = api.nvim_buf_get_lines(api.nvim_get_current_buf(), pos[1] - 1, pos[1], false)[1] or ""
	local name = extractor(line, pos[2])
	if not name then
		return
	end
	local vars = M._latest_vars or {}
	local explorer = require("ipybridge.var_explorer")
	local opened = explorer.preview_entry(name, vars[name])
	if opened ~= nil or M._debug_active then
		return
	end
	explorer.queue_preview(name)
	variables_controller:request_vars()
end

function M.request_vars()
	variables_controller:request_vars()
end

function M.request_preview(name, opts)
	variables_controller:request_preview(name, opts)
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
M.debug_cell = function()
	execution:debug_cell()
end

---Run the current cell delimited by lines starting with "# %%".
M.run_cell = function()
	execution:run_cell()
end

---Move cursor to the start of the previous cell.
M.up_cell = function()
	execution:up_cell()
end

---Move cursor to the start of the next cell.
M.down_cell = function()
	execution:down_cell()
end

return M
