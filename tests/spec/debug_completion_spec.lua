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

local function fresh_module(ctx)
  package.loaded['ipybridge.debug_completion'] = nil
  package.preload['ipybridge.debug_completion'] = nil

  local prev_vim = _G.vim
  _G.vim = {
    schedule = function(cb)
      table.insert(ctx.scheduled, cb)
      cb()
    end,
  }
  local mod = require('ipybridge.debug_completion')
  _G.vim = prev_vim
  return mod
end

it('fetch resolves completion payload from ZMQ client', function()
  local ctx = {
    scheduled = {},
    ensure_calls = 0,
    request_calls = {},
  }

  package.loaded['ipybridge'] = {
    ensure_zmq = function(cb)
      ctx.ensure_calls = ctx.ensure_calls + 1
      cb(true)
    end,
  }

  package.preload['ipybridge.zmq_client'] = function()
    return {
      request = function(op, params, cb)
        table.insert(ctx.request_calls, { op = op, params = params })
        cb({ ok = true, tag = 'complete', data = { matches = { 'value' } } })
        return true
      end,
    }
  end

  local mod = fresh_module(ctx)

  local payload, err
  mod.fetch({ code = 'value', cursor_pos = 5 }, function(result, message)
    payload = result
    err = message
  end)

  assert(ctx.ensure_calls == 1, 'ensure_zmq should be invoked once')
  assert(#ctx.request_calls == 1 and ctx.request_calls[1].op == 'complete', 'request should target complete op')
  assert(payload and payload.matches[1] == 'value', 'payload should be forwarded to callback')
  assert(err == nil, 'error should be nil on success')
  package.loaded['ipybridge'] = nil
  package.preload['ipybridge.zmq_client'] = nil
end)

it('fetch reports zmq_unavailable when ensure_zmq fails', function()
  local ctx = { scheduled = {} }

  package.loaded['ipybridge'] = {
    ensure_zmq = function(cb)
      cb(false)
    end,
  }

  local mod = fresh_module(ctx)

  local payload, err
  mod.fetch({ code = 'x' }, function(result, message)
    payload = result
    err = message
  end)

  assert(payload == nil, 'payload should be nil on failure')
  assert(err == 'zmq_unavailable', 'expected zmq_unavailable error')
  package.loaded['ipybridge'] = nil
end)

it('fetch ignores stale generations when newer request arrives', function()
  local ctx = {
    scheduled = {},
    messages = {},
  }

  local pending_cb

  package.loaded['ipybridge'] = {
    ensure_zmq = function(cb)
      cb(true)
    end,
  }

  package.preload['ipybridge.zmq_client'] = function()
    return {
      request = function(op, params, cb)
        if not pending_cb then
          pending_cb = cb
        else
          cb({ ok = true, tag = 'complete', data = { matches = { 'second' } } })
        end
        return true
      end,
    }
  end

  local mod = fresh_module(ctx)

  local first_results = {}
  local second_results = {}
  mod.fetch({ code = 'first' }, function(result, message)
    table.insert(first_results, { result = result, err = message })
  end)
  mod.fetch({ code = 'second' }, function(result, message)
    table.insert(second_results, { result = result, err = message })
  end)

  pending_cb({ ok = true, tag = 'complete', data = { matches = { 'first' } } })

  assert(#first_results == 0, 'stale generation should not reach callback')
  assert(#second_results == 1, 'latest fetch should resolve once')
  assert(second_results[1].result and second_results[1].result.matches[1] == 'second', 'latest payload should be delivered')
  package.loaded['ipybridge'] = nil
  package.preload['ipybridge.zmq_client'] = nil
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('debug_completion_spec failed')
end

return true
