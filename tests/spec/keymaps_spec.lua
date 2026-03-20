-- Specs for the keymap helper module and its public default mappings.
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

local function with_stubbed_vim(run)
	local original_vim = _G.vim
	local original_bridge = package.loaded["ipybridge"]
	local original_keymaps = package.loaded["ipybridge.keymaps"]
	local ctx = {
		keymaps = {},
		commands = {},
		autocmds = {},
		goto_calls = 0,
	}

	local bridge = {
		goto_debug_location = function()
			ctx.goto_calls = ctx.goto_calls + 1
		end,
		goto_vi = function() end,
		var_explorer_open = function() end,
		var_explorer_refresh = function() end,
		plot_open = function() end,
		plot_next = function() end,
		plot_prev = function() end,
		plot_delete = function() end,
		plot_clear = function() end,
		plot_status = function() end,
	}

	_G.vim = {
		api = {
			nvim_create_augroup = function()
				return 1
			end,
			nvim_create_autocmd = function(events, opts)
				table.insert(ctx.autocmds, { events = events, opts = opts })
			end,
			nvim_create_user_command = function(name, callback, opts)
				ctx.commands[name] = { callback = callback, opts = opts }
			end,
		},
		keymap = {
			set = function(mode, lhs, rhs, opts)
				table.insert(ctx.keymaps, {
					mode = mode,
					lhs = lhs,
					rhs = rhs,
					opts = opts,
				})
			end,
		},
	}
	package.loaded["ipybridge"] = bridge
	package.loaded["ipybridge.keymaps"] = nil

	local ok, err = pcall(run, ctx, require("ipybridge.keymaps"), bridge)

	_G.vim = original_vim
	package.loaded["ipybridge"] = original_bridge
	package.loaded["ipybridge.keymaps"] = original_keymaps

	if not ok then
		error(err)
	end
end

it("apply_defaults registers a global debug-location jump mapping and command", function()
	with_stubbed_vim(function(ctx, keymaps, bridge)
		keymaps.apply_defaults()

		local debug_map = nil
		for _, map in ipairs(ctx.keymaps) do
			if map.mode == "n" and map.lhs == "<leader>id" then
				debug_map = map
				break
			end
		end

		assert(debug_map, "global <leader>id mapping should be registered")
		assert(debug_map.rhs == bridge.goto_debug_location, "global <leader>id should jump to the debug location")
		assert(
			debug_map.opts and debug_map.opts.desc == "IPy: Jump to current debug line",
			"global <leader>id should advertise the debug jump description"
		)

		local cmd = ctx.commands["IpybridgeDebugHere"]
		assert(cmd, "IpybridgeDebugHere command should be registered")
		cmd.callback()
		assert(ctx.goto_calls == 1, "IpybridgeDebugHere should invoke the debug-location jump helper")
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
	error("keymaps_spec failed")
end

return true
