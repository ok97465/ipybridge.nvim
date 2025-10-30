-- Breakpoint management for ipybridge.nvim
-- Encapsulates storage, sign rendering, and kernel synchronization.

local vim = vim
local api = vim.api
local fn = vim.fn
local uv = vim.uv

local utils = require('ipybridge.utils')

local BP_SIGN_GROUP = 'IpybridgeBreakpoints'
local BP_SIGN_NAME = 'IpybridgeBreakpoint'
local BP_CONDITIONAL_SIGN_NAME = 'IpybridgeConditionalBreakpoint'

local Breakpoints = {}

local state = {
  map = {},
  signs = {},
  seq = 0,
  support_ready = false,
  file_path = nil,
  signature = nil,
  needs_sync = false,
  registered = false,
  exec = nil,
  is_term_open = nil,
  condition_input = nil,
}

local function warn_user(message)
  if not message then
    return
  end
  vim.schedule(function()
    vim.notify(tostring(message), vim.log.levels.WARN)
  end)
end

local function trim_condition(text)
  if type(text) ~= 'string' then
    return ''
  end
  return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function sanitize_entry(meta)
  if type(meta) ~= 'table' then
    return {}
  end
  return meta
end

local function entry_condition(meta)
  if type(meta) ~= 'table' then
    return nil
  end
  local cond = meta.condition
  if type(cond) ~= 'string' then
    return nil
  end
  local trimmed = trim_condition(cond)
  if trimmed == '' then
    return nil
  end
  return trimmed
end

local function ensure_line_entry(norm, line)
  state.map[norm] = state.map[norm] or {}
  local meta = state.map[norm][line]
  if type(meta) ~= 'table' then
    meta = sanitize_entry(meta)
  end
  state.map[norm][line] = meta
  return meta
end

local function clear_line_entry(norm, line)
  local entry = state.map[norm]
  if not entry then
    return
  end
  entry[line] = nil
  if next(entry) == nil then
    state.map[norm] = nil
  end
end

local function set_line_condition(norm, line, condition)
  local meta = ensure_line_entry(norm, line)
  local trimmed = trim_condition(condition or '')
  if trimmed ~= '' then
    meta.condition = trimmed
  else
    meta.condition = nil
  end
  return meta
end

