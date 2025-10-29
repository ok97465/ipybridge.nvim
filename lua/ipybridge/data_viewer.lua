-- Data viewer UI for DataFrame/ndarray/object preview.
-- Window orchestration lives here; rendering logic resides in viewer.renderers.

local api = vim.api
local Renderers = require('ipybridge.viewer.renderers')

local ViewerState = {}
ViewerState.__index = ViewerState

function ViewerState:new()
  return setmetatable({
    buf = nil,
    win = nil,
    name = nil,
    _line2path = {},
    _last = nil,
    _window = nil,
  }, self)
end

function ViewerState:is_open()
  return self.win and api.nvim_win_is_valid(self.win) and self.buf and api.nvim_buf_is_loaded(self.buf)
end

function ViewerState:close_window()
  if self:is_open() then
    pcall(api.nvim_win_close, self.win, true)
  end
  if self.buf and api.nvim_buf_is_loaded(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf, self.win, self.name = nil, nil, nil
  self._window = nil
  self._line2path = {}
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
  if rows <= 0 then
    rows = 30
  end
  if cols <= 0 then
    cols = 20
  end
  return rows, cols
end

local function preview_kind(payload)
  if type(payload) ~= 'table' then
    return nil
  end
  local kind = payload.kind
  if kind == 'object' then
    local seq = payload.sequence_kind
    if type(seq) == 'string' and seq ~= '' then
      return seq
    end
  end
  return kind
end

local function clamp_offset(offset, delta, total, window)
  local target = offset + delta
  if target < 0 then
    target = 0
  end
  if total and total > 0 and window and window > 0 then
    local max_offset = math.max(total - window, 0)
    if target > max_offset then
      target = max_offset
    end
  end
  return target
end

function ViewerState:set_content(lines)
  if not self:is_open() then
    return
  end
  local out = {}
  for _, l in ipairs(lines or {}) do
    local s = l
    if type(s) ~= 'string' then
      s = tostring(s or '')
    end
    if s:find('\n') or s:find('\r') then
      for _, part in ipairs(vim.split(s, '\r?\n', { plain = false })) do
        table.insert(out, part)
      end
    else
      table.insert(out, s)
    end
  end
  api.nvim_buf_set_option(self.buf, 'modifiable', true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, out)
  api.nvim_buf_set_option(self.buf, 'modifiable', false)
end

function ViewerState:update_title(name)
  if not self:is_open() then
    return
  end
  local ok = pcall(api.nvim_win_set_config, self.win, { title = ' Preview: ' .. (name or '') .. ' ' })
  if not ok then
    -- ignore configuration failures (e.g., on older Neovim)
  end
end

function ViewerState:current_offsets()
  local window = self._window or {}
  local row_offset = tonumber(window.row_offset) or 0
  local col_offset = tonumber(window.col_offset) or 0
  if row_offset < 0 then
    row_offset = 0
  end
  if col_offset < 0 then
    col_offset = 0
  end
  return row_offset, col_offset
end

function ViewerState:request_preview(row_offset, col_offset)
  if not self.name then
    return
  end
  local label = 'Loading preview for ' .. tostring(self.name) .. ' ...'
  if row_offset ~= 0 or col_offset ~= 0 then
    label = label .. string.format(' [rows %d cols %d]', row_offset, col_offset)
  end
  self:set_content({ label })
  require('ipybridge').request_preview(self.name, {
    row_offset = row_offset,
    col_offset = col_offset,
  })
end

function ViewerState:window_shape_dim(dim)
  local window = self._window or {}
  local shape = window.shape
  if type(shape) ~= 'table' then
    return nil
  end
  local value = shape[dim]
  if type(value) ~= 'number' then
    value = tonumber(value)
  end
  return value
end

function ViewerState:move_rows(direction)
  local window = self._window
  if not window then
    return
  end
  local kind = preview_kind(window)
  if kind ~= 'ndarray' and kind ~= 'dataframe' and kind ~= 'list' and kind ~= 'tuple' and kind ~= 'set' and kind ~= 'dict' then
    return
  end
  local default_rows = select(1, viewer_limits())
  local rows_step = tonumber(window.max_rows) or default_rows
  if rows_step <= 0 then
    rows_step = default_rows
  end
  local current_row, current_col = self:current_offsets()
  local total_rows = self:window_shape_dim(1)
  local new_row = clamp_offset(current_row, rows_step * direction, total_rows, rows_step)
  if new_row == current_row then
    return
  end
  self:request_preview(new_row, current_col)
end

function ViewerState:move_cols(direction)
  local window = self._window
  if not window then
    return
  end
  local kind = preview_kind(window)
  if kind ~= 'ndarray' and kind ~= 'dataframe' then
    return
  end
  local default_cols = select(2, viewer_limits())
  local viewer_cols = tonumber(window.max_cols) or default_cols
  if viewer_cols <= 0 then
    viewer_cols = default_cols
  end
  local current_row, current_col = self:current_offsets()
  local total_cols = self:window_shape_dim(2)
  if (not total_cols or total_cols <= 1) and current_col == 0 and direction ~= 0 then
    return
  end
  if total_cols and total_cols <= viewer_cols and current_col == 0 and direction > 0 then
    return
  end
  local new_col = clamp_offset(current_col, viewer_cols * direction, total_cols, viewer_cols)
  if new_col == current_col then
    return
  end
  self:request_preview(current_row, new_col)
end

function ViewerState:drilldown_current()
  if not self:is_open() then
    return
  end
  local lnum = api.nvim_win_get_cursor(self.win)[1]
  local path = self._line2path[lnum]
  if path and type(path) == 'string' and #path > 0 then
    self.name = path
    self._window = { row_offset = 0, col_offset = 0 }
    self:update_title(path)
    self:request_preview(0, 0)
  end
end

function ViewerState:ensure_window(name)
  if self:is_open() then
    return
  end
  self.buf = api.nvim_create_buf(false, true)
  local w, h = layout_size()
  local row = math.floor((vim.o.lines - h) / 4)
  local col = math.floor((vim.o.columns - w) / 2)
  self.win = api.nvim_open_win(self.buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    row = row,
    col = col,
    border = 'single',
    title = ' Preview: ' .. (name or '') .. ' ',
    style = 'minimal',
  })
  api.nvim_set_option_value('buftype', 'nofile', { buf = self.buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = self.buf })
  api.nvim_set_option_value('swapfile', false, { buf = self.buf })
  api.nvim_set_option_value('filetype', 'ipybridge-view', { buf = self.buf })
  api.nvim_buf_set_option(self.buf, 'modifiable', false)

  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = self.buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    self:close()
  end, 'Close')
  map('r', function()
    if not self.name then
      return
    end
    local row_off, col_off = self:current_offsets()
    self:request_preview(row_off, col_off)
  end, 'Refresh')
  map('<C-f>', function()
    self:move_rows(1)
  end, 'Next rows')
  map('<C-b>', function()
    self:move_rows(-1)
  end, 'Previous rows')
  map('<C-l>', function()
    self:move_cols(1)
  end, 'Next cols')
  map('<C-h>', function()
    self:move_cols(-1)
  end, 'Previous cols')
  map('<C-Right>', function()
    self:move_cols(1)
  end, 'Next cols')
  map('<C-Left>', function()
    self:move_cols(-1)
  end, 'Previous cols')
  map('<CR>', function()
    self:drilldown_current()
  end, 'Drill-down preview')
