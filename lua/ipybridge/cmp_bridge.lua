-- Completion source that exposes ipdb-aware suggestions through nvim-cmp.
-- We use a very small state layer so TAB can populate completions inside the
-- terminal buffer that hosts ipdb.
local M = {}

local SOURCE_NAME = 'ipybridge_debug_hint'

---@class BridgeState
---@field patched boolean
---@field registered boolean
---@field last_context table|nil
local state = {
  patched = false,
  registered = false,
  last_context = nil,
}

local key_listener_attached = false
local mapped_buffers = {}
local autocmd_buffers = {}

-- Lookup helpers -------------------------------------------------------------

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

-- nvim-cmp integration -------------------------------------------------------

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

local function feed_terminal(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, 'tn', false)
end

local function close_menu()
  vim.schedule(function()
    local ok, cmp = pcall(require, 'cmp')
    if ok and cmp.visible() then
      cmp.close()
    end
    state.last_context = nil
  end)
end

local function ensure_key_listener()
  if key_listener_attached then
    return
  end
  local ns = vim.api.nvim_create_namespace('ipybridge_cmp_keys')
  vim.on_key(function(char)
    if not char or char == '' then
      return
    end
    -- Ignore navigation keys we explicitly handle in mappings.
    if char == '\x0e' or char == '\x10' or char == '\r' or char == '\27' then
      return
    end
    if char:match('%c') then
      return
    end
    vim.schedule(function()
      local ok, cmp = pcall(require, 'cmp')
      if ok and cmp.visible() then
        cmp.abort()
        state.last_context = nil
      end
    end)
  end, ns)
  key_listener_attached = true
end

-- Completion candidates ------------------------------------------------------

local cmp_kinds_cache = nil

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

local function strip_prompt(text)
  if type(text) ~= 'string' or text == '' then
    return ''
  end
  local templates = { '^ipdb>[%s]*', '^%([Pp]db%)%s*' }
  for _, pattern in ipairs(templates) do
    local stripped = text:gsub(pattern, '', 1)
    if stripped ~= text then
      return stripped
    end
  end
  return text
end

local ipdb_commands = {
  'help', 'h', 'list', 'l', 'longlist', 'll', 'where', 'w',
  'continue', 'cont', 'c', 'next', 'n', 'step', 's', 'return', 'ret',
  'until', 'unt', 'jump', 'j', 'up', 'u', 'down', 'd',
  'break', 'b', 'tbreak', 'clear', 'disable', 'enable', 'ignore',
  'commands', 'alias', 'unalias', 'args', 'a', 'bt', 'stack',
  'display', 'undisplay', 'whatis', 'source', 'p', 'pp',
  'run', 'restart', 'quit', 'q', 'debug',
}

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

local function build_context(request_context)
  local before = request_context.cursor_before_line or ''
  local stripped = strip_prompt(before)
  local token = stripped:match('([%w_%.]+)$') or ''
  local cursor = request_context.cursor or {}
  local row = tonumber(cursor.line) or 0
  local col = tonumber(cursor.col) or #before
  local start_col = col - #token
  if start_col < 0 then
    start_col = col
  end
  local raw_line = nil
  local term = current_bridge()
  if term and term.buf_id and vim.api.nvim_buf_is_loaded(term.buf_id) then
    local ok_line, line = pcall(vim.api.nvim_buf_get_lines, term.buf_id, row, row + 1, false)
    if ok_line and type(line) == 'table' and line[1] then
      raw_line = line[1]
    end
  end
  return {
    before = before,
    stripped = stripped,
    token = token,
    cursor_row = row,
    cursor_col = col,
    cursor_col_start = start_col,
    raw_line = raw_line,
  }
end