local function default_condition_input(opts, cb)
  opts = type(opts) == 'table' and opts or {}
  local prompt = opts.prompt or 'Breakpoint condition'
  local default = opts.default or ''
  if type(default) ~= 'string' then
    default = tostring(default or '')
  end
  local columns = tonumber(vim.o and vim.o.columns) or 120
  local lines = tonumber(vim.o and vim.o.lines) or 40
  local width = math.floor(columns * 0.6)
  if width < 30 then
    width = 30
  end
  local min_prompt = #prompt + 6
  if width < min_prompt then
    width = min_prompt
  end
  if width > columns - 4 then
    width = math.max(columns - 4, min_prompt)
  end
  local row = math.floor((lines - 1) / 2)
  local col = math.floor((columns - width) / 2)
  local ok_buf, bufnr = pcall(api.nvim_create_buf, false, true)
  if not ok_buf or not bufnr or bufnr == 0 then
    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = prompt, default = default }, cb)
    elseif cb then
      cb(nil)
    end
    return
  end
  pcall(api.nvim_buf_set_option, bufnr, 'buftype', 'prompt')
  pcall(api.nvim_buf_set_option, bufnr, 'bufhidden', 'wipe')
  pcall(api.nvim_buf_set_option, bufnr, 'filetype', 'ipybridgeBreakpointCondition')
  local ok_win, win = pcall(api.nvim_open_win, bufnr, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'rounded',
    width = width,
    height = 1,
    row = row,
    col = col,
    noautocmd = true,
  })
  if not ok_win or not win or win == 0 then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
    if cb then
      cb(nil)
    end
    return
  end
  pcall(vim.fn.prompt_setprompt, bufnr, prompt .. ': ')
  if default ~= '' then
    pcall(fn.prompt_settext, bufnr, default)
  end
  local closed = false
  local function finalize(value, cancelled)
    if closed then
      return
    end
    closed = true
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if cancelled then
      if cb then
        cb(nil)
      end
      return
    end
    if cb then
      cb(value)
    end
  end
  pcall(vim.fn.prompt_setcallback, bufnr, function(text)
    finalize(text or '', false)
  end)
  pcall(vim.fn.prompt_setinterrupt, bufnr, function()
    finalize(nil, true)
  end)
  if vim.keymap and vim.keymap.set then
    vim.keymap.set('n', '<Esc>', function()
      finalize(nil, true)
    end, { buffer = bufnr, nowait = true, noremap = true, silent = true })
    vim.keymap.set('i', '<Esc>', function()
      finalize(nil, true)
    end, { buffer = bufnr, nowait = true, noremap = true, silent = true })
    vim.keymap.set('n', 'q', function()
      finalize(nil, true)
    end, { buffer = bufnr, nowait = true, noremap = true, silent = true })
  end
  pcall(vim.cmd, 'startinsert')
  vim.schedule(function()
    if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(bufnr) then
      return
    end
    local function cursor_to(line_text)
      if type(line_text) ~= 'string' then
        line_text = ''
      end
      pcall(api.nvim_win_set_cursor, win, { 1, math.max(0, #line_text) })
    end
    if default ~= '' then
      local feed_keys = '<C-u>' .. default
      if api and api.nvim_replace_termcodes then
        local ok_term, converted = pcall(api.nvim_replace_termcodes, feed_keys, true, false, true)
        if ok_term and type(converted) == 'string' and converted ~= '' then
          feed_keys = converted
        end
      end
      if api and api.nvim_feedkeys then
        api.nvim_feedkeys(feed_keys, 'in', false)
      else
        pcall(fn.prompt_settext, bufnr, default)
        pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, { default })
      end
      local function finalize_seed()
        if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(bufnr) then
          return
        end
        local ok_after, after_lines = pcall(api.nvim_buf_get_lines, bufnr, 0, 1, false)
        local line_text = (ok_after and type(after_lines) == 'table' and after_lines[1]) or default
        cursor_to(line_text)
      end
      if vim and vim.defer_fn then
        vim.defer_fn(finalize_seed, 10)
      else
        vim.schedule(finalize_seed)
      end
      return
    end
    local ok_lines, buf_lines = pcall(api.nvim_buf_get_lines, bufnr, 0, 1, false)
    local line_text = (ok_lines and type(buf_lines) == 'table' and buf_lines[1]) or ''
    cursor_to(line_text)
  end)
end

local function normalize_path(path)
  if not path or path == '' then
    return nil
  end
  local abs = fn.fnamemodify(path, ':p')
  if not abs or abs == '' then
    return nil
  end
  return abs:gsub('\\', '/')
end

local function collect_payload()
  local payload = {}
  for file_path, line_map in pairs(state.map) do
    local entries = {}
    for line, meta in pairs(line_map) do
      if type(line) == 'number' and line > 0 then
        local cond = entry_condition(meta)
        local item = { line = line }
        if cond then
          item.condition = cond
        end
        table.insert(entries, item)
      end
    end
    if #entries > 0 then
      table.sort(entries, function(a, b)
        if a.line ~= b.line then
          return a.line < b.line
        end
        local ac = a.condition or ''
        local bc = b.condition or ''
        return ac < bc
      end)
      payload[file_path] = entries
    end
  end
  return payload
end

local function ensure_breakpoint_support()
  if state.support_ready then
    return
  end
  pcall(vim.fn.sign_define, BP_SIGN_NAME, {
    text = 'B',
    texthl = 'DiagnosticSignError',
    linehl = '',
    numhl = '',
  })
  pcall(vim.fn.sign_define, BP_CONDITIONAL_SIGN_NAME, {
    text = '?',
    texthl = 'DiagnosticSignWarn',
    linehl = '',
    numhl = '',
  })
  local group = api.nvim_create_augroup('IpybridgeBreakpoints', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    group = group,
    callback = function(args)
      Breakpoints.refresh_signs(args.buf)
    end,
  })
  api.nvim_create_autocmd('BufUnload', {
    group = group,
    callback = function(args)
      state.signs[args.buf] = nil
    end,
  })
  state.support_ready = true
end

function Breakpoints.ensure_support()
  ensure_breakpoint_support()
end

local function refresh_signs_for(bufnr)
  if not bufnr or not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local bt = vim.bo[bufnr]
  if bt and bt.buftype and bt.buftype ~= '' then
    vim.fn.sign_unplace(BP_SIGN_GROUP, { buffer = bufnr })
    state.signs[bufnr] = nil
    return
  end
  local ft = (bt and bt.filetype) or ''
  if ft ~= 'python' then
    vim.fn.sign_unplace(BP_SIGN_GROUP, { buffer = bufnr })
    state.signs[bufnr] = nil
    return
  end
  local name = api.nvim_buf_get_name(bufnr)
  local norm = normalize_path(name)
  if not norm then
    vim.fn.sign_unplace(BP_SIGN_GROUP, { buffer = bufnr })
    state.signs[bufnr] = nil
    return
  end
  local entry = state.map[norm]
  vim.fn.sign_unplace(BP_SIGN_GROUP, { buffer = bufnr })
  state.signs[bufnr] = {}
  if not entry then
    return
  end
  local items = {}
  for line, meta in pairs(entry) do
    if type(line) == 'number' and line > 0 then
      table.insert(items, { line = line, meta = meta })
    end
  end
  table.sort(items, function(a, b)
    return a.line < b.line
  end)
  for _, item in ipairs(items) do
    state.seq = state.seq + 1
    local id = state.seq
    local sign_name = entry_condition(item.meta) and BP_CONDITIONAL_SIGN_NAME or BP_SIGN_NAME
    vim.fn.sign_place(id, BP_SIGN_GROUP, sign_name, bufnr, {
      lnum = item.line,
      priority = 80,
    })
    state.signs[bufnr][item.line] = { id = id, sign = sign_name }
  end
end

local function ensure_file()
  local existing = state.file_path
  if type(existing) == 'string' and #existing > 0 then
    local st = uv.fs_stat(existing)
    if st and st.type == 'file' then
      return existing
    end
  end
  local path = fn.tempname() .. '.ipybridge_breakpoints.json'
  state.file_path = path
  state.signature = nil
  state.needs_sync = true
  state.registered = false
  local ok = pcall(fn.writefile, { '{}' }, path, 'b')
  if ok then
    state.signature = '{}'
  end
  return path
end

function Breakpoints.refresh_signs(bufnr)
  ensure_breakpoint_support()
  refresh_signs_for(bufnr)
end

function Breakpoints.refresh_all_signs()
  ensure_breakpoint_support()
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) then
      refresh_signs_for(bufnr)
    end
  end
