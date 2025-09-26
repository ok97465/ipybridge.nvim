local M = {}

local registry = {}

local function notify_once(tag, err)
  vim.schedule(function()
    vim.notify(string.format('ipybridge: handler for %s failed: %s', tag, err), vim.log.levels.WARN)
  end)
end

local function lazy_method(module_name, method_name, transform)
  local resolved = nil
  return function(msg)
    if resolved == nil then
      local ok, mod = pcall(require, module_name)
      if not ok or not mod then
        resolved = false
        return
      end
      local candidate = mod[method_name]
      if type(candidate) ~= 'function' then
        resolved = false
        return
      end
      resolved = candidate
    end
    if resolved == false then return end
    local payload = transform and transform(msg) or msg
    local ok, err = pcall(resolved, payload)
    if not ok then
      notify_once(msg.tag or method_name or module_name, err)
    end
  end
end

---Register a handler for a specific tag.
---@param tag string
---@param handler fun(msg: table)
function M.register(tag, handler)
  if type(tag) ~= 'string' or tag == '' then return end
  if type(handler) ~= 'function' then return end
  registry[tag] = handler
end

---Remove a previously registered handler.
---@param tag string
function M.unregister(tag)
  if type(tag) ~= 'string' then return end
  registry[tag] = nil
end

---Dispatch decoded messages produced by the terminal bridge.
---@param msg table
function M.handle(msg)
  if type(msg) ~= 'table' then return end
  local tag = msg.tag
  if type(tag) ~= 'string' then return end
  local handler = registry[tag]
  if type(handler) ~= 'function' then return end
  local ok, err = pcall(handler, msg)
  if not ok then
    notify_once(tag, err)
  end
end

-- Default handlers
M.register('vars', lazy_method('ipybridge.var_explorer', 'on_vars', function(message)
  local payload = message.data or {}
  local ok, bridge = pcall(require, 'ipybridge')
  if ok and bridge and type(bridge._digest_vars_snapshot) == 'function' then
    local ok_digest, result = pcall(bridge._digest_vars_snapshot, payload)
    if ok_digest then
      return result or {}
    end
  end
  return payload
end))

M.register('preview', lazy_method('ipybridge.data_viewer', 'on_preview', function(message)
  return message.data or {}
end))

M.register('debug_location', function(message)
  local bridge = package.loaded['ipybridge']
  if not bridge then return end
  local handler = bridge.on_debug_location
  if type(handler) ~= 'function' then return end
  handler(message.data or {})
end)

return M
