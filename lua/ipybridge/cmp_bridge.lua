-- Provide a minimal completion source so ipdb TAB keeps the nvim-cmp menu alive.
local M = {}

local SOURCE_NAME = 'ipybridge_debug_hint'
local state = {
  patched = false,
  registered = false,
}

local function current_bridge()
  local bridge = package.loaded['ipybridge']
  if type(bridge) ~= 'table' then
    return nil
  end
  return rawget(bridge, 'term_instance')
end

local function is_ipybridge_terminal(bufnr)
  local term = current_bridge()
  return term and term.buf_id == bufnr or false
end

local function is_active_ipy_terminal()
  local ok_mode, info = pcall(vim.api.nvim_get_mode)
  local mode = ok_mode and tostring(info.mode or ''):sub(1, 1) or ''
  if mode ~= 't' then
    return false
  end
  local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
  if not ok_buf then
    return false
  end
  return is_ipybridge_terminal(buf)
end

local function patch_cmp_api()
  if state.patched then
    return true
  end
  local ok, cmp_api = pcall(require, 'cmp.utils.api')
  if not ok or type(cmp_api) ~= 'table' then
    return false
  end
  local original_get_mode = cmp_api.get_mode or function() return nil end
  local original_is_insert_mode = cmp_api.is_insert_mode or function() return false end
  local original_is_suitable_mode = cmp_api.is_suitable_mode or function() return false end
  cmp_api.get_mode = function()
    if is_active_ipy_terminal() then
      return 'i'
    end
    return original_get_mode()
  end
  cmp_api.is_insert_mode = function()
    if is_active_ipy_terminal() then
      return true
    end
    return original_is_insert_mode()
  end
  cmp_api.is_suitable_mode = function()
    if is_active_ipy_terminal() then
      return true
    end
    return original_is_suitable_mode()
  end
  state.patched = true
  return true
end

local HintSource = {}
HintSource.__index = HintSource

function HintSource.new()
  return setmetatable({}, HintSource)
end

function HintSource:get_debug_name()
  return 'ipybridge::debug_tab_hint'
end

function HintSource:is_available()
  local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
  if not ok_buf then
    return false
  end
  local buftype = vim.api.nvim_get_option_value('buftype', { buf = buf })
  if buftype ~= 'terminal' then
    return false
  end
  return is_ipybridge_terminal(buf)
end

function HintSource:complete(request, callback)
  local ctx = request.context or {}
  local prefix = ctx.cursor_before_line or ''
  local token = prefix:match('([%w_%.]+)$') or ''
  local label = token ~= '' and token or '[TAB]'
  callback({
    items = {
      {
        label = label,
        insertText = token,
        filterText = token,
        documentation = {
          kind = 'plaintext',
          value = 'TAB was redirected so nvim-cmp can render inside ipdb.',
        },
      },
    },
  })
end

local function ensure_source(cmp)
  if state.registered then
    return true
  end
  cmp.register_source(SOURCE_NAME, HintSource.new())
  state.registered = true
  return true
end

function M.ensure()
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end
  if not patch_cmp_api() then
    return false
  end
  ensure_source(cmp)
  return true
end

function M.trigger()
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end
  if not M.ensure() then
    return false
  end
  vim.schedule(function()
    cmp.complete({
      config = {
        sources = cmp.config.sources({
          { name = SOURCE_NAME },
        }),
      },
      reason = cmp.ContextReason.Manual,
    })
  end)
  return true
end

return M
