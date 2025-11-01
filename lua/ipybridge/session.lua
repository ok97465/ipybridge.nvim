-- Session manager isolates terminal bootstrap logic from init.lua.
-- It keeps responsibilities focused and easier to extend.
local Session = {}
Session.__index = Session

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
	self.is_windows = opts.is_windows and true or false
	return self
end

local function resolve_sep()
	local loop = vim.loop or vim.uv
	local os_name = loop and loop.os_uname().sysname or ""
	if os_name == "Windows_NT" then
		return ";", loop and loop.os_getenv("PYTHONPATH") or ""
	end
	return ":", loop and loop.os_getenv("PYTHONPATH") or ""
end

function Session:build_console_env(state, conn_file)
	local extra = ""
	if state.config.simple_prompt then
		extra = extra .. " --simple-prompt"
	end
	local cmd_console = string.format("jupyter console --existing %s%s", conn_file, extra)
	local env = {
		IPYBRIDGE_CONSOLE_PATCH = "1",
		IPYBRIDGE_CONSOLE_PATCH_SILENT = "1",
	}
	local bp_file = self.breakpoints.get_file_path()
	if bp_file and #bp_file > 0 then
		env.IPYBRIDGE_BREAKPOINT_FILE = bp_file
	end
	local ok_py_path, py_module_path = pcall(self.py_module.path, "bootstrap_helpers.py")
	if ok_py_path and type(py_module_path) == "string" and #py_module_path > 0 then
		local py_root = vim.fs.dirname(py_module_path)
		if py_root and #py_root > 0 then
			local sep, current = resolve_sep()
			if current:find(py_root, 1, true) then
				env.PYTHONPATH = current
			elseif current ~= "" then
				env.PYTHONPATH = py_root .. sep .. current
			else
				env.PYTHONPATH = py_root
			end
		end
	end
	return cmd_console, env
end

function Session:reset_state(state)
	state._term_exit_expected = false
	state._helpers_sent = false
	state._helpers_pending = false
	if state._helpers_path then
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
	state._last_filters_signature = nil
	state._pending_exec = {}
	state._helpers_waiters = {}
end

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

function Session:setup_terminal_keymaps(state)
	pcall(function()
		local term = state.term_instance
		if not term then
			return
		end
		local buf = term.buf_id
		local goto_vi = state.goto_vi
		vim.keymap.set("t", "<leader>iv", function()
			if type(goto_vi) == "function" then
				goto_vi()
			end
		end, { buffer = buf, silent = true, desc = "IPy: Back to editor" })
		self.cmp_bridge.ensure()
		vim.keymap.set(
			"t",
			"<Tab>",
			self.handle_terminal_tab,
			{ buffer = buf, silent = true, desc = "IPy: Debug completion trigger" }
		)
	end)
end

function Session:collect_startup_instructions(state, cwd)
	local config = state.config
	local startup_magics = {}
	local warmup_code = nil

	if config.matplotlib_backend and #tostring(config.matplotlib_backend) > 0 then
		local raw_backend = tostring(config.matplotlib_backend)
		local lowered = raw_backend:lower()
		local backend_aliases = {
			qtagg = "qt",
			qt5agg = "qt",
			qt6agg = "qt",
			tkagg = "tk",
			macosx = "macosx",
			osx = "macosx",
		}
		local magic_backend = backend_aliases[lowered] or lowered
		table.insert(startup_magics, string.format("%%matplotlib %s", magic_backend))
		if self.is_windows then
			local is_qt = magic_backend == "qt" or magic_backend == "qt5" or magic_backend == "qt6"
			if is_qt then
				warmup_code = table.concat({
					"import matplotlib.pyplot as _ipybridge_warm_plt",
					"_ipybridge_warm_plt.ion()",
					"_ipybridge_warm_fig = _ipybridge_warm_plt.figure()",
					"try:",
					"    _ipybridge_warm_win = getattr(_ipybridge_warm_fig.canvas.manager, 'window', None)",
					"    if _ipybridge_warm_win is not None:",
					"        try:",
					"            _ipybridge_warm_win.setWindowTitle('Matplotlib')",
					"        except Exception:",
					"            pass",
					"        try:",
					"            _ipybridge_warm_win.show()",
					"        except Exception:",
					"            pass",
					"        for _ipybridge_warm_attr in ('showNormal', 'raise_', 'activateWindow'):",
					"            try:",
					"                getattr(_ipybridge_warm_win, _ipybridge_warm_attr)()",
					"            except Exception:",
					"                pass",
					"    _ipybridge_warm_plt.pause(0.25)",
					"finally:",
					"    try:",
					"        _ipybridge_warm_win = getattr(_ipybridge_warm_fig.canvas.manager, 'window', None)",
					"        if _ipybridge_warm_win is not None:",
					"            try:",
					"                _ipybridge_warm_win.close()",
					"            except Exception:",
					"                pass",
					"    except Exception:",
					"        pass",
					"    _ipybridge_warm_plt.close(_ipybridge_warm_fig)",
					"    del _ipybridge_warm_fig",
				}, "\n")
			end
		end
	end

	if config.ipython_colors and #tostring(config.ipython_colors) > 0 then
		local c = tostring(config.ipython_colors)
		table.insert(startup_magics, string.format("%%colors %s", c))
	end

	local ar = config.autoreload
	if ar == nil then
		ar = 2
	end
	local mode = tostring(ar)
	if mode == "1" or mode == "2" then
		table.insert(startup_magics, "%load_ext autoreload")
		table.insert(startup_magics, string.format("%%autoreload %s", mode))
	end

	local startup_stmt = nil
	local path_startup_script = self.fs.joinpath(cwd, config.startup_script)
	if self.utils.file_exists(path_startup_script) then
		startup_stmt = self.utils.exec_file_stmt(path_startup_script)
	end

	return {
		magics = startup_magics,
		warmup_code = warmup_code,
		startup_stmt = startup_stmt,
	}
end

function Session:run_deferred_startup(state, opts)
	local go_back = opts.go_back
	local callback = opts.callback
	local cwd = opts.cwd
	local delay = tonumber(state.config.sleep_ms_after_open) or 0

	vim.defer_fn(function()
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

---Open the terminal session.
---@param state table
---@param go_back boolean|nil
---@param cb function|nil
function Session:open(state, go_back, cb)
	local cwd = self.fn.getcwd()
	self.kernel.ensure(state.config.python_cmd, function(ok, conn_file)
		if not ok then
			vim.notify("ipybridge: failed to start Jupyter kernel", vim.log.levels.ERROR)
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
			if ok_zmq then
				return
			end
			vim.schedule(function()
				vim.notify("ipybridge: failed to start ZMQ backend", vim.log.levels.WARN)
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
