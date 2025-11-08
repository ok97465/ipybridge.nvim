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

local function expect(condition, message)
	if not condition then
		error(message or "expectation failed")
	end
end

local function with_debug_env(run)
	local original_vim = _G.vim
	local original_debug_mod = package.loaded["ipybridge.core.debug"]

	local env = {
		term_win = 1,
		code_win = 2,
		term_buf = 91,
		code_buf = 42,
		current_win = 1,
		windows = {},
		set_current_history = {},
		scroll_calls = 0,
		insert_calls = 0,
		schedule_calls = 0,
	}

	env.windows[env.term_win] = { buf = env.term_buf, valid = true }
	env.windows[env.code_win] = { buf = env.code_buf, valid = true }

	local function list_windows()
		local wins = {}
		for win, meta in pairs(env.windows) do
			if meta.valid then
				table.insert(wins, win)
			end
		end
		table.sort(wins)
		return wins
	end

	local vim_stub = {
		api = {
			nvim_get_current_win = function()
				return env.current_win
			end,
			nvim_set_current_win = function(win)
				env.current_win = win
				table.insert(env.set_current_history, win)
			end,
			nvim_win_is_valid = function(win)
				return env.windows[win] and env.windows[win].valid or false
			end,
			nvim_win_get_buf = function(win)
				return env.windows[win] and env.windows[win].buf or -1
			end,
			nvim_win_set_buf = function(win, buf)
				env.windows[win] = env.windows[win] or { valid = true }
				env.windows[win].buf = buf
			end,
			nvim_list_wins = list_windows,
			nvim_buf_is_valid = function(buf)
				return buf == env.code_buf
			end,
			nvim_buf_line_count = function(buf)
				if buf == env.code_buf then
					return 500
				end
				return 1
			end,
			nvim_buf_set_option = function() end,
			nvim_win_call = function(win, fn)
				local prev = env.current_win
				env.current_win = win
				local ok, err = pcall(fn)
				env.current_win = prev
				if not ok then
					error(err)
				end
			end,
			nvim_win_set_cursor = function() end,
		},
		fn = {
			bufadd = function()
				env.bufadd_called = true
				return env.code_buf
			end,
			bufload = function()
				env.bufload_called = true
			end,
		},
		schedule = function(cb)
			env.schedule_calls = env.schedule_calls + 1
			cb()
		end,
		cmd = function() end,
		notify = function() end,
		log = {
			levels = {
				WARN = "WARN",
			},
		},
	}

	_G.vim = vim_stub
	package.loaded["ipybridge.core.debug"] = nil
	local Debug = require("ipybridge.core.debug")

	env.Debug = Debug
	env.state = {
		term_instance = {
			buf_id = env.term_buf,
			win_id = env.term_win,
			scroll_to_bottom = function()
				env.scroll_calls = env.scroll_calls + 1
			end,
			startinsert = function()
				env.insert_calls = env.insert_calls + 1
			end,
		},
		_debug_generation = 1,
		_debug_generation_complete = 0,
		_debug_scope = "globals",
		_debug_active = false,
		_debug_status_active = false,
		_latest_vars = {},
	}

	env.normalize_path = function(path)
		return path
	end
	env.is_open = function()
		return true
	end

	local ok, err = pcall(run, env)

	_G.vim = original_vim
	package.loaded["ipybridge.core.debug"] = original_debug_mod

	if not ok then
		error(err)
	end
end

it("restores terminal focus after debugger jumps from terminal window", function()
	with_debug_env(function(ctx)
		local vars_pushed = false
		local sign_places = 0
		local debugger = ctx.Debug.new({
			state = ctx.state,
			cmp_bridge = {
				ensure = function()
					return true
				end,
				trigger = function()
					return true
				end,
			},
			debug_sign = {
				place = function()
					sign_places = sign_places + 1
				end,
				clear = function() end,
			},
			debug_vars = {
				current_scope = function()
					return { value = { repr = "1" } }
				end,
				push_to_explorer = function()
					vars_pushed = true
				end,
			},
			normalize_path = ctx.normalize_path,
			warn_user = function() end,
			fn = {
				bufadd = function()
					ctx.bufadd_called = true
					return ctx.code_buf
				end,
				bufload = function()
					ctx.bufload_called = true
				end,
			},
			is_open = ctx.is_open,
		})

		debugger.on_location({
			file = "/tmp/example.py",
			line = 12,
			source = "  x = 1",
			["function"] = "main",
		})

		expect(ctx.bufadd_called, "bufadd should be invoked for debug file")
		expect(ctx.bufload_called, "bufload should be invoked for debug file")
		expect(ctx.state._debug_window == ctx.code_win, "debug window should track code split")
		expect(ctx.state._debug_scope == "locals", "debug scope should prefer locals when stepping into a function")
		expect(ctx.state._debug_active, "debug state should remain active")
		expect(ctx.state._latest_vars.value.repr == "1", "latest vars should reflect current scope")
		expect(vars_pushed, "variable explorer should receive updated scope")
		expect(sign_places == 1, "debug sign should be placed once")
		expect(ctx.set_current_history[1] == ctx.code_win, "should visit code window first")
		expect(ctx.set_current_history[#ctx.set_current_history] == ctx.term_win, "final focus should return to terminal")
		expect(ctx.current_win == ctx.term_win, "terminal should regain focus")
		expect(ctx.scroll_calls == 1, "terminal should scroll after restore")
		expect(ctx.insert_calls == 1, "terminal should re-enter insert mode")
		expect(ctx.schedule_calls == 1, "restore handler should be scheduled once")
	end)
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("debug_focus_spec failed")
end

return true
