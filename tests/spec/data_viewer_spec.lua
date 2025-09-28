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
    last_request = nil,
    columns = 120,
    lines = 60,
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
    o = { columns = env.columns, lines = env.lines },
    tbl_map = function(fn, list)
      local out = {}
      for i, v in ipairs(list) do
        out[i] = fn(v, i)
      end
      return out
    end,
    split = function(str, _, _)
      local out = {}
      for line in tostring(str):gmatch('[^\n]+') do
        table.insert(out, line)
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
      nvim_win_set_config = function(win, cfg)
        env.windows[win].opts = cfg
      end,
      nvim_win_get_cursor = function(win)
        return env.windows[win].cursor
      end,
      nvim_win_set_cursor = function(win, pos)
        env.windows[win].cursor = pos
      end,
      nvim_list_wins = function()
        local list = {}
        for win in pairs(env.windows) do
          table.insert(list, win)
        end
        return list
      end,
      nvim_win_get_buf = function(win)
        return env.windows[win].buf
      end,
    },
    keymap = {
      set = function(mode, lhs, rhs)
        env.keymaps[lhs] = rhs
      end,
    },
  }

  package.loaded['ipybridge'] = {
    config = { viewer_max_rows = 30, viewer_max_cols = 20 },
    request_preview = function(name, opts)
      env.last_request = { name = name, opts = opts }
    end,
  }

  package.loaded['ipybridge.data_viewer'] = nil
  local viewer = require('ipybridge.data_viewer')
  return viewer, env, buf_lines
end

it('on_preview renders dataframe payload into buffer', function()
  local viewer, env, buf_lines = fake_env()
  viewer.on_preview({
    name = 'df',
    kind = 'dataframe',
    total_shape = { 10, 2 },
    row_offset = 0,
    col_offset = 0,
    rows = {
      { 'a', 'b' },
      { 'c', 'd' },
    },
    columns = { 'x', 'y' },
  })
  local lines = buf_lines(viewer.buf)
  assert(lines[1]:match('DataFrame'), 'expected header line')
  assert(lines[4]:match('x | y'), 'expected column header')
  assert(viewer._window.row_offset == 0, 'row offset should persist from payload')
  assert(viewer._line2path[4] == nil, 'dataframe header should not register drilldown path')
end)

it('move_rows via keymap requests next window', function()
  local viewer, env = fake_env()
  viewer.on_preview({
    name = 'df',
    kind = 'dataframe',
    total_shape = { 10, 2 },
    row_offset = 0,
    col_offset = 0,
    max_rows = 3,
    max_cols = 2,
    rows = {
      { 'a', 'b' },
    },
    columns = { 'x', 'y' },
  })
  assert(env.keymaps['<C-f>'], 'expected next rows keymap to be registered')
  env.keymaps['<C-f>']()
  assert(env.last_request, 'expected request_preview invocation')
  assert(env.last_request.opts.row_offset == 3, 'row offset should advance by window size')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('data_viewer_spec failed')
end

return true
