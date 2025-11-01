-- OSC (Operating System Command) payload decoder.
-- Responsible for extracting hidden messages emitted by python.exec_magics
-- and returning visible terminal text to the caller.

local OscParser = {}
OscParser.__index = OscParser

---Create a new decoder.
---@param opts table|nil
---@return table
function OscParser:new(opts)
	local config = opts or {}
	local instance = setmetatable({
		prefix = assert(config.prefix or "\27]5379;ipybridge:", "OSC prefix is required"),
		suffix = config.suffix or "\7",
		_pending = "",
		_on_message = config.on_message,
	}, self)
	return instance
end

---Update the callback that handles decoded OSC messages.
---@param cb fun(tag:string, payload:table)|nil
function OscParser:set_handler(cb)
	self._on_message = cb
end

local function try_decode_json(raw)
	local ok, decoded = pcall(vim.json.decode, raw)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local function same_prefix_suffix(prefix, candidate)
	local max_keep = math.min(#candidate, #prefix - 1)
	for len = max_keep, 1, -1 do
		if prefix:sub(1, len) == candidate:sub(-len) then
			return len
		end
	end
	return 0
end

---Process a single chunk from terminal stdout/stderr.
---@param text string
---@return string visible
function OscParser:ingest(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local combined = (self._pending or "") .. text
	local output = {}
	local cursor = 1
	local prefix = self.prefix
	local suffix = self.suffix
	while true do
		local start_idx = combined:find(prefix, cursor, true)
		if not start_idx then
			break
		end
		local before = combined:sub(cursor, start_idx - 1)
		if before ~= "" then
			table.insert(output, before)
		end
		local payload_start = start_idx + #prefix
		local stop_idx = combined:find(suffix, payload_start, true)
		if not stop_idx then
			self._pending = combined:sub(start_idx)
			return table.concat(output, "")
		end
		local payload_raw = combined:sub(payload_start, stop_idx - 1)
		self:_handle_payload(payload_raw)
		cursor = stop_idx + #suffix
	end
	local remainder = combined:sub(cursor)
	local keep = same_prefix_suffix(prefix, remainder)
	if keep > 0 then
		self._pending = remainder:sub(-keep)
		remainder = remainder:sub(1, #remainder - keep)
	else
		self._pending = ""
	end
	if remainder ~= "" then
		table.insert(output, remainder)
	end
	return table.concat(output, "")
end

function OscParser:pending()
	return self._pending or ""
end

function OscParser:_handle_payload(payload)
	if type(payload) ~= "string" or payload == "" then
		return
	end
	local separator = payload:find(":", 1, true)
	if not separator then
		return
	end
	local tag = payload:sub(1, separator - 1)
	local body = payload:sub(separator + 1)
	if type(tag) ~= "string" or tag == "" or type(body) ~= "string" or body == "" then
		return
	end
	local decoded = try_decode_json(body)
	if not decoded then
		vim.schedule(function()
			vim.notify("ipybridge: failed to decode OSC payload for " .. tag, vim.log.levels.WARN)
		end)
		return
	end
	local handler = self._on_message
	if type(handler) ~= "function" then
		return
	end
	vim.schedule(function()
		pcall(handler, tag, decoded)
	end)
end

return OscParser
