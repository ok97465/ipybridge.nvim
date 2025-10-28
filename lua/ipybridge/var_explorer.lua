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

local function sequence_items(entry)
  local items = entry.sequence_items
  if type(items) ~= 'table' then
    items = entry.list_items
  end
  if type(items) ~= 'table' then
    return {}
  end
  return items
end

local function mapping_items(entry)
  local items = entry.mapping_items
  if type(items) ~= 'table' then
    return {}
  end
  return items
end

local function is_previewable(entry)
  local kind = tostring(entry.kind or '')
  if kind == 'list' or kind == 'tuple' or kind == 'set' or kind == 'dict' then
    return true
  end
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
  local mapping = self._line2name[lnum]
  if not mapping then
    return
  end
  local path
  local root
  local previewable
  if type(mapping) == 'table' then
    path = mapping.path or mapping.name
    root = mapping.name or mapping.root or path
    previewable = mapping.previewable
  else
    path = mapping
    root = mapping
  end
  if not path or path == '' then
    return
  end
  local entry = root and self.vars[root] or nil
  if previewable == nil and entry then
    if path == root then
      previewable = is_previewable(entry)
    else
      local kind = tostring(entry.kind or '')
      if (kind == 'list' or kind == 'tuple') and entry.sequence_index_paths ~= false then
        for _, item in ipairs(sequence_items(entry)) do
          if not item.placeholder and item.path_index ~= nil then
            local idx = item.path_index
            local idx_str
            if type(idx) == 'number' then
              idx_str = string.format('%d', idx)
            elseif idx ~= nil then
              idx_str = tostring(idx)
            end
            if idx_str then
              local expected = string.format('%s[%s]', root, idx_str)
              if expected == path then
                if item.previewable ~= nil then
                  previewable = item.previewable == true
                else
                  previewable = true
                end
                break
              end
            end
          end
        end
      elseif kind == 'dict' and entry.mapping_allow_paths ~= false then
        for _, item in ipairs(mapping_items(entry)) do
          if not item.placeholder and type(item.path_accessor) == 'string' then
            local accessor = item.path_accessor
            local expected = root .. accessor
            if expected == path then
              if item.previewable ~= nil then
                previewable = item.previewable == true
              else
                previewable = true
              end
              break
            end
          end
        end
      end
    end
  end
  if previewable == nil then
    if path == root then
      previewable = entry and is_previewable(entry) or false
    else
      previewable = false
    end
  end
  if not previewable then
    return
  end
  require('ipybridge.data_viewer').open(path)
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