end

function ViewerState:prepare_window(name)
  local incoming = name or self.name
  local name_changed = incoming and incoming ~= self.name
  if incoming and incoming ~= '' then
    self.name = incoming
  end
  self:ensure_window(self.name)
  if name_changed or not self._window then
    self._window = { row_offset = 0, col_offset = 0 }
  end
  self:update_title(self.name)
end

function ViewerState:_apply_window_metadata(data)
  local default_rows, default_cols = viewer_limits()
  local window = self._window or {}
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
  window.sequence_kind = data.sequence_kind
  self._window = window
end

function ViewerState:open(name)
  self:prepare_window(name)
  self:request_preview(0, 0)
end

function ViewerState:on_preview(data)
  if data == vim.NIL then
    data = nil
  end
  local name = data and data.name or self.name
  local should_prepare = not self:is_open() or (name and name ~= self.name)
  if should_prepare then
    self:prepare_window(name)
    if not data then
      self:request_preview(0, 0)
    end
  end
  if data and data.error then
    self:set_content({ 'Error: ' .. tostring(data.error) })
    return
  end
  if not data or type(data) ~= 'table' then
    self:set_content({ 'Preview unavailable' })
    return
  end
  self:_apply_window_metadata(data)
  local lines, map = Renderers.render(data, { viewer_name = self.name })
  self._last = data
  self._line2path = map or {}
  self:set_content(lines)
end

function ViewerState:close()
  self:close_window()
end

local state = ViewerState:new()

local M = {}

setmetatable(M, {
  __index = function(_, key)
    local method = ViewerState[key]
    if type(method) == 'function' then
      return function(first, ...)
        if first == M or first == nil then
          return method(state, ...)
        end
        return method(state, first, ...)
      end
    end
    return state[key]
  end,
  __newindex = function(_, key, value)
    state[key] = value
  end,
})

return M
