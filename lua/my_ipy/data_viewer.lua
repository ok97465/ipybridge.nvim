-- Data viewer UI for DataFrame/ndarray/object preview.

local api = vim.api

local M = {
  buf = nil,
  win = nil,
  name = nil,
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
  M.win, M.buf, M.name = nil, nil, nil
end

local function layout_size()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.max(70, math.floor(cols * 0.7))
  local h = math.max(18, math.floor(lines * 0.6))
  return w, h
end

local function to_str(v)
  local t = type(v)
  if v == nil then return '' end
  if t == 'string' then return v end
  if t == 'number' or t == 'boolean' then return tostring(v) end
  return tostring(v)
end

local function render_df(data)
  local lines = {}
  table.insert(lines, string.format('DataFrame %s  shape=%sx%s', data.name or '', tostring((data.shape or {})[1] or '?'), tostring((data.shape or {})[2] or '?')))
  table.insert(lines, string.rep('-', 80))
  local cols = data.columns or {}
  if #cols > 0 then
    table.insert(lines, table.concat(vim.tbl_map(tostring, cols), ' | '))
    table.insert(lines, string.rep('-', 80))
  end
  for _, row in ipairs(data.rows or {}) do
    local strs = {}
    for _, v in ipairs(row) do table.insert(strs, to_str(v)) end
    table.insert(lines, table.concat(strs, ' | '))
  end
  return lines
end

local function render_nd(data)
  local lines = {}
  table.insert(lines, string.format('ndarray %s  dtype=%s  shape=%s', data.name or '', tostring(data.dtype or ''), table.concat(vim.tbl_map(tostring, data.shape or {}), 'x')))
  table.insert(lines, string.rep('-', 80))
  if type(data.rows) == 'table' then
    for _, row in ipairs(data.rows) do
      local strs = {}
      for _, v in ipairs(row) do table.insert(strs, to_str(v)) end
      table.insert(lines, table.concat(strs, ' | '))
    end
  elseif type(data.values1d) == 'table' then
    for i, v in ipairs(data.values1d) do
      table.insert(lines, string.format('%4d: %s', i, to_str(v)))
    end
  else
    table.insert(lines, tostring(data.repr or ''))
  end
  return lines
end

local function render_generic(data)
  local lines = {}
  table.insert(lines, string.format('Object %s', data.name or ''))
  table.insert(lines, string.rep('-', 80))
  table.insert(lines, tostring(data.repr or ''))
  return lines
end

local function set_content(lines)
  if not is_open() then return end
  -- Normalize: nvim_buf_set_lines requires each item to be a single line
  local out = {}
  for _, l in ipairs(lines or {}) do
    local s = l
    if type(s) ~= 'string' then s = tostring(s or '') end
    -- Split on CRLF/CR/LF to avoid embedded newlines in a single item
    if s:find("\n") or s:find("\r") then
      for _, part in ipairs(vim.split(s, "\r?\n", { plain = false })) do
        table.insert(out, part)
      end
    else
      table.insert(out, s)
    end
  end
  api.nvim_buf_set_option(M.buf, 'modifiable', true)
  api.nvim_buf_set_lines(M.buf, 0, -1, false, out)
  api.nvim_buf_set_option(M.buf, 'modifiable', false)
end

local function ensure_win(name)
  if is_open() then return end
  M.buf = api.nvim_create_buf(false, true)
  local w, h = layout_size()
  local row = math.floor((vim.o.lines - h) / 4)
  local col = math.floor((vim.o.columns - w) / 2)
  M.win = api.nvim_open_win(M.buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    row = row,
    col = col,
    border = 'single',
    title = ' Preview: ' .. (name or '') .. ' ',
    style = 'minimal',
  })
  api.nvim_set_option_value('buftype', 'nofile', { buf = M.buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = M.buf })
  api.nvim_set_option_value('swapfile', false, { buf = M.buf })
  api.nvim_set_option_value('filetype', 'myipy-view', { buf = M.buf })
  api.nvim_buf_set_option(M.buf, 'modifiable', false)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = M.buf, silent = true, nowait = true, desc = desc })
  end
  map('q', close_win, 'Close')
  map('r', function()
    if M.name then require('my_ipy').request_preview(M.name) end
  end, 'Refresh')
end

function M.open(name)
  M.name = name
  ensure_win(name)
  set_content({ 'Loading preview for ' .. tostring(name) .. ' ...' })
  require('my_ipy').request_preview(name)
end

function M.on_preview(data)
  -- Expect data.name to match current viewer; otherwise open a new viewer.
  local name = data and data.name or M.name
  if not is_open() or (M.name ~= name and name) then
    M.open(name)
  end
  if data and data.error then
    set_content({ 'Error: ' .. tostring(data.error) })
    return
  end
  if not data then return end
  local lines
  if data.kind == 'dataframe' then
    lines = render_df(data)
  elseif data.kind == 'ndarray' then
    lines = render_nd(data)
  else
    lines = render_generic(data)
  end
  set_content(lines)
end

function M.close()
  close_win()
end

return M
