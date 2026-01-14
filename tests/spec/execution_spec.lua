-- Specs for the ExecutionController send_lines behavior.
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

local function stub_vim()
	local prev_vim = _G.vim
	_G.vim = {
		regex = function()
			return { match_str = function() return false end }
		end,
	}
	return prev_vim
end

local function stub_api(lines)
	return {
		nvim_buf_get_lines = function(_, s, e)
			local out = {}
			for idx = s + 1, e do
				out[#out + 1] = lines[idx] or ""
			end
			return out
		end,
	}
end

local function fresh_controller(lines)
	local ctx = {
		term_payloads = {},
		paste_calls = 0,
		paste_lines = nil,
		clear_calls = 0,
	}
	local prev_vim = stub_vim()
	package.loaded["ipybridge.controllers.execution"] = nil
	local ExecutionController = require("ipybridge.controllers.execution")
	local controller = ExecutionController.new({
		state = { config = {}, _debug_active = false },
		api = stub_api(lines),
		fn = {},
		utils = {
			paste_block = function(lines_tbl)
				ctx.paste_calls = ctx.paste_calls + 1
				ctx.paste_lines = lines_tbl
				return "<paste>"
			end,
		},
		breakpoints = {},
		warn_user = function() end,
		resolve_exec_cwd = function() end,
		with_terminal = function(_, cb)
			cb()
		end,
		term_send = function(payload)
			table.insert(ctx.term_payloads, payload)
		end,
		clear_debug_state = function()
			ctx.clear_calls = ctx.clear_calls + 1
		end,
		ensure_runcell_helpers = function() end,
		exec_with_pipeline = function() end,
		sync_debugfile_imports = function() end,
		sync_var_filters = function() end,
		is_open = function()
			return true
		end,
	})
	return controller, ctx, prev_vim
end

it("send_lines always uses bracketed paste payloads", function()
	local controller, ctx, prev_vim = fresh_controller({
		"print('alpha')",
		"print('beta')",
	})

	controller:send_lines(0, 2)
	assert(ctx.paste_calls == 1, "expected paste_block to be called once")
	assert(ctx.term_payloads[1] == "<paste>", "expected bracketed paste payload")
	assert(ctx.paste_lines[1] == "print('alpha')", "first line should be preserved")
	assert(ctx.paste_lines[2] == "print('beta')", "second line should be preserved")
	assert(ctx.clear_calls == 1, "expected debug state to be cleared")

	_G.vim = prev_vim
end)
