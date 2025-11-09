-- Lightweight wrapper around blink.cmp so we can call into it safely.
-- Handles lazy loading, protected calls, and consistent warning messages.
local MODULE_NAME = "blink.cmp"

local M = {}

local function notify_failure(method, err)
	local message = string.format("ipybridge: %s %s failed: %s", MODULE_NAME, method or "?", err or "")
	vim.schedule(function()
		vim.notify(message, vim.log.levels.WARN)
	end)
end

local function load_module()
	local blink = package.loaded[MODULE_NAME]
	if type(blink) == "table" then
		return blink
	end
	local ok, loaded = pcall(require, MODULE_NAME)
	if not ok or type(loaded) ~= "table" then
		return nil
	end
	return loaded
end

function M.module()
	return load_module()
end

function M.call(method, ...)
	local blink = load_module()
	if not blink or type(blink[method]) ~= "function" then
		return false
	end
	local ok, result = pcall(blink[method], ...)
	if not ok then
		notify_failure(method, result)
		return false
	end
	return result
end

function M.notify_failure(method, err)
	notify_failure(method, err)
end

return M
