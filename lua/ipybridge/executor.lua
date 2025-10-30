-- Execution pipeline manager for ipybridge.nvim.
-- Handles helper bootstrap, runcell helpers, ZMQ queueing, and pending exec flush.

local utils = require('ipybridge.utils')
local py_module = require('ipybridge.py_module')

local Executor = {}
Executor.__index = Executor

local function warn_once(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.WARN)
  end)
end

local function helpers_py_code()
  local template = py_module.source('bootstrap_helpers.py')
  local module_b64 = py_module.base64('ipybridge_ns.py')
  return template:gsub('__MODULE_B64__', module_b64)
end

local function runcell_py_code()
  return require('ipybridge.exec_magics').build()
end

function Executor.new(state, opts)
  local self = setmetatable({}, Executor)
  self.state = state
  self.fn = opts.fn
  self.term_send = opts.term_send
  self.ensure_conn_file = opts.ensure_conn_file
  self.is_open = opts.is_open
  return self
end

function Executor:_default_exec_fallback(code)
  if self.term_send then
    self.term_send(code)
  end
end

function Executor:_dispatch_exec_request(code, opts)
  opts = opts or {}
  local function handle_error(reason)
    if opts.fallback then
      opts.fallback(reason)
    else
      self:_default_exec_fallback(code)
    end
    if opts.on_error then
      opts.on_error(reason)
    end
  end
  local ok, z = pcall(require, 'ipybridge.zmq_client')
  if not ok or not z then
    handle_error('zmq_client_unavailable')
    return
  end
  local dispatched = z.request('exec', { code = code }, function(msg)
    if msg and msg.ok then
      if opts.on_success then
        opts.on_success()
      end
    else
      local err = (msg and msg.error) or 'exec_failed'
      handle_error(err)
    end
  end)
  if not dispatched then
    handle_error('dispatch_failed')
  end
end

function Executor:_send_helpers_via_console(script)
  local st = self.state
  if not self.term_send then
    return false
  end
  if not st._helpers_path then
    st._helpers_path = self.fn.tempname() .. '.myipy_helpers.py'
    local ok = pcall(self.fn.writefile, vim.split(script, "\n", { plain = true }), st._helpers_path)
    if not ok then
      st._helpers_path = nil
      return false
    end
  end
  self.term_send(utils.exec_file_stmt(st._helpers_path))
  return true
end

function Executor:_run_helper_waiters(success)
  local waiters = self.state._helpers_waiters
  if not waiters or #waiters == 0 then
    return
  end
  self.state._helpers_waiters = {}
  for _, cb in ipairs(waiters) do
    local ok, err = pcall(cb, success)
    if not ok then
      warn_once('ipybridge: helper callback failed: ' .. tostring(err))
    end
  end
end

function Executor:_run_runcell_waiters(success)
  local waiters = self.state._runcell_waiters
  if not waiters or #waiters == 0 then
    return
  end
  self.state._runcell_waiters = {}
  for _, cb in ipairs(waiters) do
    local ok, err = pcall(cb, success)
    if not ok then
      warn_once('ipybridge: runcell helper callback failed: ' .. tostring(err))
    end
  end
end

function Executor:after_helpers(cb)
  if type(cb) ~= 'function' then
    return
  end
  local st = self.state
  if st._helpers_sent then
    local ok, err = pcall(cb, true)
    if not ok then
      warn_once('ipybridge: helper callback failed: ' .. tostring(err))
    end
    return
  end
  if not st._helpers_waiters then
    st._helpers_waiters = {}
  end
  table.insert(st._helpers_waiters, cb)
  self:ensure_helpers()
end

function Executor:ensure_helpers()
  local st = self.state
  if st._helpers_sent or st._helpers_pending or not self.is_open() then
    return
  end
  local code = helpers_py_code()
  st._helpers_pending = true
  local handled = false

  local function finalize_ok()
    handled = true
    st._helpers_pending = false
    st._helpers_sent = true
    self:_run_helper_waiters(true)
  end

  local function do_fallback()
    if handled then
      return
    end
    handled = true
    st._helpers_pending = false
    if st._helpers_sent then
      return
    end
    local ok_console = self:_send_helpers_via_console(code)
    if ok_console then
      st._helpers_sent = true
      self:_run_helper_waiters(true)
    else
      self:_run_helper_waiters(false)
      warn_once('ipybridge: failed to load helper script')
    end
  end

  self:queue_exec(code, {
    on_success = finalize_ok,
    on_error = do_fallback,
    fallback = do_fallback,
  })
end

