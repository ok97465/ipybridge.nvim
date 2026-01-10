-- Lua specs that exercise the completion bridge engines/sources/runtime.
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

local function cleanup()
	local modules = {
	"ipybridge.cmp_bridge.runtime",
	"ipybridge.cmp_bridge.engines",
	"ipybridge.cmp_bridge.engines.nvim_cmp",
	"ipybridge.cmp_bridge.engines.blink",
	"ipybridge.cmp_bridge.sources.blink",
	"ipybridge.cmp_bridge.sources.nvim_cmp",
	"ipybridge.cmp_bridge.blink",
	"ipybridge.cmp_bridge",
	"tests.fake.nvim_source",
	"ipybridge.cmp_bridge.constants",
	"ipybridge.cmp_bridge.env",
	"ipybridge.cmp_bridge.providers",
	"ipybridge.cmp_bridge.completion_session",
	"ipybridge.cmp_bridge.completion_apply",
		"cmp",
		"blink.cmp",
		"blink.cmp.config",
	}
	for _, name in ipairs(modules) do
		package.loaded[name] = nil
	end
	_G.vim = nil
end

it("schedules nvim-cmp completion through vim.schedule", function()
	cleanup()
	local scheduled = 0
	_G.vim = {
		schedule = function(cb)
			scheduled = scheduled + 1
			if type(cb) == "function" then
				cb()
			end
		end,
	}
	package.loaded["ipybridge.cmp_bridge.constants"] = {
		source_name = "ipybridge_debug_hint",
		nvim_cmp_source_module = "tests.fake.nvim_source",
	}
	package.loaded["tests.fake.nvim_source"] = {
		new = function()
			return {}
		end,
	}
	package.loaded["ipybridge.cmp_bridge.env"] = {
		is_active_ipy_terminal = function()
			return false
		end,
		feed_terminal = function() end,
	}
	package.loaded["ipybridge.cmp_bridge.providers"] = {
		build_context = function()
			return {}
		end,
		dispatch = function() end,
	}
	local captured_opts = nil
	package.loaded["cmp"] = {
		ContextReason = { Manual = "manual" },
		get_config = function()
			return {
				sources = {
					{ name = "ipybridge_debug_hint" },
				},
			}
		end,
		complete = function(opts)
			captured_opts = opts
		end,
		visible = function()
			return false
		end,
	}
	local engine = require("ipybridge.cmp_bridge.engines.nvim_cmp")
	assert(engine:trigger(), "trigger should succeed")
	assert(scheduled == 1, "trigger must route through vim.schedule")
	assert(captured_opts ~= nil, "trigger should call cmp.complete with opts")
	cleanup()
end)

it("promotes higher-priority engine once it becomes available", function()
	cleanup()
	local availability = {
		["nvim-cmp"] = false,
		["blink.cmp"] = true,
	}
	_G.vim = {
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
		notify = function() end,
	}
	local engines = require("ipybridge.cmp_bridge.engines")
	local nvim_engine = {
		id = "nvim-cmp",
		is_available = function()
			return availability["nvim-cmp"]
		end,
		ensure = function()
			return true
		end,
	}
	local blink_engine = {
		id = "blink.cmp",
		is_available = function()
			return availability["blink.cmp"]
		end,
		ensure = function()
			return true
		end,
	}
	engines.register(nvim_engine)
	engines.register(blink_engine)
	engines.set_preference({ "nvim-cmp", "blink.cmp" })
	local initial = engines.ensure()
	assert(initial == blink_engine, "blink should be selected when nvim-cmp is unavailable")
	availability["nvim-cmp"] = true
	local promoted = engines.ensure()
	assert(promoted == nvim_engine, "nvim-cmp must take over once it loads")
	cleanup()
end)

it("does not fall back to engines outside the preference allowlist", function()
	cleanup()
	_G.vim = {
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
		notify = function() end,
	}
	local engines = require("ipybridge.cmp_bridge.engines")
	local nvim_checks = 0
	local nvim_engine = {
		id = "nvim-cmp",
		is_available = function()
			nvim_checks = nvim_checks + 1
			return true
		end,
		ensure = function()
			return true
		end,
	}
	local blink_engine = {
		id = "blink.cmp",
		is_available = function()
			return true
		end,
		ensure = function()
			return true
		end,
	}
	engines.register(nvim_engine)
	engines.register(blink_engine)
	engines.set_preference({ "blink.cmp" })
	local selected = engines.ensure()
	assert(selected == blink_engine, "only blink.cmp should be considered")
	assert(nvim_checks == 0, "nvim-cmp should be ignored when not listed")
	cleanup()
end)

it("disables runtime when engine priority list is empty", function()
	cleanup()
	local function deepcopy(value, seen)
		if type(value) ~= "table" then
			return value
		end
		seen = seen or {}
		if seen[value] then
			return seen[value]
		end
		local copy = {}
		seen[value] = copy
		for k, v in pairs(value) do
			copy[deepcopy(k, seen)] = deepcopy(v, seen)
		end
		return copy
	end
	local runtime_ensures = 0
	_G.vim = {
		deepcopy = deepcopy,
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
	}
	package.loaded["ipybridge.cmp_bridge.constants"] = {
		default_engine_priority = { "nvim-cmp", "blink.cmp" },
	}
	local abort_calls = 0
	package.loaded["ipybridge.cmp_bridge.engines"] = {
		register = function() end,
		set_preference = function() end,
		abort = function()
			abort_calls = abort_calls + 1
		end,
	}
	package.loaded["ipybridge.cmp_bridge.runtime"] = {
		ensure = function()
			runtime_ensures = runtime_ensures + 1
			return true
		end,
		trigger = function()
			return true
		end,
	}
	package.loaded["ipybridge.cmp_bridge.providers"] = {
		register = function() end,
	}
	package.loaded["ipybridge.cmp_bridge.engines.nvim_cmp"] = { id = "nvim-cmp" }
	package.loaded["ipybridge.cmp_bridge.engines.blink"] = { id = "blink.cmp" }
	local cmp_bridge = require("ipybridge.cmp_bridge")
	cmp_bridge.configure({ engine_priority = {} })
	assert(abort_calls == 1, "disabling engines should abort active engine state")
	assert(cmp_bridge.ensure() == false, "ensure should short-circuit when engines are disabled")
	assert(runtime_ensures == 0, "runtime must not be invoked when disabled")
	cmp_bridge.configure({ engine_priority = { "nvim-cmp" } })
	assert(cmp_bridge.ensure() == true, "ensure should succeed once re-enabled")
	assert(runtime_ensures == 1, "runtime ensure must run after re-enable")
	cleanup()
end)

