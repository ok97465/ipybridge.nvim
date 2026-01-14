-- Specs validating the session manager bootstrap, env building, and hooks.
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
			fnamemodify = function(path, modifier)
				if modifier == ":h" then
					return (path:gsub("[/\\][^/\\]+$", ""))
				end
				return path
			end,
			mkdir = function(_path, _opts) end,
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
	keymaps = {
		apply_terminal_defaults = function(set, opts)
			local my = package.loaded["ipybridge"]
			if not my then
				my = {
					goto_vi = function() end,
					run_file = function() end,
					debug_file = function() end,
					quit_debug = function() end,
					debug_step_over = function() end,
					debug_step_into = function() end,
					debug_step_out = function() end,
					debug_continue = function() end,
				}
				package.loaded["ipybridge"] = my
			end
			local function map(lhs, rhs, desc)
				if rhs == nil then
					return
				end
				set(lhs, rhs, { desc = desc })
			end
			map("<Tab>", opts.handle_tab, "IPy: Debug completion trigger")
			map("<C-c>", opts.interrupt, "IPy: Keyboard interrupt")
			map("<leader>iv", my.goto_vi, "IPy: Back to editor")
			map("<F5>", my.run_file, "IPy: Run file (%run)")
			map("<F6>", my.debug_file, "IPy: Debug file (%debugfile)")
			map("<S-F6>", my.quit_debug, "IPy: Quit debugger (!exit)")
			map("<F10>", my.debug_step_over, "IPy: Debug step over (F10)")
			map("<F11>", my.debug_step_into, "IPy: Debug step into (F11)")
			map("<S-F11>", my.debug_step_out, "IPy: Debug step out (Shift+F11)")
			map("<F12>", my.debug_continue, "IPy: Debug continue (F12)")
		end,
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
			state_path = function(filename)
				return "/tmp/ipybridge/" .. tostring(filename or "")
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

local function extend_with_keymap(env)
	local function deepcopy(value)
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for k, v in pairs(value) do
			copy[k] = deepcopy(v)
		end
		return copy
	end
	env.deepcopy = deepcopy
	env.keymaps = {}
	env.keymap = {
		set = function(mode, lhs, rhs, opts)
			table.insert(env.keymaps, {
				mode = mode,
				lhs = lhs,
				rhs = rhs,
				opts = opts,
			})
		end,
	}
	return env
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
		config = {},
	}
	local cmd, env = session:build_console_env(state, "conn.json")
	assert(not cmd:find("--simple-prompt", 1, true), "simple prompt flag should not be set")
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

