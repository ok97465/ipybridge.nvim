-- Data viewer UI for DataFrame/ndarray/object preview.

local api = vim.api

local M = {
  buf = nil,
  win = nil,
  name = nil,
  _line2path = {},
  _last = nil,
  _window = nil,
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
  M._window = nil
end

local function layout_size()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.max(70, math.floor(cols * 0.7))
  local h = math.max(18, math.floor(lines * 0.6))
  return w, h
end

local function viewer_limits()
  local ok_bridge, bridge = pcall(require, 'ipybridge')
  if not ok_bridge or type(bridge) ~= 'table' then
    return 30, 20
  end
  local cfg = bridge.config or {}
  local rows = tonumber(cfg.viewer_max_rows) or 30
  local cols = tonumber(cfg.viewer_max_cols) or 20
  if rows <= 0 then rows = 30 end
  if cols <= 0 then cols = 20 end
  return rows, cols
end

local function clamp_offset(offset, delta, total, window)
  local target = offset + delta
  if target < 0 then target = 0 end
  if total and total > 0 and window and window > 0 then
    local max_offset = math.max(total - window, 0)
    if target > max_offset then
      target = max_offset
    end
  end
  return target
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
  local shape = data.total_shape or data.shape or {}
  table.insert(lines, string.format('DataFrame %s  shape=%sx%s', data.name or '', tostring(shape[1] or '?'), tostring(shape[2] or '?')))
  local row_offset = tonumber(data.row_offset) or 0
  local col_offset = tonumber(data.col_offset) or 0
  local window_rows = #(data.rows or {})
  local window_cols = #(data.columns or {})
  local row_end = row_offset + window_rows - 1
  if row_end < row_offset then row_end = row_offset end
  local col_end = col_offset + window_cols - 1
  if col_end < col_offset then col_end = col_offset end
  table.insert(lines, string.format('window rows %d-%d cols %d-%d', row_offset, row_end, col_offset, col_end))
  table.insert(lines, string.rep('-', 80))
  local cols = data.columns or {}
  if #cols > 0 then
    table.insert(lines, table.concat(vim.tbl_map(tostring, cols), ' | '))
    table.insert(lines, string.rep('-', 80))
  end
  for idx, row in ipairs(data.rows or {}) do
    local strs = {}
    for _, v in ipairs(row) do table.insert(strs, to_str(v)) end
    local row_index = row_offset + idx - 1
    table.insert(lines, string.format('%6d | %s', row_index, table.concat(strs, ' | ')))
  end
  return lines
end

local function render_nd(data)
  local lines = {}
  local shape = data.total_shape or data.shape or {}
  table.insert(lines, string.format('ndarray %s  dtype=%s  shape=%s', data.name or '', tostring(data.dtype or ''), table.concat(vim.tbl_map(tostring, data.shape or {}), 'x')))
  local row_offset = tonumber(data.row_offset) or 0
  local col_offset = tonumber(data.col_offset) or 0
  local window_rows = 0
  local window_cols = 0
  if type(data.rows) == 'table' then
    window_rows = #data.rows
    window_cols = #(data.rows[1] or {})
    local row_end = row_offset + window_rows - 1
    if row_end < row_offset then row_end = row_offset end
    local col_end = col_offset + window_cols - 1
    if col_end < col_offset then col_end = col_offset end
    table.insert(lines, string.format('window rows %d-%d cols %d-%d', row_offset, row_end, col_offset, col_end))
    table.insert(lines, string.rep('-', 80))
    for idx, row in ipairs(data.rows) do
      local strs = {}
      for _, v in ipairs(row) do table.insert(strs, to_str(v)) end
      local row_index = row_offset + idx - 1
      table.insert(lines, string.format('%6d | %s', row_index, table.concat(strs, ' | ')))
    end
  elseif type(data.values1d) == 'table' then
    window_rows = #data.values1d
    local row_end = row_offset + window_rows - 1
    if row_end < row_offset then row_end = row_offset end
    table.insert(lines, string.format('window rows %d-%d', row_offset, row_end))
    table.insert(lines, string.rep('-', 80))
    for i, v in ipairs(data.values1d) do
      local row_index = row_offset + i - 1
      table.insert(lines, string.format('%6d: %s', row_index, to_str(v)))
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

-- Render dataclass preview
local function render_dataclass(data)
  local lines = {}
  local map = {}
  local cname = tostring(data.class_name or '')
  table.insert(lines, string.format('dataclass %s', cname))
  table.insert(lines, string.rep('-', 80))
  local fields = type(data.fields) == 'table' and data.fields or {}
  if #fields == 0 then
    table.insert(lines, '(no fields)')
    return lines, map
  end
  for _, it in ipairs(fields) do
    local fname = tostring(it.name or '')
    local ty = tostring(it.type or '')
    local kind = tostring(it.kind or '')
    if kind == 'ndarray' then
      local shp = it.shape or {}
      local dtype = tostring(it.dtype or '')
      table.insert(lines, string.format('%s <%s> ndarray shape=%s dtype=%s', fname, ty, table.concat(vim.tbl_map(tostring, shp), 'x'), dtype))
      map[#lines] = (M.name or data.name or '') .. '.' .. fname
    elseif kind == 'dataframe' then
      local shp = it.shape or {}
      local shape_str = (#shp >= 2) and (tostring(shp[1]) .. 'x' .. tostring(shp[2])) or table.concat(vim.tbl_map(tostring, shp), 'x')
      table.insert(lines, string.format('%s <%s> DataFrame shape=%s', fname, ty, shape_str))
      map[#lines] = (M.name or data.name or '') .. '.' .. fname
    else
      table.insert(lines, string.format('%s <%s> = %s', fname, ty, to_str(it.repr)))
      local r = tostring(it.repr or '')
      if #r >= 3 and r:sub(-3) == '...' then
        map[#lines] = (M.name or data.name or '') .. '.' .. fname
      end
    end
  end
  return lines, map
end

-- Render ctypes.Structure preview
local function render_ctypes(data)
  local lines = {}
  local map = {}
  local sname = tostring(data.struct_name or '')
  table.insert(lines, string.format('ctypes.Structure %s', sname))
  table.insert(lines, string.rep('-', 80))
  local fields = type(data.fields) == 'table' and data.fields or {}
  if #fields == 0 then
    table.insert(lines, '(no fields)')
    return lines, map
  end
  for _, it in ipairs(fields) do
    local fname = tostring(it.name or '')
    local ctype = tostring(it.ctype or '')
    local kind = tostring(it.kind or '')
    if kind == 'array' then
      local vals = {}
      for _, v in ipairs(it.values or {}) do table.insert(vals, to_str(v)) end
      local suffix = ''
      if type(it.length) == 'number' then suffix = string.format(' len=%d', it.length) end
      table.insert(lines, string.format('%s [%s]%s: [ %s ]', fname, ctype, suffix, table.concat(vals, ', ')))
      map[#lines] = (M.name or data.name or '') .. '.' .. fname
    elseif kind == 'struct' then
      -- Nested struct: render as JSON-ish
      local v = it.value
      local ok, encoded = pcall(vim.fn.json_encode, v)
      table.insert(lines, string.format('%s [%s]: %s', fname, ctype, ok and encoded or to_str(v)))
      map[#lines] = (M.name or data.name or '') .. '.' .. fname
    else
      table.insert(lines, string.format('%s [%s]: %s', fname, ctype, to_str(it.value)))
      -- For scalars, usually not drillable
    end
  end
  return lines, map
end

-- Render standalone ctypes.Array preview
local function render_ctypes_array(data)
  local lines = {}
  table.insert(lines, string.format('ctypes.Array %s len=%s', tostring(data.ctype or ''), tostring(data.length or '')))
  table.insert(lines, string.rep('-', 80))
  local vals = {}
  for _, v in ipairs(data.values or {}) do table.insert(vals, to_str(v)) end
  table.insert(lines, '[ ' .. table.concat(vals, ', ') .. ' ]')
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

local function update_title(name)
  if not is_open() then return end
  local ok = pcall(api.nvim_win_set_config, M.win, { title = ' Preview: ' .. (name or '') .. ' ' })
  if not ok then
    -- ignore if not supported
  end
end

local function current_offsets()
  local window = M._window or {}
  local row_offset = tonumber(window.row_offset) or 0
  local col_offset = tonumber(window.col_offset) or 0
  if row_offset < 0 then row_offset = 0 end
  if col_offset < 0 then col_offset = 0 end
  return row_offset, col_offset
end

local function request_with_offsets(row_offset, col_offset)
  if not M.name then return end
  local label = 'Loading preview for ' .. tostring(M.name) .. ' ...'
  if row_offset ~= 0 or col_offset ~= 0 then
    label = label .. string.format(' [rows %d cols %d]', row_offset, col_offset)
  end
  set_content({ label })
  require('ipybridge').request_preview(M.name, {
    row_offset = row_offset,
    col_offset = col_offset,
  })
end

local function window_shape_dim(dim)
  if not M._window then return nil end
  local shape = M._window.shape
  if type(shape) ~= 'table' then return nil end
  local value = shape[dim]
  if type(value) ~= 'number' then value = tonumber(value) end
  return value
end

local function move_rows(direction)
  if not M._window then return end
  local kind = M._window.kind
  if kind ~= 'ndarray' and kind ~= 'dataframe' then
    return
  end
  local default_rows = select(1, viewer_limits())
  local rows_step = tonumber(M._window.max_rows) or default_rows
  if rows_step <= 0 then rows_step = default_rows end
  local current_row, current_col = current_offsets()
  local total_rows = window_shape_dim(1)
  local new_row = clamp_offset(current_row, rows_step * direction, total_rows, rows_step)
  if new_row == current_row then return end
  request_with_offsets(new_row, current_col)
end

local function move_cols(direction)
  if not M._window then return end
  local kind = M._window.kind
  if kind ~= 'ndarray' and kind ~= 'dataframe' then
    return
  end
  local default_cols = select(2, viewer_limits())
  local viewer_cols = tonumber(M._window.max_cols) or default_cols
  if viewer_cols <= 0 then viewer_cols = default_cols end
  local current_row, current_col = current_offsets()
  local total_cols = window_shape_dim(2)
  if (not total_cols or total_cols <= 1) and current_col == 0 and direction ~= 0 then
    return
  end
  if total_cols and total_cols <= viewer_cols and current_col == 0 and direction > 0 then
    return
  end
  local new_col = clamp_offset(current_col, viewer_cols * direction, total_cols, viewer_cols)
  if new_col == current_col then return end
  request_with_offsets(current_row, new_col)
end

local function drilldown_current()
  if not is_open() then return end
  local lnum = api.nvim_win_get_cursor(M.win)[1]
  local path = M._line2path[lnum]
  if path and type(path) == 'string' and #path > 0 then
    M.name = path
    M._window = { row_offset = 0, col_offset = 0 }
    update_title(path)
    request_with_offsets(0, 0)
  end
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
  api.nvim_set_option_value('filetype', 'ipybridge-view', { buf = M.buf })
  api.nvim_buf_set_option(M.buf, 'modifiable', false)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = M.buf, silent = true, nowait = true, desc = desc })
  end
  map('q', close_win, 'Close')
  map('r', function()
    if not M.name then return end
    local row_off, col_off = current_offsets()
    request_with_offsets(row_off, col_off)
  end, 'Refresh')
  map('<C-f>', function() move_rows(1) end, 'Next rows')
  map('<C-b>', function() move_rows(-1) end, 'Previous rows')
  map('<C-l>', function() move_cols(1) end, 'Next cols')
  map('<C-h>', function() move_cols(-1) end, 'Previous cols')
  map('<C-Right>', function() move_cols(1) end, 'Next cols')
  map('<C-Left>', function() move_cols(-1) end, 'Previous cols')
  map('<CR>', drilldown_current, 'Drill-down preview')
end

function M.open(name)
  M.name = name
  ensure_win(name)
  M._window = { row_offset = 0, col_offset = 0 }
  update_title(name)
  request_with_offsets(0, 0)
end

function M.on_preview(data)
  if data == vim.NIL then data = nil end
  -- Expect data.name to match current viewer; otherwise open a new viewer.
  local name = data and data.name or M.name
  if not is_open() or (M.name ~= name and name) then
    M.open(name)
  end
  if data and data.error then
    set_content({ 'Error: ' .. tostring(data.error) })
    return
  end
  if not data or type(data) ~= 'table' then
    set_content({ 'Preview unavailable' })
    return
  end
  local window = M._window or {}
  local default_rows, default_cols = viewer_limits()
  window.row_offset = tonumber(data.row_offset) or 0
  window.col_offset = tonumber(data.col_offset) or 0
  window.max_rows = tonumber(data.max_rows) or default_rows
  window.max_cols = tonumber(data.max_cols) or default_cols
  if type(data.total_shape) == 'table' then
    window.shape = data.total_shape
  elseif type(data.shape) == 'table' then
    window.shape = data.shape
  else
    window.shape = nil
  end
  window.kind = data.kind
  M._window = window
  local lines, map = nil, {}
  if data.kind == 'dataframe' then
    lines = render_df(data)
  elseif data.kind == 'ndarray' then
    lines = render_nd(data)
  elseif data.kind == 'dataclass' then
    lines, map = render_dataclass(data)
  elseif data.kind == 'ctypes' then
    lines, map = render_ctypes(data)
  elseif data.kind == 'ctypes_array' then
    lines = render_ctypes_array(data)
  else
    lines = render_generic(data)
  end
  M._last = data
  M._line2path = map or {}
  set_content(lines)
end

function M.close()
  close_win()
end

return M
