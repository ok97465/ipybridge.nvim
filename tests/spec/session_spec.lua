package.path = table.concat({
	"tests/?.lua",
	"tests/?/init.lua",
	"lua/?.lua",
	"lua/?/init.lua",
	package.path,
}, ";")

local results = {}

local function record(name, ok, err)
	table.insert(results, { name = name, ok = ok, err = err })
	if ok then
		io.write(string.format("[PASS] %s\n", name))
	else
		io.write(string.format("[FAIL] %s: %s\n", name, err))
	end
end

local function it(name, fn)
	local ok, err = pcall(fn)
	record(name, ok, err)
end

local function base_deps()
	local TermIpy = {}
	function TermIpy:new()
		local obj = { scroll_to_bottom = function() end }
		return setmetatable(obj, { __index = self })
	end

	return {
		fn = {
			getcwd = function()
				return "/tmp/project"
			end,
		},
		kernel = {
			ensure = function(_python_cmd, _cb) end,
		},
		term_helper = {
			TermIpy = TermIpy,
		},
		dispatch = {
			handle = function(_) end,
		},
		observe_terminal_chunk = function(_) end,
		handle_terminal_tab = function() end,
		cmp_bridge = {
			ensure = function() end,
		},
		breakpoints = {
			get_file_path = function()
				return nil
			end,
			attach_session = function(_) end,
			sync_with_kernel = function() end,
		},
		fs = {
			joinpath = function(...)
				local parts = { ... }
				return table.concat(parts, "/")
			end,
		},
		utils = {
			file_exists = function(_path)
				return false
			end,
			exec_file_stmt = function(_path)
				return nil
			end,
		},
		py_module = {
			path = function(_module)
				return nil
			end,
		},
		exec_with_pipeline = function(_payload, _opts) end,
		term_send = function(_payload) end,
		warn_user = function(_msg) end,
	}
end

local function fresh_session(opts)
	opts = opts or {}
	package.loaded["ipybridge.session"] = nil
	local Session = require("ipybridge.session")
	local deps = base_deps()
	if opts.deps then
		for key, value in pairs(opts.deps) do
			deps[key] = value
		end
	end
	local session = Session.new(deps)
	if opts.is_windows ~= nil then
		session.is_windows = opts.is_windows
	end
	return session, deps
end

local function windows_vim(py_path)
	py_path = py_path or ""
	return {
		loop = {
			os_uname = function()
				return { sysname = "Windows_NT" }
			end,
			os_getenv = function(name)
				if name == "PYTHONPATH" then
					return py_path
				end
				return ""
			end,
		},
		fs = {
			dirname = function(path)
				return (path:gsub("[/\\][^/\\]+$", ""))
			end,
		},
	}
end

local function posix_vim(py_path)
	py_path = py_path or ""
	return {
		loop = {
			os_uname = function()
				return { sysname = "Linux" }
			end,
			os_getenv = function(name)
				if name == "PYTHONPATH" then
					return py_path
				end
				return ""
			end,
		},
		fs = {
			dirname = function(path)
				return (path:gsub("[/\\][^/\\]+$", ""))
			end,
		},
	}
end

it("build_console_env merges pythonpath on Windows", function()
	_G.vim = windows_vim("C:\\helpers;C:\\existing")
	local session = fresh_session()
	session.breakpoints.get_file_path = function()
		return "C:\\tmp\\breakpoints.json"
	end
	session.py_module.path = function(module)
		assert(module == "bootstrap_helpers.py", "unexpected module request")
		return "C:\\helpers\\bootstrap_helpers.py"
	end
	local state = {
		config = {
			simple_prompt = true,
		},
	}
	local cmd, env = session:build_console_env(state, "conn.json")
	assert(cmd:find("--simple-prompt", 1, true), "expected simple prompt flag")
	assert(env.IPYBRIDGE_BREAKPOINT_FILE == "C:\\tmp\\breakpoints.json", "breakpoint file missing")
	assert(
		env.PYTHONPATH == "C:\\helpers;C:\\existing",
		string.format("pythonpath should keep existing order, got %s", tostring(env.PYTHONPATH))
	)
end)

