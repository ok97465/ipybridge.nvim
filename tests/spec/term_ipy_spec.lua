package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local mock_vim = require('tests.helpers.mock_vim')
local json = require('tests.helpers.json')

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

local function fresh_term(opts)
  package.loaded['ipybridge.term_ipy'] = nil
  local env = mock_vim.new()
  _G.vim = env.vim
  vim.NIL = json.NIL
  -- Provide minimal api/fn tables required by term_ipy
  vim.api = {
    nvim_buf_is_loaded = function() return true end,
    nvim_win_is_valid = function() return true end,
    nvim_buf_line_count = function() return 1 end,
    nvim_win_set_cursor = function() end,
    nvim_win_get_buf = function() return 1 end,
    nvim_get_current_win = function() return 1 end,
    nvim_create_buf = function() return 2 end,
    nvim_set_current_buf = function() end,
    nvim_win_close = function() end,
    nvim_chan_send = function() end,
  }
  vim.json = {
    decode = function(str)
      return json.decode(str)
    end,
  }
  vim.fn = {
    termopen = function(_, cfg)
      -- Capture callbacks for manual triggering
      return 1
    end,
  }
  vim.cmd = function() end
  local term_mod = require('ipybridge.term_ipy')
  local term = term_mod.TermIpy:new('dummy', '.', opts)
  return env, term
end

local OSC_PREFIX = '\27]5379;ipybridge:'

it('decodes OSC payload and forwards to handler', function()
  local seen = {}
  local _, term = fresh_term({
    on_message = function(msg)
      table.insert(seen, msg)
    end,
  })
  term:__on_stdout({ OSC_PREFIX .. 'vars:{"answer": 42}\7' })
  assert(#seen == 1, 'expected single message')
  assert(seen[1].tag == 'vars', 'tag mismatch')
  assert(seen[1].data.answer == 42, 'payload mismatch')
end)

it('buffers partial OSC payload until complete', function()
  local seen = {}
  local _, term = fresh_term({
    on_message = function(msg)
      table.insert(seen, msg)
    end,
  })
  local prefix = OSC_PREFIX .. 'preview:{"ok":'
  local suffix = ' true}\7'
  term:__on_stdout({ prefix })
  assert(#seen == 0, 'unexpected early message')
  term:__on_stdout({ suffix })
  assert(#seen == 1, 'message not delivered after completion')
  assert(seen[1].tag == 'preview', 'tag mismatch after completion')
  assert(seen[1].data.ok == true, 'payload mismatch after completion')
end)

it('skips invalid JSON payloads with warning', function()
  local env, term = fresh_term()
  term:__on_stdout({ OSC_PREFIX .. 'vars:{bad json}\7' })
  assert(#env.notifications == 1, 'expected warning notification')
  assert(env.notifications[1].message:find('vars', 1, true), 'tag missing in notification')
end)

it('strips hidden payload while preserving visible text', function()
  local seen = {}
  local _, term = fresh_term({
    on_message = function(msg)
      table.insert(seen, msg)
    end,
  })
  local chunk = '>>> print(42)' .. OSC_PREFIX .. 'vars:{"numbers": [1, 2, 3]}\7after'
  local visible = term:__extract_hidden(chunk)
  assert(visible == '>>> print(42)after', 'expected visible text without payload markers')
  assert(#seen == 1, 'hidden payload should produce one message')
  assert(seen[1].data.numbers[2] == 2, 'array payload not decoded as Lua list')
end)

it('handles multiple hidden payloads within one chunk', function()
  local seen = {}
  local _, term = fresh_term({
    on_message = function(msg)
      table.insert(seen, msg)
    end,
  })
  local chunk = OSC_PREFIX .. 'vars:{"value": 1}\7visible' .. OSC_PREFIX .. 'preview:{"rows": 2}\7'
  local visible = term:__extract_hidden(chunk)
  assert(visible == 'visible', 'unexpected visible output')
  assert(#seen == 2, 'expected two decoded messages')
  assert(seen[1].tag == 'vars', 'first payload tag mismatch')
  assert(seen[2].tag == 'preview', 'second payload tag mismatch')
end)

it('retains partial prefix across chunks', function()
  local seen = {}
  local _, term = fresh_term({
    on_message = function(msg)
      table.insert(seen, msg)
    end,
  })
  local first = 'noise' .. OSC_PREFIX:sub(1, 5)
  local second = OSC_PREFIX:sub(6) .. 'vars:{"flag": true}\7tail'
  local visible_first = term:__extract_hidden(first)
  assert(visible_first == 'noise', 'first chunk should return only visible prefix')
  assert(#seen == 0, 'handler should not run until suffix arrives')
  local visible_second = term:__extract_hidden(second)
  assert(visible_second == 'tail', 'second chunk should include trailing text')
  assert(#seen == 1, 'payload should be emitted once suffix arrives')
  assert(seen[1].data.flag == true, 'decoded payload mismatch after recombination')
  assert(term._osc_pending == '', 'pending buffer should be cleared after full message')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('term_ipy_spec failed')
end

return true
