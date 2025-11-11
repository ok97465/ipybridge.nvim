-- SyncController owns ZMQ helper synchronization for variable filters and
-- debugfile imports, handling signature caching, retries, and template
-- rendering so other modules can remain declarative.

local SyncController = {}
SyncController.__index = SyncController

local function encode_json(value)
	local ok, encoded = pcall(vim.json.encode, value)
	if not ok or not encoded then
		return "[]"
	end
	return encoded
end

local function should_retry(reason)
	local r = tostring(reason or "")
	return r == "helpers_failed" or r == "zmq_unavailable" or r == "conn_file_unavailable"
end

function SyncController.new(opts)
	local self = setmetatable({}, SyncController)
	self.state = assert(opts.state, "sync controller: state is required")
	self.py_module = assert(opts.py_module, "sync controller: py_module is required")
	self.exec_with_pipeline = assert(opts.exec_with_pipeline, "sync controller: exec_with_pipeline is required")
	self.ensure_helpers = assert(opts.ensure_helpers, "sync controller: ensure_helpers is required")
	self.is_open = assert(opts.is_open, "sync controller: is_open checker is required")
	self.warn_user = opts.warn_user or function() end
	return self
end

function SyncController:sync_var_filters()
	if not self.is_open() then
		return
	end
	self.ensure_helpers()
	local cfg = self.state.config or {}
	local names = type(cfg.hidden_var_names) == "table" and cfg.hidden_var_names or {}
	local types = type(cfg.hidden_type_names) == "table" and cfg.hidden_type_names or {}
	local max_repr = tonumber(cfg.var_repr_limit) or 120
	if max_repr <= 0 then
		max_repr = 120
	end
	local enable_logs = cfg.zmq_debug and true or false
	local names_json = encode_json(names)
	local types_json = encode_json(types)
	local signature =
		table.concat({ names_json, "\0", types_json, "\0", tostring(max_repr), "\0", enable_logs and "1" or "0" })
	if self.state._last_filters_signature == signature then
		return
	end
	local template = self.py_module.source("sync_filters.py")
	local script = template
		:gsub("__NAMES_JSON__", names_json)
		:gsub("__TYPES_JSON__", types_json)
		:gsub("__MAX_REPR__", tostring(max_repr))
		:gsub("__ENABLE_LOGS__", enable_logs and "True" or "False")
	self.exec_with_pipeline(script, {
		require_helpers = true,
		on_error = function(reason)
			local r = tostring(reason or "")
			if self.state._last_filters_signature == signature then
				self.state._last_filters_signature = nil
			end
			if should_retry(reason) then
				vim.defer_fn(function()
					if self.is_open() then
						self:sync_var_filters()
					end
				end, 150)
				return
			end
			self.warn_user(
				"ipybridge: failed to sync variable filters via ZMQ (" .. (r ~= "" and r or "unknown") .. ")"
			)
		end,
	})
	self.state._last_filters_signature = signature
end

function SyncController:sync_debugfile_imports(cb)
	if not self.is_open() then
		if type(cb) == "function" then
			cb(false)
		end
		return
	end
	self.ensure_helpers()
	local block = vim.trim((self.state.config or {}).debugfile_auto_imports or "")
	local payload = encode_json(block)
	local signature = payload
	if self.state._debugfile_imports_signature == signature then
		if type(cb) == "function" then
			cb(true)
		end
		return
	end
	local template = self.py_module.source("set_debugfile_imports.py")
	local script = template:gsub("__IMPORTS_JSON__", payload)
	self.exec_with_pipeline(script, {
		require_helpers = true,
		on_error = function(reason)
			local r = tostring(reason or "")
			if self.state._debugfile_imports_signature == signature then
				self.state._debugfile_imports_signature = nil
			end
			if should_retry(reason) then
				vim.defer_fn(function()
					if self.is_open() then
						self:sync_debugfile_imports(cb)
					end
				end, 150)
				return
			end
			self.warn_user(
				"ipybridge: failed to sync debugfile imports via ZMQ (" .. (r ~= "" and r or "unknown") .. ")"
			)
			if type(cb) == "function" then
				cb(false)
			end
		end,
		on_success = function()
			self.state._debugfile_imports_signature = signature
			if type(cb) == "function" then
				cb(true)
			end
		end,
	})
end

return SyncController