end

function Breakpoints.get_file_path()
  return ensure_file()
end

function Breakpoints.attach_session(opts)
  state.exec = opts and opts.exec or nil
  state.is_term_open = opts and opts.is_term_open or nil
  state.registered = false
  state.needs_sync = true
  Breakpoints.sync_with_kernel()
end

function Breakpoints.detach_session()
  state.exec = nil
  state.is_term_open = nil
  state.registered = false
  state.needs_sync = false
end

function Breakpoints.sync_with_kernel()
  if not state.needs_sync then
    return
  end
  if not state.exec then
    return
  end
  if state.is_term_open and not state.is_term_open() then
    return
  end
  local path = ensure_file()
  if not path or path == '' then
    return
  end
  local safe = utils.py_quote_single(path)
  local payload = string.format("_myipy_register_breakpoints_file('%s')\n", safe)
  local function schedule_retry()
    if not state.needs_sync then
      return
    end
    vim.defer_fn(function()
      if state.needs_sync then
        Breakpoints.sync_with_kernel()
      end
    end, 200)
  end
  state.exec(payload, {
    on_success = function()
      state.registered = true
      state.needs_sync = false
    end,
    on_error = function(reason)
      state.registered = false
      state.needs_sync = true
      local r = tostring(reason or '')
      if r == 'helpers_failed' or r == 'conn_file_unavailable' or r == 'zmq_unavailable' then
        schedule_retry()
        return
      end
      warn_user('ipybridge: failed to register breakpoint file via ZMQ (' .. (r ~= '' and r or 'unknown') .. ')')
    end,
  })
