-- ZMQ client manager for ipybridge.nvim.
-- Responsibilities:
--  1. Spawn and supervise the helper Python process.
--  2. Decode line-delimited JSON responses.
--  3. Route replies back to request callbacks with error isolation.

local fn = vim.fn

local WARNING = vim.log.levels.WARN

local function notify_once(message)
  vim.schedule(function()
    vim.notify('[ipybridge.zmq] ' .. message, WARNING)
  end)
end

-- Maintain buffered stdout data until full JSON lines are available.
local JsonLineBuffer = {}
JsonLineBuffer.__index = JsonLineBuffer

function JsonLineBuffer:new()
  return setmetatable({ _buffer = '' }, self)
end

function JsonLineBuffer:feed(chunk)
  if type(chunk) ~= 'string' or chunk == '' then
    return {}
  end
  self._buffer = self._buffer .. chunk .. '\n'
  local lines = {}
  while true do
    local start_idx, end_idx = self._buffer:find('\n', 1, true)
    if not start_idx then
      break
    end
    local line = self._buffer:sub(1, start_idx - 1)
    self._buffer = self._buffer:sub(end_idx + 1)
    if line ~= '' then
      lines[#lines + 1] = line
    end
  end
  return lines
end

function JsonLineBuffer:reset()
  self._buffer = ''
end

-- Track outstanding requests and deliver responses exactly once.
local RequestRegistry = {}
RequestRegistry.__index = RequestRegistry

function RequestRegistry:new()
  return setmetatable({ next_id = 1, pending = {} }, self)
end

local function safe_invoke(cb, payload)
  local ok, err = pcall(cb, payload)
  if not ok then
    notify_once('callback failed: ' .. tostring(err))
  end
end

function RequestRegistry:allocate_id()
  local id = tostring(self.next_id)
  self.next_id = self.next_id + 1
  return id
end

function RequestRegistry:register(id, cb)
  if not cb then
    return
  end
  self.pending[id] = cb
end

function RequestRegistry:resolve(id)
  local cb = self.pending[id]
  self.pending[id] = nil
  return cb
end

function RequestRegistry:flush_with_error(reason)
  local payload = { ok = false, error = reason }
  for id, cb in pairs(self.pending) do
    payload.id = id
    safe_invoke(cb, payload)
  end
  self.pending = {}
end

-- Concrete client managing the subprocess and IO wiring.
local Client = {}
Client.__index = Client

function Client:new()
  local instance = setmetatable({
    job_id = nil,
    buffer = JsonLineBuffer:new(),
    requests = RequestRegistry:new(),
  }, self)
  return instance
end

function Client:is_running()
  return self.job_id ~= nil
end

function Client:start(python_cmd, conn_file, module_path, debug)
  if self:is_running() then
    return true
  end
  local cmd = { python_cmd or 'python3', '-u', module_path, '--conn-file', conn_file }
  if debug then
    table.insert(cmd, '--debug')
  end
  local job = fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      self:_on_stdout(data)
    end,
    on_stderr = function(_, data)
      self:_on_stderr(data)
    end,
    on_exit = function()
      self:_on_exit()
    end,
  })
  if job <= 0 then
    return false
  end
  self.job_id = job
  return true
end

function Client:stop()
  if self.job_id then
    pcall(fn.jobstop, self.job_id)
  end
  self:_on_exit()
end

function Client:request(op, args, cb)
  if not self.job_id then
    return false
  end
  local id = self.requests:allocate_id()
  if cb then
    self.requests:register(id, cb)
  end
  local payload = { id = id, op = op, args = args or {} }
  if not self:_send(payload) then
    if cb then
      self.requests:resolve(id)
      safe_invoke(cb, { id = id, ok = false, error = 'send_failed' })
    end
    return false
  end
  return true
end

function Client:_send(msg)
  local encoded = vim.json.encode(msg) .. "\n"
  return fn.chansend(self.job_id, encoded) > 0
end

function Client:_on_stdout(data)
  if type(data) ~= 'table' then
    return
  end
  for _, chunk in ipairs(data) do
    local lines = self.buffer:feed(chunk or '')
    for _, line in ipairs(lines) do
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == 'table' and decoded.id then
        local cb = self.requests:resolve(decoded.id)
        if cb then
          safe_invoke(cb, decoded)
        end
      end
    end
  end
end

function Client:_on_stderr(data)
  if type(data) ~= 'table' then
    return
  end
  local msg = vim.trim(table.concat(data, '\n'))
  if msg ~= '' then
    notify_once('stderr: ' .. msg)
  end
end

function Client:_on_exit()
  if not self.job_id then
    return
  end
  self.requests:flush_with_error('zmq client exited')
  self.buffer:reset()
  self.job_id = nil
end

local singleton = Client:new()

return {
  is_running = function()
    return singleton:is_running()
  end,
  start = function(python_cmd, conn_file, module_path, debug)
    return singleton:start(python_cmd, conn_file, module_path, debug)
  end,
  stop = function()
    singleton:stop()
  end,
  request = function(op, args, cb)
    return singleton:request(op, args, cb)
  end,
}
