-- Engine adapter that configures blink.cmp to host the ipybridge source.
-- Handles provider registration, menu lifecycle, and selection plumbing.
local blink = require("ipybridge.cmp_bridge.blink")
local constants = require("ipybridge.cmp_bridge.constants")

local SOURCE_NAME = constants.source_name
local BLINK_SOURCE_MODULE = constants.blink_source_module

local blink_engine = {
	id = "blink.cmp",
}

local function provider_registered()
	local ok, config = pcall(require, "blink.cmp.config")
	if not ok or type(config) ~= "table" then
		return false
	end
	local sources = config.sources
	if type(sources) ~= "table" then
		return false
	end
	local providers = sources.providers
	if type(providers) ~= "table" then
		return false
	end
	return providers[SOURCE_NAME] ~= nil
end

function blink_engine:is_available()
	return blink.module() ~= nil
end

function blink_engine:ensure()
	local blink_module = blink.module()
	if not blink_module then
		return false
	end
	if provider_registered() then
		return true
	end
	local ok, err = pcall(blink_module.add_source_provider, SOURCE_NAME, {
		name = "IpyBridge",
		module = BLINK_SOURCE_MODULE,
	})
	if not ok then
		local message = tostring(err or "")
		if message:match("already exists") then
			return true
		end
		blink.notify_failure("add_source_provider", message)
		return false
	end
	return true
end

function blink_engine:is_visible()
	return blink.call("is_visible") and true or false
end

function blink_engine:close()
	blink.call("hide")
end

function blink_engine:abort()
	if not blink.call("cancel") then
		blink.call("hide")
	end
end

function blink_engine:select(direction)
	if direction == "next" then
		blink.call("select_next")
	elseif direction == "prev" then
		blink.call("select_prev")
	end
end

function blink_engine:accept()
	if blink.call("select_and_accept") then
		return true
	end
	return blink.call("accept") and true or false
end

function blink_engine:trigger()
	return blink.call("show", { providers = { SOURCE_NAME } }) and true or false
end

return blink_engine
