-- Variable Explorer UI for my_ipy.nvim
-- Renders a floating window listing variables with type/shape/preview.

local api = vim.api

local M = {
  buf = nil,
  win = nil,
  vars = {},
  _line2name = {},
}

local function is_open()
  return M.win and api.nvim_win_is_valid(M.win) and M.buf and api.nvim_buf_is_loaded(M.buf)
end

local function close_win()
  if is_open() then
    pcall(api.nvim_win_close, M.win, true)
  end
  if M.buf and api.nvim_buf_is_loaded(M.buf) then
    pcall(api.nvim_buf_delete, M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
  M._line2name = {}
end

local function fmt_shape(shp)
  if type(shp) ~= 'table' then return '' end
  local ok, first = pcall(function() return shp[1] end)
  if not ok then return '' end
  if #shp == 2 then return string.format('%sx%s', tostring(shp[1]), tostring(shp[2])) end
  return table.concat(vim.tbl_map(tostring, shp), 'x')
end

local function layout_size()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.max(60, math.floor(cols * 0.5))
  local h = math.max(12, math.floor(lines * 0.5))
  return w, h
end

local function render()
  if not is_open() then return end
  local names = {}
  for k, _ in pairs(M.vars or {}) do table.insert(names, k) end
  table.sort(names)
  local lines = {}
  M._line2name = {}
  table.insert(lines, 'Name                Type            Shape     Preview')
  table.insert(lines, string.rep('-', 72))
  for _, name in ipairs(names) do
    local it = M.vars[name] or {}
    local ty = tostring(it.type or ''):gsub('[\r\n]', ' ')
    local shp = fmt_shape(it.shape)
    local pv = tostring(it.repr or ''):gsub('[\r\n]', ' ')
    -- Simple padding; keep to reasonable widths
    local l = string.format('%-20s %-14s %-9s %s', name, ty, shp, pv)
    table.insert(lines, l)
    M._line2name[#lines] = name
  end
  if #lines <= 2 then
    table.insert(lines, '(No user variables) — press r to refresh')
  end
  api.nvim_buf_set_option(M.buf, 'modifiable', true)
  api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  api.nvim_buf_set_option(M.buf, 'modifiable', false)
end

local function ensure_win()
  if is_open() then return end
  M.buf = api.nvim_create_buf(false, true)
  local w, h = layout_size()
  local row = math.floor((vim.o.lines - h) / 3)
  local col = math.floor((vim.o.columns - w) / 2)
  M.win = api.nvim_open_win(M.buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    row = row,
    col = col,
    border = 'single',
    title = ' Variables ',
    style = 'minimal',
  })
  api.nvim_set_option_value('buftype', 'nofile', { buf = M.buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = M.buf })
  api.nvim_set_option_value('swapfile', false, { buf = M.buf })
  api.nvim_set_option_value('filetype', 'myipy-vars', { buf = M.buf })
  api.nvim_buf_set_option(M.buf, 'modifiable', false)
  -- Keymaps
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = M.buf, silent = true, nowait = true, desc = desc })
  end
  map('q', close_win, 'Close')
  map('r', function() require('my_ipy').var_explorer_refresh() end, 'Refresh')
  map('<CR>', function()
    local lnum = api.nvim_win_get_cursor(M.win)[1]
    local name = M._line2name[lnum]
    if name then
      -- Open viewer for selected variable
      require('my_ipy.data_viewer').open(name)
    end
  end, 'Open viewer')
end

function M.open()
  ensure_win()
  render()
end

function M.refresh()
  require('my_ipy').var_explorer_refresh()
end

function M.on_vars(tbl)
  M.vars = tbl or {}
  render()
end

function M.is_open()
  return is_open()
end

function M.close()
  close_win()
end

return M
