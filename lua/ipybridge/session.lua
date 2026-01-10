-- Session manager that owns terminal bootstrap/orchestration.
-- Handles console environment setup, helper uploads, breakpoint wiring, and
-- terminal keymaps so init.lua stays lean.
local plot_viewer = require("ipybridge.viewer.plot")
local session_env = require("ipybridge.session_env")
local session_startup = require("ipybridge.session_startup")

local Session = {}
Session.__index = Session

-- Fetch a required dependency from opts and fail fast when missing.
local function dependency(tbl, key)
	local value = tbl[key]
	assert(value ~= nil, string.format("ipybridge.session: missing dependency '%s'", key))
	return value
end

---Create a new session manager.
---@param opts table
function Session.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Session)
	self.fn = dependency(opts, "fn")
	self.kernel = dependency(opts, "kernel")
	self.term_helper = dependency(opts, "term_helper")
	self.dispatch = dependency(opts, "dispatch")
	self.observe_terminal_chunk = dependency(opts, "observe_terminal_chunk")
	self.handle_terminal_tab = dependency(opts, "handle_terminal_tab")
	self.cmp_bridge = dependency(opts, "cmp_bridge")
	self.breakpoints = dependency(opts, "breakpoints")
	self.fs = dependency(opts, "fs")
	self.utils = dependency(opts, "utils")
	self.py_module = dependency(opts, "py_module")
	self.exec_with_pipeline = dependency(opts, "exec_with_pipeline")
	self.term_send = dependency(opts, "term_send")
	self.warn_user = dependency(opts, "warn_user")
	self.keymaps = dependency(opts, "keymaps")
	self.is_windows = opts.is_windows and true or false
	return self
end

---Build the Jupyter console command and env overrides for this session.
---@param state table
---@param conn_file string
---@return string, table
function Session:build_console_env(state, conn_file)
	return session_env.build_console_env({
		utils = self.utils,
		fn = self.fn,
		breakpoints = self.breakpoints,
		py_module = self.py_module,
	}, state, conn_file)
end

---Reset transient session flags and clean up temp helper files.
---@param state table
function Session:reset_state(state)
	state._term_exit_expected = false
	state._helpers_sent = false
	state._helpers_pending = false
	if state._helpers_path then
		-- Clean up temporary helper files from previous runs so they never leak between sessions.
		pcall(os.remove, state._helpers_path)
		state._helpers_path = nil
	end
	state._runcell_sent = false
	if state._runcell_path then
		pcall(os.remove, state._runcell_path)
		state._runcell_path = nil
	end
	state._runcell_pending = false
	state._runcell_waiters = {}
	state._zmq_ready = false
	state._zmq_bootstrap_pending = false
	state._zmq_waiters = {}
	state._last_filters_signature = nil
	state._debugfile_imports_signature = nil
	state._pending_exec = {}
	state._helpers_waiters = {}
end

---Attach breakpoint hooks so debug commands flow through the exec pipeline.
---@param state table
function Session:attach_breakpoints(state)
	self.breakpoints.attach_session({
		exec = function(payload, opts)
			if type(payload) ~= "string" or payload == "" then
				return
			end
			local merged = vim.tbl_extend("force", {
				require_helpers = true,
			}, opts or {})
			self.exec_with_pipeline(payload, merged)
		end,
		is_term_open = state.is_open,
	})
end

---Apply terminal buffer keymaps and completion hooks.
---@param state table
function Session:setup_terminal_keymaps(state)
	pcall(function()
		local term = state.term_instance
		-- Keymaps rely on the terminal buffer still being alive, so we guard the setup.
		if not term then
			return
		end
		local buf = term.buf_id
		local function define_terminal_map(lhs, rhs, opts)
			local options = type(opts) == "table" and vim.deepcopy(opts) or {}
			options.buffer = buf
			if options.silent == nil then
				options.silent = true
			end
			vim.keymap.set("t", lhs, rhs, options)
		end

		self.cmp_bridge.ensure()

		local config = state.config or {}
		local completion = config.completion
		local tab_enabled = true
		if completion then
			local priority = completion.engine_priority
			if type(priority) == "table" and vim.tbl_isempty(priority) then
				tab_enabled = false
			end
		end
		if config.set_default_keymaps ~= false then
			self.keymaps.apply_terminal_defaults(define_terminal_map, {
				goto_vi = state.goto_vi,
				goto_desc = "IPy: Back to editor",
				handle_tab = tab_enabled and self.handle_terminal_tab or nil,
				tab_desc = "IPy: Debug completion trigger",
				interrupt = state.interrupt,
				interrupt_desc = "IPy: Keyboard interrupt",
			})
		end

		local custom_maps = config.terminal_keymaps
		if type(custom_maps) == "function" then
			custom_maps(define_terminal_map)
		end
	end)
end

---Collect startup magics/scripts to run after the console opens.
---@param state table
---@param cwd string
---@return table
function Session:collect_startup_instructions(state, cwd)
	return session_startup.collect_startup_instructions({
		fs = self.fs,
		utils = self.utils,
		is_windows = self.is_windows,
	}, state, cwd)
