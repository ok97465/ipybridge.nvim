-- ZMQ client manager for my_ipy.nvim
-- Spawns a background Python process that attaches to the existing IPython kernel
-- via Jupyter's connection file and serves NDJSON over stdio.

local fn = vim.fn
local api = vim.api

local M = {
  job = nil,
  buf = "",
  pending = {}, -- id -> callback
  next_id = 1,
}

local function gen_id()
  local id = tostring(M.next_id)
  M.next_id = M.next_id + 1
  return id
end

local function on_stdout(job_id, data, _)
  if not data then return end
  for _, chunk in ipairs(data) do
    if chunk and #chunk > 0 then
      M.buf = M.buf .. chunk .. "\n"
    end
  end
  while true do
    local s, e = M.buf:find("\n")
    if not s then break end
    local line = M.buf:sub(1, s - 1)
    M.buf = M.buf:sub(e + 1)
    if #line > 0 then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == 'table' and msg.id then
        local cb = M.pending[msg.id]
        M.pending[msg.id] = nil
        if cb then pcall(cb, msg) end
      end
    end
  end
end

local function on_stderr(job_id, data, _)
  if not data then return end
  local msg = table.concat(data, "\n")
  if #vim.trim(msg) > 0 then
    vim.schedule(function()
      vim.notify('[my_ipy.zmq] stderr: ' .. msg, vim.log.levels.WARN)
    end)
  end
end

local function on_exit()
  for id, cb in pairs(M.pending) do
    pcall(cb, { id = id, ok = false, error = 'zmq client exited' })
  end
  M.pending = {}
  M.job = nil
  M.buf = ""
end

function M.is_running()
  return M.job ~= nil
end

function M.start(python_cmd, conn_file, module_path)
  if M.is_running() then return true end
  local cmd = { python_cmd or 'python3', '-u', module_path, '--conn-file', conn_file }
  local job = fn.jobstart(cmd, {
    on_stdout = on_stdout,
    stdout_buffered = false,
    on_stderr = on_stderr,
    stderr_buffered = false,
    on_exit = on_exit,
  })
  if job <= 0 then return false end
  M.job = job
  return true
end

function M.stop()
  if M.job then pcall(fn.jobstop, M.job) end
  on_exit()
end

local function send_msg(msg)
  if not M.job then return false end
  local line = vim.json.encode(msg) .. "\n"
  return fn.chansend(M.job, line) > 0
end

function M.request(op, args, cb)
  if not M.job then return false end
  local id = gen_id()
  M.pending[id] = cb
  return send_msg({ id = id, op = op, args = args or {} })
end

return M