it("setup_terminal_keymaps applies defaults and custom mappings", function()
	local vim_env = extend_with_keymap(posix_vim(""))
	vim_env.tbl_extend = function(_, base, extra)
		local merged = {}
		for k, v in pairs(base or {}) do
			merged[k] = v
		end
		for k, v in pairs(extra or {}) do
			merged[k] = v
		end
		return merged
	end
	_G.vim = vim_env
	local cmp_calls = 0
	local stub_module = {
		goto_vi = function() end,
		run_file = function() end,
		debug_file = function() end,
		quit_debug = function() end,
		debug_step_over = function() end,
		debug_step_into = function() end,
		debug_step_out = function() end,
		debug_continue = function() end,
	}
	local previous_module = package.loaded["ipybridge"]
	package.loaded["ipybridge"] = stub_module
	local session, deps = fresh_session({
		deps = {
			cmp_bridge = {
				ensure = function()
					cmp_calls = cmp_calls + 1
				end,
			},
		},
	})
	local state = {
		term_instance = { buf_id = 41 },
	config = {
		set_default_keymaps = true,
		terminal_keymaps = function(set)
			set("<C-z>", function() end, { silent = false, desc = "Custom" })
		end,
	},
	interrupt = function() end,
	}
	session:setup_terminal_keymaps(state)
	assert(cmp_calls == 1, "cmp bridge ensure should be called once")
	local seen = {}
	for _, map in ipairs(vim_env.keymaps) do
		seen[map.lhs] = map
		assert(map.mode == "t", string.format("mapping %s should target terminal mode", tostring(map.lhs)))
		assert(map.opts and map.opts.buffer == 41, "buffer-local mapping expected")
	end
	assert(seen["<Tab>"], "default <Tab> mapping missing")
	assert(
		seen["<Tab>"].rhs == deps.handle_terminal_tab,
		"default <Tab> should use terminal tab handler"
	)
	assert(seen["<leader>iv"], "default <leader>iv mapping missing")
	assert(
		seen["<leader>iv"].rhs == stub_module.goto_vi,
		"default <leader>iv should use ipybridge goto_vi"
	)
	local ctrl_c = seen["<C-c>"]
	assert(ctrl_c, "default <C-c> mapping missing")
	assert(ctrl_c.opts.silent == true, "default interrupt mapping should stay silent")
	assert(ctrl_c.opts.desc == "IPy: Keyboard interrupt", "default interrupt mapping should set description")
	assert(ctrl_c.rhs == state.interrupt, "default interrupt mapping should use session interrupt")
	local f5 = seen["<F5>"]
	assert(f5, "default <F5> mapping missing")
	assert(f5.rhs == stub_module.run_file, "default <F5> should use ipybridge run_file")
	assert(f5.opts.desc == "IPy: Run file (%run)", "default <F5> mapping should set description")
	local f6 = seen["<F6>"]
	assert(f6, "default <F6> mapping missing")
	assert(f6.rhs == stub_module.debug_file, "default <F6> should use ipybridge debug_file")
	assert(f6.opts.desc == "IPy: Debug file (%debugfile)", "default <F6> mapping should set description")
	local sf6 = seen["<S-F6>"]
	assert(sf6, "default <S-F6> mapping missing")
	assert(sf6.rhs == stub_module.quit_debug, "default <S-F6> should use ipybridge quit_debug")
	assert(sf6.opts.desc == "IPy: Quit debugger (!exit)", "default <S-F6> mapping should set description")
	local f10 = seen["<F10>"]
	assert(f10, "default <F10> mapping missing")
	assert(f10.rhs == stub_module.debug_step_over, "default <F10> should use ipybridge debug_step_over")
	assert(f10.opts.desc == "IPy: Debug step over (F10)", "default <F10> mapping should set description")
	local f11 = seen["<F11>"]
	assert(f11, "default <F11> mapping missing")
	assert(f11.rhs == stub_module.debug_step_into, "default <F11> should use ipybridge debug_step_into")
	assert(f11.opts.desc == "IPy: Debug step into (F11)", "default <F11> mapping should set description")
	local sf11 = seen["<S-F11>"]
	assert(sf11, "default <S-F11> mapping missing")
	assert(sf11.rhs == stub_module.debug_step_out, "default <S-F11> should use ipybridge debug_step_out")
	assert(sf11.opts.desc == "IPy: Debug step out (Shift+F11)", "default <S-F11> mapping should set description")
	local f12 = seen["<F12>"]
	assert(f12, "default <F12> mapping missing")
	assert(f12.rhs == stub_module.debug_continue, "default <F12> should use ipybridge debug_continue")
	assert(f12.opts.desc == "IPy: Debug continue (F12)", "default <F12> mapping should set description")
	local custom = seen["<C-z>"]
	assert(custom, "custom <C-z> mapping missing")
	assert(custom.opts.silent == false, "custom mapping should keep explicit silent option")
	assert(custom.opts.desc == "Custom", "custom mapping should keep description")
	package.loaded["ipybridge"] = previous_module
end)

it("setup_terminal_keymaps skips defaults when disabled", function()
	local vim_env = extend_with_keymap(posix_vim(""))
	_G.vim = vim_env
	local session = fresh_session()
	local state = {
		term_instance = { buf_id = 99 },
	config = {
		set_default_keymaps = false,
		terminal_keymaps = function(set)
			set("<C-x>", "<C-x>", { desc = "noop" })
		end,
	},
	}
	session:setup_terminal_keymaps(state)
	local seen = {}
	for _, map in ipairs(vim_env.keymaps) do
		seen[map.lhs] = map
	end
	assert(seen["<C-x>"], "custom map should be applied when defaults disabled")
	assert(not seen["<leader>iv"], "default <leader>iv should not be applied when disabled")
	assert(not seen["<Tab>"], "default <Tab> should not be applied when disabled")
	assert(not seen["<C-c>"], "default <C-c> should not be applied when disabled")
	assert(not seen["<F5>"], "default <F5> should not be applied when disabled")
	assert(not seen["<F6>"], "default <F6> should not be applied when disabled")
	assert(not seen["<S-F6>"], "default <S-F6> should not be applied when disabled")
	assert(not seen["<F10>"], "default <F10> should not be applied when disabled")
	assert(not seen["<F11>"], "default <F11> should not be applied when disabled")
	assert(not seen["<S-F11>"], "default <S-F11> should not be applied when disabled")
	assert(not seen["<F12>"], "default <F12> should not be applied when disabled")
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
		_debugfile_imports_signature = {},
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
	assert(state._debugfile_imports_signature == nil, "debugfile imports signature not cleared")
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
