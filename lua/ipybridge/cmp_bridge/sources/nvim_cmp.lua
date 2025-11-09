local env = require("ipybridge.cmp_bridge.env")
local source_common = require("ipybridge.cmp_bridge.sources.common")

local function empty_result()
	return { items = {}, isIncomplete = false }
end

---@class IpybridgeNvimCmpSource
---@field on_empty fun()|nil
local Source = {}
Source.__index = Source

function Source.new(opts)
	opts = opts or {}
	return setmetatable({
		on_empty = opts.on_empty,
	}, Source)
end

function Source:get_debug_name()
	return "ipybridge::debug_tab_hint"
end

local function source_disabled()
	local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
	if not ok_buf then
		return true
	end
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "terminal" then
		return true
	end
	if not env.is_ipybridge_terminal(buf) then
		return true
	end
	return not env.is_debug_session()
end

function Source:is_available()
	return not source_disabled()
end

local function schedule_close(self)
	if type(self.on_empty) ~= "function" then
		return
	end
	self.on_empty()
end

function Source:complete(request, callback)
	if not env.is_debug_session() then
		callback(empty_result())
		schedule_close(self)
		return
	end
	source_common.stream({
		request_context = request.context or {},
		on_result = function(result)
			callback({
				items = result.items,
				isIncomplete = result.isIncomplete,
			})
		end,
		on_empty = function()
			schedule_close(self)
		end,
	})
end

return Source
