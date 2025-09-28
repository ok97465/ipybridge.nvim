package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local results = {}

local function record(name, ok, err)
  table.insert(results, { name = name, ok = ok, err = err })
  if ok then
    io.write(string.format('[PASS] %s\n', name))
  else
    io.write(string.format('[FAIL] %s: %s\n', name, err))
  end
end

local function it(name, fn)
  local ok, err = pcall(fn)
  record(name, ok, err)
end

local function fake_vim(env)
  env = env or {}
  local timer = {
    started = false,
    start = function(self, _delay, _repeat, cb)
      self.started = true
      env.tick = cb
    end,
  }
  local uv = {
    now = function()
      return env.now or 0
    end,
    fs_stat = function(path)
      if env.fs_stat then
        return env.fs_stat(path)
      end
      return nil
    end,
    new_timer = function()
      return timer
    end,
  }
  local fn = {
    tempname = function()
      return env.tempname or '/tmp/conn'
    end,
    jobstart = function(cmd, opts)
      env.jobstart_args = { cmd = cmd, opts = opts }
      if env.jobstart_result then
        return env.jobstart_result
      end
      return 1
    end,
    jobstop = function(job)
      env.stopped = job
    end,
  }
  local function schedule_wrap(cb)
    return function()
      return cb()
    end
  end
  _G.vim = {
    uv = uv,
    fn = fn,
    schedule_wrap = schedule_wrap,
  }
  return env
end

local function fresh_kernel(env)
  fake_vim(env)
  package.loaded['ipybridge.kernel'] = nil
  return require('ipybridge.kernel')
end

it('ensure reuses running kernel when connection file exists', function()
  local env = {
    fs_stat = function()
      return { type = 'file', size = 10 }
    end,
  }
  local kernel = fresh_kernel(env)
  kernel.ensure('python3', function(ok, conn)
    assert(ok, 'expected ok flag')
    assert(conn, 'expected conn file')
  end)
end)

it('ensure reports failure when jobstart fails', function()
  local env = {
    jobstart_result = -1,
  }
  local kernel = fresh_kernel(env)
  kernel.ensure('python3', function(ok)
    assert(ok == false, 'expected failure flag')
  end)
end)

it('ensure polls until connection file appears', function()
  local env = {
    fs_stat = function()
      return nil
    end,
    now = 0,
  }
  local kernel = fresh_kernel(env)
  local called = false
  kernel.ensure('python3', function(ok, conn)
    called = true
    assert(ok == true, 'expected success after file appears')
    assert(conn:match('%.json$'), 'expected json connection file')
  end)
  assert(env.jobstart_args, 'expected jobstart to be invoked')
  env.fs_stat = function()
    return { type = 'file', size = 1 }
  end
  env.tick()
  assert(called, 'expected callback after tick')
end)

it('stop terminates job and clears state', function()
  local env = {}
  local kernel = fresh_kernel(env)
  kernel.ensure('python3', function() end)
  assert(env.jobstart_args, 'job should start')
  kernel.stop()
  assert(env.stopped == 1 or env.stopped == env.jobstart_result, 'expected jobstop to be called')
  env.fs_stat = function()
    return { type = 'file', size = 1 }
  end
  kernel.ensure('python3', function(ok)
    assert(ok, 'kernel should start again after stop')
  end)
  env.tick()
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('kernel_spec failed')
end

return true
