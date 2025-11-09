-- Manages a single completion request/response conversation with the bridge.
-- Builds request context, dispatches via providers, and annotates items with
-- cursor metadata for downstream engines.
local providers = require("ipybridge.cmp_bridge.providers")

local M = {}

local function default_scheduler(cb)
	if type(cb) ~= "function" then
		return
	end
	if vim and type(vim.schedule) == "function" then
		vim.schedule(cb)
	else
		cb()
	end
end

local Session = {}
Session.__index = Session

function Session.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Session)
	self.dispatch_opts = opts.dispatch_opts
	self.scheduler = opts.scheduler or default_scheduler
	self.on_result = opts.on_result
	self.on_complete = opts.on_complete
	self.context = providers.build_context(opts.request_context or {})
	self.started = false
	return self
end

function Session:get_context()
	return self.context
end

function Session:start()
	if self.started then
		return self
	end
	self.started = true
	providers.dispatch(self.context, function(result)
		local payload = result or {}
		if type(payload.items) ~= "table" then
			payload.items = {}
		end
		if payload.isIncomplete == nil then
			payload.isIncomplete = false
		end
		self.scheduler(function()
			if type(self.on_result) == "function" then
				self.on_result(payload, self.context)
			end
			if payload.isIncomplete == false and type(self.on_complete) == "function" then
				self.on_complete(payload, self.context)
			end
		end)
	end, self.dispatch_opts)
	return self
end

local function attach_context_metadata(items, context)
	if type(items) ~= "table" or #items == 0 or type(context) ~= "table" then
		return
	end
	local meta = {
		cursor_row = context.cursor_row or 0,
		cursor_col = context.cursor_col or 0,
		cursor_col_start = context.cursor_col_start or (context.cursor_col or 0),
	}
	for _, item in ipairs(items) do
		if type(item) == "table" then
			local data = item.data
			if type(data) ~= "table" then
				data = {}
				item.data = data
			end
			data.__ipybridge = meta
		end
	end
end

M.Session = Session
M.new = function(opts)
	return Session.new(opts)
end
M.attach_context_metadata = attach_context_metadata

return M
