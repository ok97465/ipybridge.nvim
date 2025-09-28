package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local Json = require('tests.helpers.json')

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



local function fresh_client(env)
  env = env or {}
  local job_opts
  _G.vim = {
    notify = function(msg, level)
      env.last_notify = { msg = msg, level = level }
    end,
    log = { levels = { WARN = 'WARN' } },
    schedule = function(fn)
      fn()
    end,
    defer_fn = function(fn)
      fn()
    end,
    json = {
      encode = function(tbl)
        env.last_encoded = tbl
        return '__json__'
      end,
      decode = Json.decode,
    },
    fn = {
      jobstart = function(cmd, opts)
        env.jobstart_args = { cmd = cmd, opts = opts }
        job_opts = opts
        return env.job_id or 1
      end,
      jobstop = function(job)
        env.stopped = job
        if job_opts and job_opts.on_exit then
          job_opts.on_exit(job)
        end
      end,
      chansend = function(job, payload)
        env.sent = { job = job, payload = payload }
        return #payload
      end,
    },
  }
  package.loaded['ipybridge.zmq_client'] = nil
  local client = require('ipybridge.zmq_client')
  env.job_opts = job_opts
  return client, env
end

it('start launches background job with expected command', function()
  local client, env = fresh_client({ job_id = 42 })
  local ok = client.start('python3', '/tmp/kernel.json', '/path/backend.py', true)
  assert(ok, 'expected start to return true')
  local args = env.jobstart_args
  assert(args, 'jobstart should be invoked')
  assert(args.cmd[1] == 'python3', 'expected python executable')
  assert(args.cmd[3] == '/path/backend.py', 'expected backend path argument')
  assert(args.cmd[#args.cmd] == '--debug', 'expected debug flag when enabled')
  assert(type(args.opts.on_stdout) == 'function', 'stdout handler missing')
  env.job_opts = args.opts
end)

it('request encodes payload and resolves callbacks on stdout', function()
  local client, env = fresh_client({ job_id = 7 })
  client.start('python3', '/tmp/kernel.json', '/path/backend.py', false)
  env.job_opts = env.jobstart_args.opts
  local resolved
  local ok = client.request('ping', { probe = true }, function(msg)
    resolved = msg
  end)
  assert(ok, 'expected request to send message')
  assert(env.sent and env.sent.job == 7, 'expected chansend to target job id')
  assert(env.last_encoded, 'expected json encode to capture payload')
  assert(env.last_encoded.id == '1', 'expected incremental id assignment')
  assert(env.last_encoded.op == 'ping', 'expected ping operation')
  assert(env.last_encoded.args and env.last_encoded.args.probe == true, 'encoded payload mismatch')
  env.job_opts.on_stdout(7, { '{"id":"1","ok":true,"tag":"pong"}' }, nil)
  env.job_opts.on_stdout(7, { '\n' }, nil)
  assert(resolved and resolved.tag == 'pong', 'callback did not receive decoded message')
end)

it('on_exit flushes pending callbacks with failure', function()
  local client, env = fresh_client({ job_id = 9 })
  client.start('python3', '/tmp/kernel.json', '/path/backend.py', false)
  env.job_opts = env.jobstart_args.opts
  local fallback
  client.request('vars', {}, function(msg)
    fallback = msg
  end)
  env.job_opts.on_exit()
  assert(fallback and fallback.ok == false, 'pending callback not informed of exit')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('zmq_client_spec failed')
end

return true
