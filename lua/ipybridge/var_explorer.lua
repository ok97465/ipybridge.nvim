-- Variable explorer UI for ipybridge.nvim.
-- Manages floating window lifecycle while delegating row formatting.

local api = vim.api
local Renderer = require('ipybridge.viewer.var_renderer')

local ExplorerState = {}
ExplorerState.__index = ExplorerState

function ExplorerState:new()
  return setmetatable({
    buf = nil,
    win = nil,
    vars = {},
    _line2name = {},
  }, self)
end

function ExplorerState:is_open()
  return self.win and api.nvim_win_is_valid(self.win) and self.buf and api.nvim_buf_is_loaded(self.buf)
end

function ExplorerState:close_window()
  if self:is_open() then
    pcall(api.nvim_win_close, self.win, true)
  end
  if self.buf and api.nvim_buf_is_loaded(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf, self.win = nil, nil
  self._line2name = {}
end

local function layout_size()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.max(60, math.floor(cols * 0.5))
  local h = math.max(12, math.floor(lines * 0.5))
  return w, h
end

function ExplorerState:set_content(lines, map)
  if not self:is_open() then
    return
  end
  api.nvim_buf_set_option(self.buf, 'modifiable', true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  api.nvim_buf_set_option(self.buf, 'modifiable', false)
  self._line2name = map or {}
end

function ExplorerState:ensure_window()
  if self:is_open() then
    return
  end
  self.buf = api.nvim_create_buf(false, true)
  local w, h = layout_size()
  local row = math.floor((vim.o.lines - h) / 3)
  local col = math.floor((vim.o.columns - w) / 2)
  self.win = api.nvim_open_win(self.buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    row = row,
    col = col,
    border = 'single',
    title = ' Variables ',
    style = 'minimal',
  })
  api.nvim_set_option_value('buftype', 'nofile', { buf = self.buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = self.buf })
  api.nvim_set_option_value('swapfile', false, { buf = self.buf })
  api.nvim_set_option_value('filetype', 'ipybridge-vars', { buf = self.buf })
  api.nvim_buf_set_option(self.buf, 'modifiable', false)

  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = self.buf, silent = true, nowait = true, desc = desc })
  end

  map('q', function()
    self:close()
  end, 'Close')
  map('r', function()
    require('ipybridge').var_explorer_refresh()
  end, 'Refresh')
  map('<CR>', function()
    self:drilldown_current()
  end, 'Open viewer')
end

function ExplorerState:render()
  if not self:is_open() then
    return
  end
  local lines, map = Renderer.render(self.vars or {})
  self:set_content(lines, map)
end

local function is_previewable(entry)
  local kind = tostring(entry.kind or '')
  if kind == 'ndarray' or kind == 'dataframe' or kind == 'dataclass' or kind == 'ctypes' or kind == 'ctypes_array' then
    return true
  end
  local repr = tostring(entry.repr or '')
  return #repr >= 3 and repr:sub(-3) == '...'
end

function ExplorerState:drilldown_current()
  if not self:is_open() then
    return
  end
  local lnum = api.nvim_win_get_cursor(self.win)[1]
  local name = self._line2name[lnum]
  if not name then
    return
  end
  local entry = self.vars[name]
  if not entry or not is_previewable(entry) then
    return
  end
  require('ipybridge.data_viewer').open(name)
end

function ExplorerState:open()
  self:ensure_window()
  self:render()
end

function ExplorerState:refresh()
  require('ipybridge').var_explorer_refresh()
end

function ExplorerState:on_vars(tbl)
  self.vars = tbl or {}
  self:render()
end

function ExplorerState:close()
  self:close_window()
end

local state = ExplorerState:new()

local M = {}

setmetatable(M, {
  __index = function(_, key)
    local method = ExplorerState[key]
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
