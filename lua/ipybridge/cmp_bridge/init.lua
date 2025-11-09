-- Entry point for the cmp bridge subsystem.
-- Registers engine adapters, exposes configuration hooks, and routes trigger
-- requests through the runtime helpers.
local constants = require("ipybridge.cmp_bridge.constants")
local engines = require("ipybridge.cmp_bridge.engines")
local providers = require("ipybridge.cmp_bridge.providers")
local runtime = require("ipybridge.cmp_bridge.runtime")

engines.register(require("ipybridge.cmp_bridge.engines.nvim_cmp"))
engines.register(require("ipybridge.cmp_bridge.engines.blink"))

local config = {
	engine_priority = vim.deepcopy(constants.default_engine_priority),
	engines_enabled = true,
}

local function apply_config()
	if config.engines_enabled then
		engines.set_preference(config.engine_priority)
	else
		engines.abort()
	end
end

local function normalize_priority(list)
	if type(list) ~= "table" then
		return nil
	end
	local normalized = {}
	for _, id in ipairs(list) do
		if type(id) == "string" and id ~= "" then
			normalized[#normalized + 1] = id
		end
	end
	return normalized
end

local M = {}

function M.configure(opts)
	opts = opts or {}
	if opts.engine_priority ~= nil then
		local priority = normalize_priority(opts.engine_priority)
		if priority and #priority > 0 then
			config.engine_priority = priority
			config.engines_enabled = true
		elseif priority and #priority == 0 then
			config.engine_priority = {}
			config.engines_enabled = false
		else
			config.engine_priority = vim.deepcopy(constants.default_engine_priority)
			config.engines_enabled = true
		end
	end
	apply_config()
end

apply_config()

---Register an additional completion provider.
---@param provider table
function M.register_completion_provider(provider)
	return providers.register(provider)
end

function M.ensure()
	if not config.engines_enabled then
		return false
	end
	return runtime.ensure()
end

function M.trigger()
	if not config.engines_enabled then
		return false
	end
	return runtime.trigger()
end

return M