end

---Start the plot viewer when the browser-backed mode is enabled.
---@param state table
function Session:_maybe_enable_plot_viewer(state)
	if plot_viewer.mode() ~= "browser" then
		return
	end
	-- Delegate readiness orchestration to the Lua plot_viewer module so ZMQ and Python helpers stay encapsulated there.
	local ok, err = pcall(plot_viewer.ensure_ready)
	if not ok then
		self.warn_user("ipybridge: failed to start plot viewer (" .. tostring(err or "unknown") .. ")")
	end
end

---Run startup steps after an optional delay to let the kernel settle.
---@param state table
---@param opts table
function Session:run_deferred_startup(state, opts)
	local go_back = opts.go_back
	local callback = opts.callback
	local cwd = opts.cwd
	local delay = tonumber(state.config.sleep_ms_after_open) or 0

	vim.defer_fn(function()
		-- Run the startup sequence after a short delay so the kernel and ZMQ bridges are settled.
		if not state.is_open() then
			return
		end
		state._send_helpers_if_needed()
		self.breakpoints.sync_with_kernel()
		state._sync_var_filters()

		local instructions = self:collect_startup_instructions(state, cwd)
		if #instructions.magics > 0 then
			local payload = table.concat(instructions.magics, "\n") .. "\n"
			self.exec_with_pipeline(payload, {
				on_error = function(reason)
					self.warn_user(
						"ipybridge: failed to run startup magics via ZMQ (" .. tostring(reason or "unknown") .. ")"
					)
				end,
			})
		end

		if instructions.warmup_code then
			self.exec_with_pipeline(instructions.warmup_code .. "\n", {
				on_error = function(reason)
					self.warn_user("ipybridge: matplotlib warmup failed (" .. tostring(reason or "unknown") .. ")")
				end,
			})
		end

		if instructions.startup_stmt then
			local stmt = instructions.startup_stmt
			self.exec_with_pipeline(stmt, {
				require_helpers = true,
				on_error = function(reason)
					local r = tostring(reason or "")
					self.warn_user(
						"ipybridge: failed to run startup script via ZMQ; replaying in terminal ("
						.. (r ~= "" and r or "unknown")
						.. ")"
					)
					self.term_send(stmt)
				end,
			})
		end

		self:_maybe_enable_plot_viewer(state)

		state._ensure_runcell_helpers()
		if state.term_instance then
			state.term_instance:scroll_to_bottom()
		end
		if go_back == true then
			vim.cmd("wincmd p")
		end
		if callback then
			callback(true)
		end
	end, delay)
end

---Notify user about missing Python dependencies when a startup step fails.
---@param python_cmd string
---@param context string
---@param modules table
function Session:_notify_missing_deps(python_cmd, context, modules)
	-- Check for missing python dependencies and notify the user if any are found.
	-- This is only called when a startup process fails, so we don't slow down the happy path.
	local missing = self.utils.check_python_deps(python_cmd, modules)
	if missing and #missing > 0 then
		local msg = string.format(
			"ipybridge: %s. Missing packages: %s. You may need to run: %s -m pip install %s",
			context,
			table.concat(missing, ", "),
			python_cmd,
			table.concat(missing, " ")
		)
		vim.notify(msg, vim.log.levels.ERROR)
		return true -- notification was sent
	end
	return false -- no missing dependencies found
end

---Open the terminal session.
---@param state table
---@param go_back boolean|nil
---@param cb function|nil
function Session:open(state, go_back, cb)
	local cwd = self.fn.getcwd()
	local python_cmd = state.config.python_cmd
	local core_deps = { "ipykernel", "jupyter_client", "ipython", "jupyter_console" }
	local zmq_deps = { "zmq" }

	self.kernel.ensure(python_cmd, function(ok, conn_file)
		if not ok then
			local notified = self:_notify_missing_deps(python_cmd, "failed to start Jupyter kernel", core_deps)
			if not notified then
				vim.notify("ipybridge: failed to start Jupyter kernel", vim.log.levels.ERROR)
			end
			if cb then
				cb(false)
			end
			return
		end

		local cmd_console, env = self:build_console_env(state, conn_file)
		state.term_instance = self.term_helper.TermIpy:new(cmd_console, cwd, {
			on_message = self.dispatch.handle,
			on_stdout_chunk = self.observe_terminal_chunk,
			env = env,
			on_exit = state._handle_term_exit,
		})

		self:reset_state(state)
		self:attach_breakpoints(state)

		state.ensure_zmq(function(ok_zmq)
			-- ZMQ bootstrap happens asynchronously; warn the user if the background channel never comes up.
			if ok_zmq then
				return
			end
			vim.schedule(function()
				local notified = self:_notify_missing_deps(python_cmd, "failed to start ZMQ backend", zmq_deps)
				if not notified then
					vim.notify("ipybridge: failed to start ZMQ backend", vim.log.levels.WARN)
				end
			end)
		end)

		self:setup_terminal_keymaps(state)
		self:run_deferred_startup(state, {
			cwd = cwd,
			go_back = go_back,
			callback = cb,
		})
	end)
end

return Session