it("nvim-cmp engine refuses to trigger when ipybridge source is not configured", function()
	cleanup()
	_G.vim = {
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
	}
	package.loaded["ipybridge.cmp_bridge.constants"] = {
		source_name = "ipybridge_debug_hint",
		nvim_cmp_source_module = "tests.fake.nvim_source",
	}
	package.loaded["ipybridge.cmp_bridge.env"] = {
		is_active_ipy_terminal = function()
			return false
		end,
	}
	package.loaded["ipybridge.cmp_bridge.completion_apply"] = {
		prepare = function()
			return {}
		end,
		commit = function() end,
	}
	package.loaded["tests.fake.nvim_source"] = {
		new = function()
			return {}
		end,
	}
	local completes = 0
	package.loaded["cmp"] = {
		ContextReason = { Manual = "manual" },
		get_config = function()
			return {
				sources = {
					{ name = "buffer" },
				},
			}
		end,
		register_source = function() end,
		complete = function()
			completes = completes + 1
		end,
		visible = function()
			return false
		end,
	}
	local engine = require("ipybridge.cmp_bridge.engines.nvim_cmp")
	assert(engine:is_available() == false, "engine should be unavailable without ipybridge source configured")
	assert(engine:trigger() == false, "trigger should fail when source is missing from config")
	assert(completes == 0, "cmp.complete must not fire when trigger is rejected")
	cleanup()
end)

it("treats blink show returning nil as a successful trigger", function()
	cleanup()
	package.loaded["blink.cmp"] = {
		show = function() end,
	}
	local engine = require("ipybridge.cmp_bridge.engines.blink")
	assert(engine:trigger() == true, "trigger should treat nil show return as success")
	cleanup()
end)

it("re-registers blink provider after blink config resets providers", function()
	cleanup()
	_G.vim = {
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
		notify = function() end,
	}
	local blink_config = {
		sources = {
			providers = {},
		},
	}
	package.loaded["blink.cmp.config"] = blink_config
	package.loaded["blink.cmp"] = {
		add_source_provider = function(source_id, provider_config)
			if blink_config.sources.providers[source_id] ~= nil then
				error("Provider with id " .. source_id .. " already exists")
			end
			blink_config.sources.providers[source_id] = provider_config
		end,
	}
	local engine = require("ipybridge.cmp_bridge.engines.blink")
	assert(engine:ensure(), "initial ensure should register provider")
	assert(
		blink_config.sources.providers["ipybridge_debug_hint"],
		"provider must be present after first ensure"
	)
	blink_config.sources.providers = {}
	assert(engine:ensure(), "engine should re-register provider when config overwrites table")
	assert(
		blink_config.sources.providers["ipybridge_debug_hint"],
		"provider must be restored after config reset"
	)
	cleanup()
end)

it("blink source only forwards new completion labels", function()
	cleanup()
	local close_calls = 0
	_G.vim = {
		api = {
			nvim_get_current_buf = function()
				return 1
			end,
			nvim_get_option_value = function()
				return "terminal"
			end,
		},
		schedule = function(cb)
			if type(cb) == "function" then
				cb()
			end
		end,
	}
	package.loaded["blink.cmp"] = {
		hide = function()
			close_calls = close_calls + 1
		end,
	}
	package.loaded["ipybridge.cmp_bridge.env"] = {
		is_debug_session = function()
			return true
		end,
		is_ipybridge_terminal = function()
			return true
		end,
		is_active_ipy_terminal = function()
			return true
		end,
		feed_terminal = function() end,
	}
	local received_mode = nil
	package.loaded["ipybridge.cmp_bridge.providers"] = {
		build_context = function()
			return {}
		end,
		dispatch = function(_, cb, opts)
			received_mode = opts and opts.mode
			cb({
				items = {
					{ label = "data" },
					{ label = "data2" },
				},
				isIncomplete = true,
			})
			cb({
				items = {
					{ label = "data3" },
				},
				isIncomplete = false,
			})
		end,
	}
	local BlinkSource = require("ipybridge.cmp_bridge.sources.blink")
	local source = BlinkSource.new()
	local batches = {}
	source:get_completions({}, function(payload)
		table.insert(batches, payload)
	end)
	assert(received_mode == "delta", "blink source must request delta streaming")
	assert(#batches == 2, "expected two callback batches")
	local first = batches[1]
	assert(#first.items == 2, "first batch should emit unique items only")
	assert(first.items[1].label == "data", "first label should be data")
	assert(first.items[2].label == "data2", "second label should be data2")
	local second = batches[2]
	assert(#second.items == 1, "second batch should only include unseen labels")
	assert(second.items[1].label == "data3", "second batch label should be data3")
	assert(close_calls == 0, "menu should stay open while we return results")
	cleanup()
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("cmp_bridge_spec failed")
end

return true
