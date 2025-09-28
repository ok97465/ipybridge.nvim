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

local function fake_env()
  local env = {
    buffers = {},
    windows = {},
    keymaps = {},
    last_refresh = 0,
    last_open = nil,
  }
  local function new_buf()
    local id = #env.buffers + 1
    env.buffers[id] = { lines = {} }
    return id
  end
  local function new_win(buf, opts)
    local id = #env.windows + 1
    env.windows[id] = { buf = buf, opts = opts, cursor = { 1, 0 } }
    return id
  end
  local function buf_lines(buf)
    return env.buffers[buf] and env.buffers[buf].lines or {}
  end

  _G.vim = {
    o = { columns = 100, lines = 40 },
    tbl_map = function(fn, list)
      local out = {}
      for i, v in ipairs(list) do
        out[i] = fn(v, i)
      end
      return out
    end,
    api = {
      nvim_win_is_valid = function(win)
        return env.windows[win] ~= nil
      end,
      nvim_buf_is_loaded = function(buf)
        return env.buffers[buf] ~= nil
      end,
      nvim_win_close = function(win)
        env.windows[win] = nil
      end,
      nvim_buf_delete = function(buf)
        env.buffers[buf] = nil
      end,
      nvim_create_buf = function()
        return new_buf()
      end,
      nvim_open_win = function(buf, _, opts)
        return new_win(buf, opts)
      end,
      nvim_set_option_value = function() end,
      nvim_buf_set_option = function() end,
      nvim_buf_set_lines = function(buf, _, _, _, lines)
        env.buffers[buf].lines = lines
      end,
      nvim_win_get_cursor = function(win)
        return env.windows[win].cursor
      end,
      nvim_win_set_cursor = function(win, pos)
        env.windows[win].cursor = pos
      end,
    },
    keymap = {
      set = function(_, lhs, rhs)
        env.keymaps[lhs] = rhs
      end,
    },
  }

  package.loaded['ipybridge'] = {
    var_explorer_refresh = function()
      env.last_refresh = env.last_refresh + 1
    end,
  }

  package.loaded['ipybridge.data_viewer'] = {
    open = function(name)
      env.last_open = name
    end,
  }

  package.loaded['ipybridge.var_explorer'] = nil
  local explorer = require('ipybridge.var_explorer')
  return explorer, env, buf_lines
end

it('on_vars renders a sorted table of variables', function()
  local explorer, env, buf_lines = fake_env()
  explorer.open()
  explorer.on_vars({
    beta = { type = 'int', repr = '2' },
    alpha = { type = 'list', repr = '[1, 2, 3]' },
  })
  local lines = buf_lines(explorer.buf)
  assert(lines[1]:match('Name'), 'expected header row')
  assert(lines[3]:match('alpha'), 'names should be sorted alphabetically')
  assert(lines[4]:match('beta'), 'expected beta entry')
end)

it('enter key opens preview for expandable variable', function()
  local explorer, env = fake_env()
  explorer.open()
  explorer.on_vars({
    data = { type = 'DataFrame', kind = 'dataframe', repr = '<df>' },
  })
  env.windows[explorer.win].cursor = { 3, 0 }
  assert(env.keymaps['<CR>'], 'enter mapping should be registered')
  env.keymaps['<CR>']()
  assert(env.last_open == 'data', 'expected data viewer to open for previewable variable')
end)

it('refresh delegates to ipybridge refresh helper when not in debug mode', function()
  local explorer, env = fake_env()
  explorer.refresh()
  assert(env.last_refresh == 1, 'refresh should call backend helper')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('var_explorer_spec failed')
end

return true
