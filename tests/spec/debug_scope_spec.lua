package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local debug_scope = require('ipybridge.debug_scope')

-- Exercises debug scope resolver fallbacks and precedence rules.

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

local function expect_table_equal(actual, expected)
  assert(type(actual) == 'table', 'expected table result')
  for k, v in pairs(expected) do
    local av = actual[k]
    assert(av ~= nil, string.format('expected key %s to exist', k))
    if type(v) == 'table' then
      assert(type(av) == 'table', string.format('expected key %s to be table', k))
      for subk, subv in pairs(v) do
        assert(av[subk] == subv, string.format('expected key %s.%s to match', k, subk))
      end
      for subk in pairs(av) do
        assert(v[subk] ~= nil, string.format('unexpected key %s.%s in result', k, subk))
      end
    else
      assert(av == v, string.format('expected key %s to match', k))
    end
  end
  for k in pairs(actual) do
    assert(expected[k] ~= nil, string.format('unexpected key %s in result', k))
  end
end

it('returns locals when globals snapshot is empty while globals are preferred', function()
  local locals_snapshot = { __locals__ = { data = { repr = 'ndarray' }, __meta = true } }
  local globals_snapshot = { __globals__ = {}, __scoped__ = true }
  local scope = debug_scope.resolve_scope(false, locals_snapshot, globals_snapshot)
  expect_table_equal(scope, { data = { repr = 'ndarray' } })
end)

it('prefers locals when requested and they exist', function()
  local locals_snapshot = { __locals__ = { value = { repr = '42' } } }
  local globals_snapshot = { __globals__ = { other = { repr = '0' } } }
  local scope = debug_scope.resolve_scope(true, locals_snapshot, globals_snapshot)
  expect_table_equal(scope, { value = { repr = '42' } })
end)

it('falls back to globals when available and locals missing', function()
  local locals_snapshot = { __locals__ = {} }
  local globals_snapshot = { __globals__ = { shared = { repr = 'global' } } }
  local scope = debug_scope.resolve_scope(false, locals_snapshot, globals_snapshot)
  expect_table_equal(scope, { shared = { repr = 'global' } })
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('debug_scope_spec failed')
end

return true
