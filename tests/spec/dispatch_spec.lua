package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local mock_vim = require('tests.helpers.mock_vim')

local results = {}

local function record(name, ok, err)
  table.insert(results, { name = name, ok = ok, err = err })
  if ok then
    io.write(string.format('[PASS] %s\n', name))
  else
    io.write(string.format('[FAIL] %s: %s\n', name, err))
  end
end

local function fresh_dispatch()
  package.loaded['ipybridge.dispatch'] = nil
  local env = mock_vim.new()
  _G.vim = env.vim
  local dispatch = require('ipybridge.dispatch')
  return env, dispatch
end

local function with_preload(name, loader, fn)
  local prev_loaded = package.loaded[name]
  local prev_preload = package.preload[name]
  package.loaded[name] = nil
  package.preload[name] = loader
  local ok, err = pcall(fn)
  package.loaded[name] = prev_loaded
  if prev_preload ~= nil then
    package.preload[name] = prev_preload
  else
    package.preload[name] = nil
  end
  if not ok then error(err) end
end

local function with_loaded(name, value, fn)
  local prev = package.loaded[name]
  package.loaded[name] = value
  local ok, err = pcall(fn)
  package.loaded[name] = prev
  if not ok then error(err) end
end

local function it(name, fn)
  local ok, err = pcall(fn)
  record(name, ok, err)
end

it('invokes registered handler with matching tag', function()
  local _, dispatch = fresh_dispatch()
  local hit = 0
  dispatch.register('custom', function(msg)
    hit = hit + 1
    assert(msg.data.answer == 42)
  end)
  dispatch.handle({ tag = 'custom', data = { answer = 42 } })
  assert(hit == 1, 'handler not called exactly once')
end)

it('ignores message when tag has no handler', function()
  local env, dispatch = fresh_dispatch()
  dispatch.handle({ tag = 'unknown', data = {} })
  assert(#env.notifications == 0, 'unexpected notification emitted')
end)

it('records notification when handler errors', function()
  local env, dispatch = fresh_dispatch()
  dispatch.register('boom', function()
    error('bad handler')
  end)
  dispatch.handle({ tag = 'boom', data = {} })
  assert(#env.notifications == 1, 'expected single notification')
  local note = env.notifications[1]
  assert(note.level == vim.log.levels.WARN, 'expected WARN level')
  assert(note.message:find('boom', 1, true), 'tag not included in message')
end)

it('lazy vars handler loads module once and transforms payload', function()
  local loads = 0
  local seen = {}
  with_preload('ipybridge.var_explorer', function()
    loads = loads + 1
    return {
      on_vars = function(payload)
        table.insert(seen, payload)
      end,
    }
  end, function()
    local _, dispatch = fresh_dispatch()
    dispatch.handle({ tag = 'vars', data = { count = 2 } })
    dispatch.handle({ tag = 'vars' })
  end)
  assert(loads == 1, 'module should load exactly once')
  assert(#seen == 2, 'handler expected to fire twice')
  assert(seen[1].count == 2, 'payload not forwarded correctly')
  assert(next(seen[2]) == nil, 'missing data should become empty table')
end)

it('lazy vars handler surfaces errors as warnings', function()
  local env, dispatch
  with_preload('ipybridge.var_explorer', function()
    return {
      on_vars = function()
        error('explode')
      end,
    }
  end, function()
    env, dispatch = fresh_dispatch()
    dispatch.handle({ tag = 'vars', data = {} })
  end)
  assert(#env.notifications == 1, 'expected warning notification')
  local note = env.notifications[1]
  assert(note.message:find('vars', 1, true), 'tag missing in warning')
  assert(note.level == vim.log.levels.WARN, 'warning level mismatch')
end)

it('lazy preview handler loads and forwards payload', function()
  local loads = 0
  local received
  with_preload('ipybridge.data_viewer', function()
    loads = loads + 1
    return {
      on_preview = function(payload)
        received = payload
      end,
    }
  end, function()
    local _, dispatch = fresh_dispatch()
    dispatch.handle({ tag = 'preview', data = { rows = 10 } })
  end)
  assert(loads == 1, 'expected data_viewer to load once')
  assert(received and received.rows == 10, 'payload not forwarded correctly')
end)

it('forwards debug_location to bridge module when available', function()
  local captured
  with_loaded('ipybridge', {
    on_debug_location = function(payload)
      captured = payload
    end,
  }, function()
    local _, dispatch = fresh_dispatch()
    dispatch.handle({ tag = 'debug_location', data = { file = 'foo.py', line = 12 } })
  end)
  assert(captured and captured.file == 'foo.py', 'expected payload to be forwarded')
end)

it('unregister removes handlers', function()
  local _, dispatch = fresh_dispatch()
  local hits = 0
  dispatch.register('temp', function()
    hits = hits + 1
  end)
  dispatch.handle({ tag = 'temp', data = {} })
  dispatch.unregister('temp')
  dispatch.handle({ tag = 'temp', data = {} })
  assert(hits == 1, 'handler should not fire after unregister')
end)

it('ignores malformed messages safely', function()
  local env, dispatch = fresh_dispatch()
  local hits = 0
  dispatch.register('valid', function()
    hits = hits + 1
  end)
  dispatch.handle('not a table')
  dispatch.handle({})
  dispatch.handle({ tag = 123 })
  dispatch.handle({ tag = 'missing' })
  assert(hits == 0, 'handler should not fire for malformed messages')
  assert(#env.notifications == 0, 'malformed messages should not emit notifications')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('dispatch_spec failed')
end

return true
