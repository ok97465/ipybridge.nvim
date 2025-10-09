-- Provide debugger-aware completion candidates for nvim-cmp inside ipdb.
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

local cmp_kinds_cache = nil

local function strip_prompt(prefix)
  if type(prefix) ~= 'string' or prefix == '' then
    return ''
  end
  local templates = { '^ipdb>[%s]*', '^%([Pp]db%)%s*' }
  for _, pattern in ipairs(templates) do
    local stripped = prefix:gsub(pattern, '', 1)
    if stripped ~= prefix then
      return stripped
    end
  end
  return prefix
end

local ipdb_commands = {
  'help', 'h', 'list', 'l', 'longlist', 'll', 'where', 'w',
  'continue', 'cont', 'c', 'next', 'n', 'step', 's', 'return', 'ret',
  'until', 'unt', 'jump', 'j', 'up', 'u', 'down', 'd',
  'break', 'b', 'tbreak', 'clear', 'disable', 'enable', 'ignore',
  'commands', 'alias', 'unalias', 'args', 'a', 'bt', 'stack',
  'display', 'undisplay', 'whatis', 'source', 'p', 'pp',
  'run', 'restart', 'quit', 'q', 'debug'
}

local function completion_kind(source)
  if not cmp_kinds_cache then
    local ok_types, types = pcall(require, 'cmp.types')
    if ok_types and types and types.lsp and types.lsp.CompletionItemKind then
      cmp_kinds_cache = types.lsp.CompletionItemKind
    else
      cmp_kinds_cache = {}
    end
  end
  local kinds = cmp_kinds_cache or {}
  local default = kinds.Text or 1
  if source == 'pdb' then
    return kinds.Keyword or default
  end
  if source == 'python' then
    return kinds.Variable or default
  end
  return default
end

local function collect_debug_names()
  local names = {}
  local ok_bridge, bridge = pcall(require, 'ipybridge')
  if not ok_bridge or type(bridge) ~= 'table' then
    return names
  end
  local function collect(scope)
    if type(scope) ~= 'table' then
      return
    end
    for key, _ in pairs(scope) do
      if type(key) == 'string' and key ~= '' and not key:match('^__') then
        names[key] = true
      end
    end
  end
  collect(bridge._latest_vars)
  local locals_snapshot = bridge._debug_locals_snapshot
  if type(locals_snapshot) == 'table' then
    collect(locals_snapshot.__locals__)
  end
  local globals_snapshot = bridge._debug_globals_snapshot
  if type(globals_snapshot) == 'table' then
    collect(globals_snapshot.__globals__)
  end
  return names
end

local function default_items(context)
  local token = context.token
  local label = token ~= '' and token or '[TAB]'
  return {
    {
      label = label,
      insertText = token,
      filterText = token,
      documentation = {
        kind = 'plaintext',
        value = 'TAB was redirected so nvim-cmp can render inside ipdb.',
      },
    },
  }
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

local function build_context(request_context)
  local before = request_context.cursor_before_line or ''
  local stripped = strip_prompt(before)
  if type(stripped) ~= 'string' then
    stripped = tostring(stripped or '')
  end
  local token = stripped:match('([%w_%.]+)$') or ''
  return {
    before = before,
    stripped = stripped,
    token = token,
  }
end

local function command_items(context)
  local stripped = context.stripped
  local token = context.token
  if stripped:sub(1, 1) == '!' then
    return {}
  end
  if token:find('%.', 1, true) and not token:match('^!') then
    return {}
  end
  local target = token
  if target:sub(1, 1) == '!' then
    target = target:sub(2)
  end
  local items = {}
  for _, cmd in ipairs(ipdb_commands) do
    if target == '' or cmd:sub(1, #target) == target then
      items[#items + 1] = {
        label = cmd,
        insertText = cmd,
        filterText = cmd,
        kind = completion_kind('pdb'),
        detail = '[cmd]',
        dup = 0,
      }
    end
  end
  return items
end

local function variable_items(context)
  local token = context.token
  local names = collect_debug_names()
  if vim.tbl_isempty(names) then
    return {}
  end
  local items = {}
  for name, _ in pairs(names) do
    if token == '' or name:sub(1, #token) == token then
      items[#items + 1] = {
        label = name,
        insertText = name,
        filterText = name,
        kind = completion_kind('python'),
        detail = '[var]',
        dup = 0,
      }
    end
  end
  table.sort(items, function(a, b)
    return (a and a.label or '') < (b and b.label or '')
  end)
  return items
end

local completion_providers = {
  command_items,
  variable_items,
}

local function collect_items(context)
  local aggregate = {}
  local seen = {}
  for _, provider in ipairs(completion_providers) do
    local ok, list = pcall(provider, context)
    if ok and type(list) == 'table' then
      for _, item in ipairs(list) do
        local label = item and item.label
        if label and not seen[label] then
          seen[label] = true
          aggregate[#aggregate + 1] = item
        end
      end
    end
  end
  return aggregate
end

function HintSource:complete(request, callback)
  local ctx = request.context or {}
  local context = build_context(ctx)
  local items = collect_items(context)
  if not items or #items == 0 then
    items = default_items(context)
  end
  vim.schedule(function()
    callback({ items = items })
  end)
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