end

function Breakpoints.push()
  ensure_breakpoint_support()
  local payload = collect_payload()
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok or type(encoded) ~= 'string' then
    return
  end
  if encoded == '' then
    encoded = '{}'
  end
  local path = ensure_file()
  if not path or path == '' then
    return
  end
  if state.signature == encoded then
    return
  end
  local wrote = pcall(fn.writefile, { encoded }, path, 'b')
  if wrote then
    state.signature = encoded
    if not state.registered then
      state.needs_sync = true
      Breakpoints.sync_with_kernel()
    end
  end
end

function Breakpoints.toggle_current_line()
  ensure_breakpoint_support()
  local bufnr = api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local bt = vim.bo[bufnr]
  if bt and bt.filetype ~= 'python' then
    return
  end
  local norm = normalize_path(api.nvim_buf_get_name(bufnr))
  if not norm then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local entry = state.map[norm] and state.map[norm][line]
  if entry ~= nil then
    clear_line_entry(norm, line)
  else
    ensure_line_entry(norm, line)
  end
  refresh_signs_for(bufnr)
  Breakpoints.push()
end

function Breakpoints.set_conditional_current_line()
  ensure_breakpoint_support()
  local bufnr = api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local bt = vim.bo[bufnr]
  if bt and bt.filetype ~= 'python' then
    return
  end
  local norm = normalize_path(api.nvim_buf_get_name(bufnr))
  if not norm then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local current_meta = state.map[norm] and state.map[norm][line] or nil
  local default_cond = entry_condition(current_meta) or ''
  local provider = state.condition_input or default_condition_input
  provider({
    prompt = 'Breakpoint condition',
    default = default_cond,
  }, function(value)
    if value == nil then
      return
    end
    vim.schedule(function()
      local trimmed = trim_condition(value or '')
      local prior_meta = state.map[norm] and state.map[norm][line] or nil
      local prior_cond = entry_condition(prior_meta)
      if trimmed == '' then
        if prior_meta ~= nil then
          clear_line_entry(norm, line)
          refresh_signs_for(bufnr)
          Breakpoints.push()
        end
        return
      end
      if prior_meta == nil or prior_cond ~= trimmed then
        set_line_condition(norm, line, trimmed)
        refresh_signs_for(bufnr)
        Breakpoints.push()
      end
    end)
  end)
end

function Breakpoints._set_condition_input(provider)
  if type(provider) == 'function' then
    state.condition_input = provider
  else
    state.condition_input = nil
  end
end

function Breakpoints.clear_for_file(path)
  local norm = normalize_path(path)
  if not norm then
    return
  end
  state.map[norm] = nil
  Breakpoints.push()
end

function Breakpoints.collect()
  return collect_payload()
end

function Breakpoints.on_session_close()
  if state.file_path then
    pcall(os.remove, state.file_path)
  end
  state.file_path = nil
  state.signature = nil
  state.needs_sync = false
  state.registered = false
  Breakpoints.detach_session()
end

return Breakpoints
