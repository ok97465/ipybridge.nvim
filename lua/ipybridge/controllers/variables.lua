-- VariablesController handles variable explorer lifecycle, ZMQ-backed refresh
-- requests, preview payload delivery, and debug cache lookups.

local VariablesController = {}
VariablesController.__index = VariablesController

-- Deliver variable snapshots to the explorer UI module.
local function deliver_vars_to_explorer(payload, warn_user)
	local ok, vx = pcall(require, "ipybridge.var_explorer")
	if not ok or not vx or type(vx.on_vars) ~= "function" then
		return false
	end
	vim.schedule(function()
		vx.on_vars(payload or {})
	end)
	return true
end

-- Deliver preview payloads to the data viewer UI module.
local function deliver_preview_payload(payload, warn_user)
	local ok, dv = pcall(require, "ipybridge.data_viewer")
	if not ok or not dv or type(dv.on_preview) ~= "function" then
		return false
	end
	vim.schedule(function()
		dv.on_preview(payload)
	end)
	return true
end

-- Send a structured preview error payload (or fallback warning).
local function deliver_preview_error(name, message, warn_user)
	local delivered = deliver_preview_payload({ name = name, error = message }, warn_user)
	if not delivered then
		warn_user("ipybridge: data viewer module unavailable")
	end
end

---Create a new VariablesController instance.
---@param opts table
---@return table
function VariablesController.new(opts)
	local self = setmetatable({}, VariablesController)
	self.state = assert(opts.state, "variables controller: state is required")
	self.debug_vars = assert(opts.debug_vars, "variables controller: debug_vars is required")
	self.sync_var_filters = assert(opts.sync_var_filters, "variables controller: sync_var_filters is required")
	self.ensure_zmq = assert(opts.ensure_zmq, "variables controller: ensure_zmq is required")
	self.warn_user = opts.warn_user or function() end
	return self
end

---Open the variable explorer and trigger a refresh when needed.
---@param focus_terminal_on_close boolean|nil
function VariablesController:open(focus_terminal_on_close)
	local vx = require("ipybridge.var_explorer")
	vx.open(focus_terminal_on_close)
	if self.state._debug_active then
		self.debug_vars.push_to_explorer(self.state)
		return
	end
	self:request_vars()
end

---Refresh the explorer contents, preferring debug snapshots when active.
function VariablesController:refresh()
	if self.state._debug_active then
		self.debug_vars.push_to_explorer(self.state)
		return
	end
	self:request_vars()
end

---Request a variable snapshot over ZMQ and dispatch to the explorer.
function VariablesController:request_vars()
	self.sync_var_filters()
	if self.state._debug_active then
		return
	end
	local cfg = self.state.config or {}
	local max_repr = tonumber(cfg.var_repr_limit) or 120
	if max_repr <= 0 then
		max_repr = 120
	end
	local payload = {
		max_repr = max_repr,
		hide_names = cfg.hidden_var_names,
		hide_types = cfg.hidden_type_names,
	}
	local function dispatch_vars_request()
		local z = require("ipybridge.zmq_client")
		local ok_req = z.request("vars", payload, function(msg)
			if msg and msg.ok and msg.tag == "vars" then
				if not deliver_vars_to_explorer(msg.data or {}, self.warn_user) then
					self.warn_user("ipybridge: variable explorer module unavailable")
				end
				return
			end
			self.warn_user("ipybridge: ZMQ vars request failed")
		end)
		if not ok_req then
			self.warn_user("ipybridge: ZMQ request send failed")
		end
	end
	if self.state._zmq_ready then
		dispatch_vars_request()
		return
	end
	self.ensure_zmq(function(ok)
		if ok then
			dispatch_vars_request()
			return
		end
		self.warn_user("ipybridge: ZMQ backend not available; vars unavailable")
	end)
end

---Request a preview payload for a given variable name.
---@param name string
---@param opts table|nil
function VariablesController:request_preview(name, opts)
	if not name or #name == 0 then
		return
	end
	opts = opts or {}
	local row_offset = tonumber(opts.row_offset) or 0
	local col_offset = tonumber(opts.col_offset) or 0
	if row_offset < 0 then
		row_offset = 0
	end
	if col_offset < 0 then
		col_offset = 0
	end
	local cfg = self.state.config or {}
	local max_rows = tonumber(cfg.viewer_max_rows) or 30
	local max_cols = tonumber(cfg.viewer_max_cols) or 20
	local debug_mode = self.state._debug_active == true
	if debug_mode then
		-- Prefer cached debug previews to avoid redundant ZMQ requests.
		local use_cache = (row_offset == 0 and col_offset == 0)
		local payload = nil
		if use_cache then
			payload = self.debug_vars.preview_payload(self.state, name)
			if type(payload) == "table" then
				payload.row_offset = payload.row_offset or 0
				payload.col_offset = payload.col_offset or 0
				payload.max_rows = payload.max_rows or max_rows
				payload.max_cols = payload.max_cols or max_cols
				if not deliver_preview_payload(payload, self.warn_user) then
					self.warn_user("ipybridge: data viewer module unavailable")
				end
				return
			end
		end
		local function dispatch_response(msg)
			if msg and msg.ok and msg.tag == "preview" then
				if not deliver_preview_payload(msg.data or {}, self.warn_user) then
					self.warn_user("ipybridge: data viewer module unavailable")
				end
				return
			end
			deliver_preview_error(name, "Failed to fetch debug preview", self.warn_user)
			self.warn_user("ipybridge: ZMQ debug preview failed")
		end
		local function send_debug_request()
			local z = require("ipybridge.zmq_client")
			local payload_dbg = {
				name = name,
				max_rows = max_rows,
				max_cols = max_cols,
				debug = true,
				row_offset = row_offset,
				col_offset = col_offset,
			}
			local ok_req = z.request("preview", payload_dbg, dispatch_response)
			if not ok_req then
				deliver_preview_error(name, "Failed to send debug preview request", self.warn_user)
				self.warn_user("ipybridge: failed to send ZMQ debug preview request")
			end
		end
		if self.state._zmq_ready then
			send_debug_request()
		else
			self.ensure_zmq(function(ok)
				if ok then
					send_debug_request()
				else
					deliver_preview_error(name, "ZMQ backend unavailable in debug", self.warn_user)
					self.warn_user("ipybridge: ZMQ backend not available; debug preview unavailable")
				end
			end)
		end
		return
	end

	-- Keep filters in sync before issuing non-debug preview requests.
	self.sync_var_filters()
	local function dispatch_preview_request()
		local z = require("ipybridge.zmq_client")
		local payload_req = {
			name = name,
			max_rows = max_rows,
			max_cols = max_cols,
			row_offset = row_offset,
			col_offset = col_offset,
		}
		local ok_req = z.request("preview", payload_req, function(msg)
			if msg and msg.ok and msg.tag == "preview" then
				if not deliver_preview_payload(msg.data or {}, self.warn_user) then
					self.warn_user("ipybridge: data viewer module unavailable")
				end
				return
			end
			self.warn_user("ipybridge: ZMQ preview request failed")
		end)
		if not ok_req then
			self.warn_user("ipybridge: ZMQ request send failed")
		end
	end
	if self.state._zmq_ready then
		dispatch_preview_request()
		return
	end
	self.ensure_zmq(function(ok)
		if ok then
			dispatch_preview_request()
			return
		end
		self.warn_user("ipybridge: ZMQ backend not available; preview unavailable")
	end)
end

return VariablesController