local function build_item(label, source_kind, detail, context)
  local col = context.cursor_col or #context.before
  local row = context.cursor_row or 0
  local token = context.token or ''
  local start_col = context.cursor_col_start or (col - #token)
  local target_line = context.raw_line or context.before
  return {
    label = label,
    insertText = label,
    filterText = label,
    kind = completion_kind(source_kind),
    detail = detail,
    dup = 0,
    textEdit = {
      range = {
        start = { line = row, character = start_col },
        ['end'] = { line = row, character = col },
      },
      newText = label,
    },
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
      items[#items + 1] = build_item(cmd, 'pdb', '[cmd]', context)
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
      items[#items + 1] = build_item(name, 'python', '[var]', context)
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

local function apply_completion()
  local ok, cmp = pcall(require, 'cmp')
  if not ok or not cmp.visible() then
    return false
  end
  local ctx = state.last_context or {}
  local token = ctx.token or ''
  if #token > 0 then
    feed_terminal(string.rep('<BS>', #token))
  end
  local entry = cmp.get_selected_entry()
  if not entry then
    local entries = cmp.get_entries()
    entry = entries and entries[1] or nil
  end
  if entry then
    local item = entry.completion_item or {}
    local text = (item.textEdit and item.textEdit.newText) or item.insertText or item.label or ''
    if text ~= '' then
      feed_terminal(text)
    end
  end
  cmp.close()
  state.last_context = nil
  return true
end

-- cmp source ----------------------------------------------------------------

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
  local context = build_context(request.context or {})
  local items = collect_items(context)
  state.last_context = context
  vim.schedule(function()
    if items and #items > 0 then
      callback({ items = items })
    else
      callback({ items = {}, isIncomplete = false })
      close_menu()
    end
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

-- Buffer integration ---------------------------------------------------------

local function setup_terminal_keymaps()
  local cmp = require('cmp')
  local buf = vim.api.nvim_get_current_buf()
  if mapped_buffers[buf] then
    return
  end
  local function cmp_or_nil()
    local ok, cmp_mod = pcall(require, 'cmp')
    if ok then
      return cmp_mod
    end
    return nil
  end
  vim.keymap.set('t', '<C-n>', function()
    local cmp_mod = cmp_or_nil()
    if cmp_mod and cmp_mod.visible() then
      vim.schedule(function()
        local ok_cmp, active = pcall(require, 'cmp')
        if ok_cmp and active.visible() then
          active.select_next_item({ behavior = active.SelectBehavior.Select })
        end
      end)
      return ''
    end
    return vim.api.nvim_replace_termcodes('<C-n>', true, false, true)
  end, { buffer = buf, noremap = true, silent = true, expr = true })
  vim.keymap.set('t', '<C-p>', function()
    local cmp_mod = cmp_or_nil()
    if cmp_mod and cmp_mod.visible() then
      vim.schedule(function()
        local ok_cmp, active = pcall(require, 'cmp')
        if ok_cmp and active.visible() then
          active.select_prev_item({ behavior = active.SelectBehavior.Select })
        end
      end)
      return ''
    end
    return vim.api.nvim_replace_termcodes('<C-p>', true, false, true)
  end, { buffer = buf, noremap = true, silent = true, expr = true })
  vim.keymap.set('t', '<CR>', function()
    local cmp_mod = cmp_or_nil()
    if cmp_mod and cmp_mod.visible() then
      apply_completion()
      return ''
    end
    return vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  end, { buffer = buf, noremap = true, silent = true, expr = true })
  vim.keymap.set('t', '<Esc>', function()
    local cmp_mod = cmp_or_nil()
    if cmp_mod and cmp_mod.visible() then
      vim.schedule(function()
        local ok_cmp, active = pcall(require, 'cmp')
        if ok_cmp and active.visible() then
          active.abort()
        end
        state.last_context = nil
      end)
      return ''
    end
    return vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  end, { buffer = buf, noremap = true, silent = true, expr = true })
  mapped_buffers[buf] = true
end

local function setup_buffer_autocmds()
  local buf = vim.api.nvim_get_current_buf()
  if autocmd_buffers[buf] then
    return
  end
  local group = vim.api.nvim_create_augroup('ipybridge_cmp_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'TermClose', 'TermLeave' }, {
    group = group,
    buffer = buf,
    callback = function()
      local ok, cmp = pcall(require, 'cmp')
      if ok and cmp.visible() then
        cmp.abort()
      end
      state.last_context = nil
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      mapped_buffers[buf] = nil
      autocmd_buffers[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  autocmd_buffers[buf] = group
end

-- Public API -----------------------------------------------------------------

function M.ensure()
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end
  if not patch_cmp_api() then
    return false
  end
  ensure_source(cmp)
  setup_terminal_keymaps()
  setup_buffer_autocmds()
  ensure_key_listener()
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
