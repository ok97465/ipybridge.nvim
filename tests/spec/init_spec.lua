-- Specs exercising the top-level ipybridge module wiring and commands.
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

local function stub_vim(ctx)
	local prev_vim = _G.vim
	local keymaps = {}
	ctx.keymaps = keymaps
	local function add_keymap(mode, lhs, rhs, opts)
		table.insert(keymaps, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
	end

	local bo_store = {}

	local vim_stub = {
		notify = function(msg, level)
			table.insert(ctx.notifications, { message = msg, level = level })
		end,
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
		defer_fn = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
		log = {
			levels = { WARN = "WARN", ERROR = "ERROR" },
		},
		inspect = function()
			return "inspect"
		end,
		tbl_deep_extend = function(_, base, extra)
			local merged = {}
			if type(base) == "table" then
				for k, v in pairs(base) do
					merged[k] = v
				end
			end
			if type(extra) == "table" then
				for k, v in pairs(extra) do
					merged[k] = v
				end
			end
			return merged
		end,
		validate = function()
			return true
		end,
		regex = function(pattern)
			return {
				match_str = function(_, text)
					if type(text) ~= "string" then
						return nil
					end
					local matched = text:match("^# %%+")
					if matched then
						return 0, #matched
					end
					return nil
				end,
			}
		end,
		fn = {
			has = function()
				return 1
			end,
			getcwd = function()
				return ctx.cwd
			end,
			expand = function(expr)
				if expr == "%:p" then
					return ctx.buffer_name
				end
				return expr
			end,
			tempname = function()
				ctx.temp_index = ctx.temp_index + 1
				return string.format("/tmp/temp%d", ctx.temp_index)
			end,
			fnamemodify = function(path)
				return path .. "_abs"
			end,
			writefile = function(lines, path)
				table.insert(ctx.file_writes, { lines = lines, path = path })
				return true
			end,
		},
		keymap = {
			set = add_keymap,
		},
		uv = {
			os_uname = function()
				return { sysname = "Darwin" }
			end,
			os_getenv = function()
				return ctx.python_path or ""
			end,
			fs_stat = function()
				return nil
			end,
		},
		loop = {
			os_uname = function()
				return { sysname = "Darwin" }
			end,
			os_getenv = function()
				return ctx.python_path or ""
			end,
			fs_open = function()
				error("fs_open not expected in init spec")
			end,
			fs_close = function()
				return true
			end,
			fs_fstat = function()
				return { size = 0 }
			end,
			fs_read = function()
				return ""
			end,
		},
		fs = {
			joinpath = function(...)
				return table.concat({ ... }, "/")
			end,
			dirname = function(_)
				return ctx.cwd .. "/lua"
			end,
		},
		cmd = function(cmd)
			table.insert(ctx.commands, cmd)
		end,
	}

	vim_stub.on_key = function() end
	vim_stub.schedule_wrap = function(cb)
		return cb
	end

	vim_stub.iter = function(tbl)
		local data = tbl or {}
		local obj = {}
		function obj:enumerate()
			local enum = {}
			function enum:rev()
				local i = #data + 1
				local function rev_iter(_, _)
					i = i - 1
					if i >= 1 then
						return i, data[i]
					end
				end
				return rev_iter, nil, nil
			end
			return setmetatable(enum, {
				__call = function()
					return ipairs(data)
				end,
			})
		end
		return obj
	end

	vim_stub.api = {
		nvim_replace_termcodes = function(str)
			return str
		end,
		nvim_feedkeys = function(keys, mode)
			ctx.feedkeys = { keys = keys, mode = mode }
		end,
		nvim_list_bufs = function()
			return {}
		end,
		nvim_buf_is_loaded = function()
			return false
		end,
		nvim_create_autocmd = function() end,
		nvim_create_augroup = function()
			return 1
		end,
		nvim_create_user_command = function() end,
		nvim_get_mode = function()
			return { mode = "t" }
		end,
		nvim_get_current_buf = function()
			return 1
		end,
		nvim_buf_get_name = function()
			return ctx.buffer_name
		end,
		nvim_win_get_cursor = function()
			return { ctx.cursor_line or 1, 0 }
		end,
		nvim_win_set_cursor = function(_, pos)
			ctx.cursor_set = pos
		end,
		nvim_buf_set_option = function() end,
		nvim_set_option_value = function() end,
		nvim_win_is_valid = function()
			return true
		end,
		nvim_buf_line_count = function()
			local lines = ctx.buf_lines
			if type(lines) == "table" and #lines > 0 then
				return #lines
			end
			return 1
		end,
		nvim_buf_get_lines = function(_, start_idx, stop_idx)
			local src = ctx.buf_lines or {}
			local total = #src
			local last = stop_idx
			if not last or last < 0 or last > total then
				last = total
			end
			local first = math.max((start_idx or 0) + 1, 1)
			local out = {}
			for i = first, last do
				out[#out + 1] = src[i]
			end
			return out
		end,
		nvim_buf_is_valid = function()
			return true
		end,
		nvim_get_current_win = function()
			return 1
		end,
	}

	vim_stub.bo = setmetatable({}, {
		__index = function(_, key)
			if not bo_store[key] then
				bo_store[key] = { buftype = "", filetype = "python", modified = false }
			end
			return bo_store[key]
		end,
		__newindex = function(_, key, value)
			bo_store[key] = value
		end,
	})

	_G.vim = vim_stub
	return prev_vim
end

local function fresh_init()
	local ctx = {
		notifications = {},
		commands = {},
		cwd = "/workspace",
		buffer_name = "/workspace/main.py",
		temp_index = 0,
		file_writes = {},
	}

	local modules = {
		"ipybridge",
		"ipybridge.init",
		"ipybridge.core.dispatch",
		"ipybridge.kernel",
		"ipybridge.term_ipy",
		"ipybridge.utils",
		"ipybridge.keymaps",
		"ipybridge.py_module",
		"ipybridge.debug.scope",
		"ipybridge.debug.breakpoints",
		"ipybridge.core.debug",
		"ipybridge.core.terminal",
		"ipybridge.cmp_bridge",
		"ipybridge.exec_magics",
		"ipybridge.zmq_client",
	}
	for _, name in ipairs(modules) do
		package.loaded[name] = nil
		package.preload[name] = nil
	end

	package.preload["ipybridge.core.dispatch"] = function()
		return {
			handle = function(msg)
				ctx.last_dispatch = msg
			end,
		}
	end

	package.preload["ipybridge.kernel"] = function()
		return {
			ensure = function(python_cmd, cb)
				ctx.kernel_calls = ctx.kernel_calls or {}
				table.insert(ctx.kernel_calls, { python_cmd = python_cmd })
				if cb then
					cb(true, ctx.kernel_conn or "/tmp/conn.json")
				end
			end,
		}
	end

	package.preload["ipybridge.term_ipy"] = function()
		local TermIpy = {}
		function TermIpy:new(cmd, cwd, opts)
			ctx.term_invocation = {
				cmd = cmd,
				cwd = cwd,
				opts = opts,
			}
			ctx.term_payloads = {}
			local instance = {
				job_id = 7,
				buf_id = 12,
			}
			function instance:send(payload)
				table.insert(ctx.term_payloads, payload)
			end
			function instance:scroll_to_bottom()
				ctx.scrolled = true
			end
			return instance
		end
		return { TermIpy = TermIpy }
	end

	package.preload["ipybridge.utils"] = function()
		return {
			exec_file_stmt = function(path)
				ctx.exec_stmt = path
				return "exec:" .. tostring(path)
			end,
			file_exists = function(target)
				if ctx.file_exists ~= nil then
					return ctx.file_exists
				end
				if ctx.file_exists_map and target then
					local flag = ctx.file_exists_map[target]
					if flag ~= nil then
						return flag
					end
				end
				return false
			end,
			py_quote_single = function(text)
				ctx.last_py_quote_single = text
				return text
			end,
			py_quote_double = function(text)
				ctx.last_py_quote_double = text
				return text
			end,
			send_exec_block = function(block)
				ctx.last_exec_block = block
				return "exec_block:" .. tostring(block)
			end,
			paste_block = function(lines_tbl)
				ctx.paste_payload = lines_tbl
				return "paste"
			end,
		}
	end

	package.preload["ipybridge.keymaps"] = function()
		return {
			apply_defaults = function()
				ctx.keymaps_applied = true
			end,
			apply_buffer = function() end,
		}
	end

	package.preload["ipybridge.debug.scope"] = function()
		return {
			sanitize_scope = function(scope)
				return scope
			end,
		}
	end

	package.preload["ipybridge.debug.breakpoints"] = function()
		return {
			ensure_support = function()
				ctx.breakpoints_support = true
			end,
			get_file_path = function()
				return ctx.breakpoint_file or "/tmp/breakpoints.json"
			end,
			attach_session = function(opts)
				ctx.attached_breakpoints = opts
			end,
			sync_with_kernel = function()
				ctx.breakpoints_synced = true
			end,
			push = function()
				ctx.breakpoints_pushed = (ctx.breakpoints_pushed or 0) + 1
			end,
		}
	end

	package.preload["ipybridge.py_module"] = function()
		return {
			path = function()
				return "/workspace/python/bootstrap_helpers.py"
			end,
			base64 = function()
				return "b64"
			end,
			source = function()
				return 'print("helpers")'
			end,
		}
	end

	package.preload["ipybridge.cmp_bridge"] = function()
		return {
			ensure = function()
				ctx.cmp_ensure = (ctx.cmp_ensure or 0) + 1
				return true
			end,
			trigger = function()
				ctx.cmp_trigger = true
				return true
			end,
		}
	end

	package.preload["ipybridge.exec_magics"] = function()
		return {
			build = function()
				return 'print("magic")'
			end,
		}
	end

	package.preload["ipybridge.zmq_client"] = function()
		return {
			start = function(...)
				ctx.zmq_start = { ... }
				return true
			end,
			request = function(op, args, cb)
				ctx.zmq_requests = ctx.zmq_requests or {}
				table.insert(ctx.zmq_requests, { op = op, args = args })
				if cb then
					if op == "ping" then
						cb({ ok = true, tag = "pong" })
					else
						cb({ ok = true, tag = op })
					end
				end
				return true
			end,
			is_running = function()
				return true
			end,
			stop = function() end,
		}
	end

	local prev_vim = stub_vim(ctx)
	local init_mod = require("ipybridge.init")
	_G.vim = prev_vim

	init_mod.ensure_zmq = function(cb)
		ctx.zmq_calls = (ctx.zmq_calls or 0) + 1
		if cb then
			cb(true)
		end
		return true
	end

	init_mod._send_helpers_if_needed = function()
		ctx.helpers_sent = true
		return true
	end

	init_mod._sync_var_filters = function()
		ctx.filters_synced = true
	end

	return init_mod, ctx
end

it("open starts console and attaches breakpoint session", function()
	local init_mod, ctx = fresh_init()
	local cb_ok = nil
	init_mod.open(false, function(ok)
		cb_ok = ok
	end)

	assert(
		ctx.kernel_calls and ctx.kernel_calls[1].python_cmd == "python3",
		"expected kernel.ensure to use default python"
	)
	assert(ctx.term_invocation, "TermIpy:new should be invoked")
	assert(ctx.term_invocation.cmd:match("jupyter console --existing"), "expected jupyter console command")
	assert(ctx.term_invocation.cwd == ctx.cwd, "expected cwd to be forwarded")
	local env = ctx.term_invocation.opts and ctx.term_invocation.opts.env or {}
	assert(
		env.IPYBRIDGE_BREAKPOINT_FILE == ctx.breakpoint_file or env.IPYBRIDGE_BREAKPOINT_FILE == "/tmp/breakpoints.json",
		"breakpoint file not forwarded"
	)
	assert(type(ctx.attached_breakpoints) == "table", "breakpoints.attach_session not called")
	assert(ctx.zmq_calls == 1, "ensure_zmq should be invoked once")
	assert(ctx.helpers_sent == true, "helpers should be sent during setup")
	assert(ctx.filters_synced == true, "var filters should be synced")
	assert(ctx.scrolled == true, "terminal should scroll to bottom")
	assert(cb_ok == true, "callback should receive success flag")
	assert(init_mod.is_open() == true, "terminal should report open state")

	local attached_exec = ctx.attached_breakpoints.exec
	assert(type(attached_exec) == "function", "exec handler missing")
	attached_exec("payload-1", { on_success = function() end })
	local payload_routed = false
	for _, req in ipairs(ctx.zmq_requests or {}) do
		if req.op == "exec" and type(req.args) == "table" and req.args.code == "payload-1" then
			payload_routed = true
			break
		end
	end
	assert(payload_routed, "payload should route through ZMQ exec")

	local keymap_seen = false
	for _, entry in ipairs(ctx.keymaps) do
		if entry.mode == "t" and entry.lhs == "<Tab>" then
			keymap_seen = true
			break
		end
	end
	assert(keymap_seen, "<Tab> terminal mapping should be applied")
end)

it("run_file waits for runcell helpers before dispatch", function()
	local init_mod, ctx = fresh_init()
	init_mod.run_file()

	local helper_request = false
	for _, req in ipairs(ctx.zmq_requests or {}) do
		if req.op == "exec" and type(req.args) == "table" and tostring(req.args.code):find('print("magic")') then
			helper_request = true
			break
		end
	end
	assert(helper_request, "helper bootstrap should execute via ZMQ")

	local runfile_idx
	for idx, payload in ipairs(ctx.term_payloads or {}) do
		if payload:match("runfile%(") then
			runfile_idx = idx
			break
		end
	end
	assert(runfile_idx, "runfile command should be sent")
end)

it("run_cell defers runcell call until helpers are ready", function()
	local init_mod, ctx = fresh_init()
	ctx.file_exists = true
	ctx.buf_lines = {
		"# %% cell1",
		'print("top")',
		"# %% cell2",
		'print("bottom")',
	}
	ctx.cursor_line = 2

	init_mod.run_cell()

	local helper_request = false
	for _, req in ipairs(ctx.zmq_requests or {}) do
		if req.op == "exec" and type(req.args) == "table" and tostring(req.args.code):find('print("magic")') then
			helper_request = true
			break
		end
	end
	assert(helper_request, "helper bootstrap should execute via ZMQ")

	local runcell_idx
	for idx, payload in ipairs(ctx.term_payloads or {}) do
		if payload:match("runcell%(") then
			runcell_idx = idx
			break
		end
	end
	assert(runcell_idx, "runcell command should be sent")
end)

it("run_cell keeps debug state when active", function()
	local init_mod, ctx = fresh_init()
	ctx.file_exists = true
	ctx.buf_lines = {
		"# %% cell1",
		'print("top")',
		"# %% cell2",
		'print("bottom")',
	}
	ctx.cursor_line = 2
	init_mod._debug_active = true
	init_mod._debug_status_active = true

	init_mod.run_cell()

	local runcell_idx
	for idx, payload in ipairs(ctx.term_payloads or {}) do
		if payload:match("runcell%(") then
			runcell_idx = idx
			break
		end
	end
	assert(runcell_idx, "runcell command should be sent")
	assert(init_mod._debug_active == true, "run_cell should not clear debug state")
	assert(init_mod._debug_status_active == true, "run_cell should not clear debug status")
end)

it("debug_cell pushes breakpoints and triggers debugcell command", function()
	local init_mod, ctx = fresh_init()
	ctx.file_exists = true
	ctx.buf_lines = {
		"# %% cell1",
		'print("top")',
		"# %% cell2",
		'print("bottom")',
	}
	ctx.cursor_line = 4

	init_mod.debug_cell()

	local helper_request = false
	for _, req in ipairs(ctx.zmq_requests or {}) do
		if req.op == "exec" and type(req.args) == "table" and tostring(req.args.code):find('print("magic")') then
			helper_request = true
			break
		end
	end
	assert(helper_request, "helper bootstrap should execute via ZMQ")
	assert(ctx.breakpoints_pushed == 1, "breakpoints should be pushed before debugcell")

	local debugcell_idx
	for idx, payload in ipairs(ctx.term_payloads or {}) do
		if payload:match("debugcell%(") then
			debugcell_idx = idx
			break
		end
	end
	assert(debugcell_idx, "debugcell command should be sent")
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("init_spec failed")
end

return true