function Executor:ensure_runcell_helpers(cb)
  local st = self.state
  if st._runcell_sent then
    if type(cb) == 'function' then
      local ok, err = pcall(cb, true)
      if not ok then
        warn_once('ipybridge: runcell helper callback failed: ' .. tostring(err))
      end
    end
    return
  end
  if type(cb) == 'function' then
    if not st._runcell_waiters then
      st._runcell_waiters = {}
    end
    table.insert(st._runcell_waiters, cb)
  end
  if st._runcell_pending or not self.is_open() then
    return
  end
  local code = runcell_py_code()
  st._runcell_pending = true
  local resolved = false
  local function resolve(success)
    if resolved then
      return
    end
    resolved = true
    st._runcell_pending = false
    if success then
      st._runcell_sent = true
    end
    self:_run_runcell_waiters(success)
  end
  local function fallback()
    if st._runcell_sent then
      resolve(true)
      return
    end
    if not self.term_send then
      resolve(false)
      warn_once('ipybridge: failed to load runcell helpers (no terminal sender)')
      return
    end
    if not st._runcell_path then
      st._runcell_path = self.fn.tempname() .. '.myipy_runcell.py'
      local ok_write = pcall(self.fn.writefile, vim.split(code, "\n", { plain = true }), st._runcell_path)
      if not ok_write then
        st._runcell_path = nil
        resolve(false)
        warn_once('ipybridge: failed to persist runcell helpers')
        return
      end
    end
    self.term_send(utils.exec_file_stmt(st._runcell_path))
    resolve(true)
  end
  self:exec_with_pipeline(code, {
    require_helpers = true,
    on_success = function()
      resolve(true)
    end,
    on_error = function()
      fallback()
    end,
    fallback = fallback,
  })
end

function Executor:_flush_pending_exec()
  local st = self.state
  if not st._zmq_ready then
    return
  end
  local queue = st._pending_exec
  if not queue or #queue == 0 then
    return
  end
  st._pending_exec = {}
  for _, entry in ipairs(queue) do
    self:_dispatch_exec_request(entry.code, entry.opts or {})
  end
end

function Executor:flush_pending_exec()
  self:_flush_pending_exec()
end

function Executor:_fail_pending_exec(reason)
  local st = self.state
  local queue = st._pending_exec
  if not queue or #queue == 0 then
    return
  end
  st._pending_exec = {}
  for _, entry in ipairs(queue) do
    local opts = entry.opts or {}
    local fallback = opts.fallback
    if fallback then
      fallback(reason)
    else
      self:_default_exec_fallback(entry.code)
    end
    if opts.on_error then
      opts.on_error(reason)
    end
  end
end

function Executor:fail_pending_exec(reason)
  self:_fail_pending_exec(reason)
end

function Executor:queue_exec(code, opts)
  opts = opts or {}
  local st = self.state
  if st._zmq_ready then
    self:_dispatch_exec_request(code, opts)
    return
  end
  if not st._pending_exec then
    st._pending_exec = {}
  end
  table.insert(st._pending_exec, { code = code, opts = opts })
  self:ensure_zmq(function(ok)
    if ok then
      self:_flush_pending_exec()
    else
      self:_fail_pending_exec('zmq_unavailable')
    end
  end)
end

function Executor:exec_with_pipeline(code, opts)
  opts = opts or {}
  local require_helpers = opts.require_helpers == true
  local queue_opts = {
    on_success = opts.on_success,
    on_error = opts.on_error,
    fallback = opts.fallback,
  }
  local function dispatch()
    self:queue_exec(code, queue_opts)
  end
  if require_helpers then
    self:after_helpers(function(ok_helpers)
      if not ok_helpers then
        if opts.fallback then
          opts.fallback('helpers_failed')
        end
        return
      end
      dispatch()
    end)
    return
  end
  dispatch()
end

function Executor:ensure_zmq(cb)
  local st = self.state
  if st._zmq_ready then
    self:_flush_pending_exec()
    if cb then
      cb(true)
    end
    return
  end

  self.ensure_conn_file(function(ok, conn_file)
    if not ok or not conn_file then
      self:_fail_pending_exec('conn_file_unavailable')
      if cb then
        cb(false)
      end
      return
    end
    local z = require('ipybridge.zmq_client')
    local this = debug.getinfo(1, 'S').source:sub(2)
    local plugin_dir = self.fn.fnamemodify(this, ':h')
    local repo_root = self.fn.fnamemodify(plugin_dir, ':h:h')
    local backend = repo_root .. '/python/myipy_kernel_client.py'
    local ok_start = z.start(st.config.python_cmd, conn_file, backend, st.config.zmq_debug)
    if not ok_start then
      self:_fail_pending_exec('zmq_start_failed')
      if cb then
        cb(false)
      end
      return
    end
    local tried = 0
    local function try_ping()
      tried = tried + 1
      if tried > 20 then
        self:_fail_pending_exec('zmq_ping_timeout')
        if cb then
          cb(false)
        end
        return
      end
      local sent = z.request('ping', {}, function(msg)
        if msg and msg.ok and msg.tag == 'pong' then
          st._zmq_ready = true
          self:_flush_pending_exec()
          if cb then
            cb(true)
          end
        else
          vim.defer_fn(try_ping, 100)
        end
      end)
      if not sent then
        vim.defer_fn(try_ping, 100)
      end
    end
    try_ping()
  end)
end

return Executor
