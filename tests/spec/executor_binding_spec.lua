-- Specs confirming the executor binds helpers/runcell uploads correctly.
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

local function setup_env()
	local fn = {
		has = function()
			return 1
		end,
		tempname = function()
			return "/tmp/ipybridge_spec"
		end,
		writefile = function()
			return true
		end,
		fnamemodify = function(path, _)
			return path
		end,
		bufadd = function()
			return 1
		end,
		bufload = function() end,
		jobstop = function() end,
	}

	local api = {
		nvim_replace_termcodes = function(_, _, _, _)
			return ""
		end,
		nvim_feedkeys = function() end,
		nvim_list_bufs = function()
			return {}
		end,
		nvim_buf_is_loaded = function()
			return false
		end,
		nvim_win_is_valid = function()
			return false
		end,
		nvim_buf_set_option = function() end,
		nvim_buf_get_lines = function()
			return {}
		end,
		nvim_buf_line_count = function()
			return 0
		end,
		nvim_buf_get_name = function()
			return ""
		end,
		nvim_create_buf = function()
			return 1
		end,
		nvim_open_win = function()
			return 1
		end,
		nvim_set_option_value = function() end,
		nvim_win_get_buf = function()
			return 1
		end,
		nvim_win_get_cursor = function()
			return { 1, 0 }
		end,
		nvim_win_set_cursor = function() end,
		nvim_win_set_buf = function() end,
		nvim_get_current_win = function()
			return 1
		end,
		nvim_set_current_win = function() end,
		nvim_win_close = function() end,
		nvim_buf_delete = function() end,
	}

	_G.vim = {
		fn = fn,
		api = api,
		o = { columns = 120, lines = 60 },
		loop = {
			os_uname = function()
				return { sysname = "Test" }
			end,
			os_getenv = function()
				return ""
			end,
		},
		uv = {
			os_uname = function()
				return { sysname = "Test" }
			end,
			new_timer = function()
				return {
					start = function() end,
					stop = function() end,
					close = function() end,
				}
			end,
			now = function()
				return 0
			end,
			fs_stat = function()
				return nil
			end,
		},
		iter = function(tbl)
			local iterator = {}
			function iterator:enumerate()
				local i = 0
				return function()
					i = i + 1
					if tbl[i] ~= nil then
						return i, tbl[i]
					end
				end
			end
			function iterator:rev()
				local i = #tbl + 1
				return function()
					i = i - 1
					if i > 0 then
						return i, tbl[i]
					end
				end
			end
			return iterator
		end,
		defer_fn = function(fn_cb)
			fn_cb()
		end,
		schedule = function(fn_cb)
			fn_cb()
		end,
		notify = function() end,
		cmd = function() end,
		list_extend = function(dst, src)
			for _, v in ipairs(src) do
				dst[#dst + 1] = v
			end
			return dst
		end,
	}

	package.loaded["ipybridge.utils"] = {
		exec_file_stmt = function()
			return ""
		end,
		paste_block = function()
			return ""
		end,
		send_exec_block = function()
			return ""
		end,
		py_quote_single = function()
			return ""
		end,
		py_quote_double = function()
			return ""
		end,
		file_exists = function()
			return false
		end,
		selection_line_range = function()
			return nil
		end,
	}

	package.loaded["ipybridge.keymaps"] = {
		apply_defaults = function() end,
		apply_buffer = function() end,
	}

	package.loaded["ipybridge.kernel"] = {
		ensure = function(_, cb)
			cb(true, "/tmp/connection.json")
		end,
		ensure_conn_file = function(_, cb)
			cb(true, "/tmp/connection.json")
		end,
		stop = function() end,
	}

	package.loaded["ipybridge.py_module"] = {
		source = function()
			return ""
		end,
		base64 = function()
			return ""
		end,
	}

	package.loaded["ipybridge.debug.vars"] = {
		digest_snapshot = function()
			return {}
		end,
		current_scope = function()
			return {}
		end,
		preview_payload = function()
			return nil
		end,
		push_to_explorer = function() end,
	}

	package.loaded["ipybridge.debug.breakpoints"] = {
		ensure_support = function() end,
		refresh_signs = function() end,
		get_file_path = function()
			return nil
		end,
		attach_session = function(opts)
			vim.g__exec_handler = opts.exec
		end,
		sync_with_kernel = function() end,
		toggle_current_line = function() end,
		on_session_close = function() end,
	}

	package.loaded["ipybridge.cmp_bridge"] = {
		ensure = function()
			return true
		end,
		trigger = function()
			return true
		end,
	}

	package.loaded["ipybridge.debug.completion"] = {}

	package.loaded["ipybridge.dispatch"] = {
		handle = function() end,
	}

	package.loaded["ipybridge.term_ipy"] = {
		TermIpy = {
			new = function()
				return {
					buf_id = 1,
					job_id = 1,
					send = function() end,
					scroll_to_bottom = function() end,
					startinsert = function() end,
					show = function() end,
				}
			end,
		},
	}

	package.loaded["ipybridge.executor"] = {
		new = function(state, opts)
			return setmetatable({
				state = state,
				opts = opts,
			}, {
				__index = {
					queue_exec = function() end,
					after_helpers = function(_, cb)
						if cb then
							cb(true)
						end
					end,
					exec_with_pipeline = function() end,
					flush_pending_exec = function() end,
					fail_pending_exec = function() end,
					ensure_runcell_helpers = function() end,
					ensure_helpers = function() end,
					ensure_zmq = function(_, cb)
						if cb then
							cb(true)
						end
					end,
				},
			})
		end,
	}

	package.loaded["ipybridge.var_explorer"] = {
		open = function() end,
		on_vars = function() end,
	}

	package.loaded["ipybridge.data_viewer"] = {
		on_preview = function() end,
		open = function() end,
	}

	package.loaded["ipybridge.zmq_client"] = {
		request = function()
			return true
		end,
		start = function()
			return true
		end,
	}
end

local function find_upvalue(fn, target)
	local idx = 1
	while true do
		local name, value = debug.getupvalue(fn, idx)
		if not name then
			break
		end
		if name == target then
			return value
		end
		idx = idx + 1
	end
	return nil
end

it("exec_with_pipeline upvalue is wired before open usage", function()
	setup_env()
	package.loaded["ipybridge"] = nil
	local bridge = require("ipybridge")
	local exec_upvalue = find_upvalue(bridge.open, "exec_with_pipeline")
	assert(type(exec_upvalue) == "function", "exec_with_pipeline should be a function upvalue on bridge.open")
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("executor_binding_spec failed")
end

return true