it("build_console_env sets pythonpath when missing on posix", function()
	_G.vim = posix_vim("")
	local session = fresh_session()
	session.py_module.path = function(module)
		assert(module == "bootstrap_helpers.py", "unexpected module request")
		return "/opt/ipybridge/bootstrap_helpers.py"
	end
	local state = {
		config = {},
	}
	local cmd, env = session:build_console_env(state, "/tmp/conn.json")
	assert(cmd:find("/tmp/conn.json", 1, true), "connection file not in command")
	assert(
		env.PYTHONPATH == "/opt/ipybridge",
		string.format("pythonpath should be set to helper root, got %s", tostring(env.PYTHONPATH))
	)
	assert(env.IPYBRIDGE_BREAKPOINT_FILE == nil, "breakpoint file should be absent")
end)

it("collect_startup_instructions assembles warmup and startup script", function()
	local session = fresh_session({ is_windows = true })
	session.py_module.path = function(_module)
		return nil
	end
	session.utils.file_exists = function(path)
		assert(path == "/workspace/startup.py", "unexpected startup script path")
		return true
	end
	session.utils.exec_file_stmt = function(path)
		assert(path == "/workspace/startup.py", "unexpected exec path")
		return "print('hello')"
	end
	local state = {
		config = {
			matplotlib_backend = "QtAgg",
			ipython_colors = "linux",
			autoreload = 1,
			startup_script = "startup.py",
		},
	}
	local instructions = session:collect_startup_instructions(state, "/workspace")
	assert(#instructions.magics == 4, "expected four startup magics")
	local magics_blob = table.concat(instructions.magics, " ")
	assert(magics_blob:find("%matplotlib qt", 1, true), "matplotlib magic missing")
	assert(magics_blob:find("%colors linux", 1, true), "colors magic missing")
	assert(magics_blob:find("%load_ext autoreload", 1, true), "load_ext missing")
	assert(magics_blob:find("%autoreload 1", 1, true), "autoreload mode missing")
	assert(instructions.warmup_code and instructions.warmup_code:find("setWindowTitle", 1, true), "warmup code not generated")
	assert(instructions.startup_stmt == "print('hello')", "startup stmt mismatch")
end)

it("reset_state clears transient fields and removes files", function()
	local session = fresh_session()
	local removed = {}
	local original_remove = os.remove
	os.remove = function(path)
		table.insert(removed, path)
		return true
	end
	local state = {
		_helpers_path = "/tmp/helpers.py",
		_term_exit_expected = true,
		_helpers_sent = true,
		_helpers_pending = true,
		_runcell_sent = true,
		_runcell_path = "/tmp/runcell.py",
		_runcell_pending = true,
		_runcell_waiters = { 1 },
		_zmq_ready = true,
		_last_filters_signature = {},
		_pending_exec = { key = true },
		_helpers_waiters = { 1 },
	}
	session:reset_state(state)
	os.remove = original_remove
	assert(state._helpers_path == nil, "helpers path not cleared")
	assert(state._runcell_path == nil, "runcell path not cleared")
	assert(#removed == 2, "expected both temp files removed")
	assert(state._helpers_sent == false, "helpers sent flag not reset")
	assert(state._runcell_sent == false, "runcell sent flag not reset")
	assert(state._helpers_pending == false, "helpers pending flag not reset")
	assert(state._runcell_pending == false, "runcell pending flag not reset")
	assert(next(state._runcell_waiters) == nil, "runcell waiters not cleared")
	assert(state._zmq_ready == false, "zmq flag not reset")
	assert(state._last_filters_signature == nil, "filters signature not cleared")
	assert(next(state._pending_exec) == nil, "pending exec queue not cleared")
	assert(next(state._helpers_waiters) == nil, "helpers waiters not cleared")
end)

it("run_deferred_startup dispatches instructions and handles errors", function()
	local warnings = {}
	local exec_calls = {}
	local sent_stmt
	local helpers_called = 0
	local filters_called = 0
	local ensure_called = false
	local sync_called = 0
	local go_back_cmds = {}
	local callback_arg

	_G.vim = {
		defer_fn = function(cb, delay)
			assert(delay == 25, "unexpected defer delay")
			cb()
		end,
		cmd = function(cmd)
			table.insert(go_back_cmds, cmd)
		end,
		log = {
			levels = {
				WARN = "WARN",
			},
		},
	}

	local session = fresh_session()
	session.exec_with_pipeline = function(payload, opts)
		table.insert(exec_calls, { payload = payload, opts = opts })
	end
	session.warn_user = function(msg)
		table.insert(warnings, msg)
	end
	session.term_send = function(stmt)
		sent_stmt = stmt
	end
	session.breakpoints.sync_with_kernel = function()
		sync_called = sync_called + 1
	end

	local term_instance = {
		scrolled = false,
		scroll_to_bottom = function(self)
			self.scrolled = true
		end,
	}

	local state = {
		config = {
			sleep_ms_after_open = 25,
		},
		is_open = function()
			return true
		end,
		_send_helpers_if_needed = function()
			helpers_called = helpers_called + 1
		end,
		_sync_var_filters = function()
			filters_called = filters_called + 1
		end,
		_ensure_runcell_helpers = function()
			ensure_called = true
		end,
		term_instance = term_instance,
	}
	session.collect_startup_instructions = function(_, session_state, cwd)
		assert(cwd == "/cwd", "cwd not forwarded")
		assert(session_state == state, "state mismatched")
		return {
			magics = { "%matplotlib inline" },
			warmup_code = "print('warm')",
			startup_stmt = "run_script()",
		}
	end

	session:run_deferred_startup(state, {
		cwd = "/cwd",
		go_back = true,
		callback = function(ok)
			callback_arg = ok
		end,
	})

	assert(helpers_called == 1, "helpers were not sent")
	assert(filters_called == 1, "var filters not synced")
	assert(sync_called == 1, "breakpoints not synced")
	assert(#exec_calls == 3, "expected three pipeline calls")
	assert(exec_calls[1].payload == "%matplotlib inline\n", "magics payload mismatch")
	assert(exec_calls[2].payload == "print('warm')\n", "warmup payload mismatch")
	assert(exec_calls[3].payload == "run_script()", "startup stmt payload mismatch")
	assert(term_instance.scrolled, "terminal not scrolled to bottom")
	assert(go_back_cmds[1] == "wincmd p", "go back command not issued")
	assert(callback_arg == true, "callback not invoked with success flag")
	assert(ensure_called, "runcell helpers not ensured")

	exec_calls[1].opts.on_error("boom")
	assert(warnings[#warnings]:find("startup magics", 1, true), "magics warning not emitted")
	exec_calls[2].opts.on_error("oops")
	assert(warnings[#warnings]:find("matplotlib warmup", 1, true), "warmup warning not emitted")
	exec_calls[3].opts.on_error("fail")
	assert(warnings[#warnings]:find("startup script", 1, true), "startup script warning not emitted")
	assert(sent_stmt == "run_script()", "startup script should replay in terminal")
end)

it("run_deferred_startup aborts when terminal is closed", function()
	local session = fresh_session()
	local called = false
	local exec_calls = 0

	_G.vim = {
		defer_fn = function(cb, _delay)
			cb()
		end,
		log = {
			levels = {
				WARN = "WARN",
			},
		},
	}

	session.collect_startup_instructions = function()
		called = true
		return {}
	end
	session.exec_with_pipeline = function()
		exec_calls = exec_calls + 1
	end

	local state = {
		config = {},
		is_open = function()
			return false
		end,
		_send_helpers_if_needed = function()
			error("should not be called")
		end,
		_sync_var_filters = function()
			error("should not be called")
		end,
		_ensure_runcell_helpers = function()
			error("should not be called")
		end,
	}

	session:run_deferred_startup(state, {
		cwd = "/cwd",
		go_back = true,
		callback = function()
			error("callback should not fire when session closed")
		end,
	})

	assert(called == false, "startup instructions should not be collected")
	assert(exec_calls == 0, "pipeline should not execute when closed")
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("session_spec failed")
end

return true
