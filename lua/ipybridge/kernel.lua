-- Kernel management for ipybridge.nvim
-- Starts/stops a standalone Jupyter kernel and exposes its connection file.

local uv = vim.uv
local fn = vim.fn

local K = {
  job = nil,
  conn_file = nil,
}

local M = {}

-- Ensure a standalone Jupyter kernel is running and return its connection file via callback.
-- cb(ok:boolean, conn_file:string|nil)
function M.ensure(python_cmd, cb)
  if K.job and K.conn_file and uv.fs_stat(K.conn_file) then
    if cb then cb(true, K.conn_file) end
    return
  end
  local cf = fn.tempname() .. '.json'
  local cmd = { python_cmd or 'python3', '-m', 'ipykernel_launcher', '-f', cf }
  local job = fn.jobstart(cmd, {
    on_exit = function() K.job = nil end,
  })
  if job <= 0 then
    if cb then cb(false) end
    return
  end
  K.job = job
  K.conn_file = cf
  -- Poll for the connection file to appear and be non-empty.
  local timer = uv.new_timer()
  local start = uv.now()
  local function tick()
    if (uv.now() - start) > 5000 then
      pcall(timer.stop, timer); pcall(timer.close, timer)
      if cb then cb(false) end
      return
    end
    local st = uv.fs_stat(cf)
    if st and st.type == 'file' and st.size and st.size > 0 then
      pcall(timer.stop, timer); pcall(timer.close, timer)
      if cb then cb(true, cf) end
    end
  end
  timer:start(50, 100, vim.schedule_wrap(tick))
end

-- Resolve the current connection file, starting the kernel if needed.
function M.ensure_conn_file(python_cmd, cb)
  M.ensure(python_cmd, cb)
end

-- Stop the kernel job and clear connection info.
function M.stop()
  if K.job then pcall(fn.jobstop, K.job) end
  K.job = nil
  K.conn_file = nil
end

return M
