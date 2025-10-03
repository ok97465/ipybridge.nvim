-- Breakpoint management for ipybridge.nvim
-- Encapsulates storage, sign rendering, and kernel synchronization.

local vim = vim
local api = vim.api
local fn = vim.fn
local uv = vim.uv

local utils = require('ipybridge.utils')

local BP_SIGN_GROUP = 'IpybridgeBreakpoints'
local BP_SIGN_NAME = 'IpybridgeBreakpoint'

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
  term_send = nil,
  exec = nil,
  is_term_open = nil,
}

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
  for file_path, line_set in pairs(state.map) do
    local lines = {}
    for line in pairs(line_set) do
      table.insert(lines, line)
    end
    if #lines > 0 then
      table.sort(lines)
      payload[file_path] = lines
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
  local lines = {}
  for line in pairs(entry) do
    table.insert(lines, line)
  end
  table.sort(lines)
  for _, line in ipairs(lines) do
    state.seq = state.seq + 1
    local id = state.seq
    vim.fn.sign_place(id, BP_SIGN_GROUP, BP_SIGN_NAME, bufnr, {
      lnum = line,
      priority = 80,
    })
    state.signs[bufnr][line] = id
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
  state.term_send = opts and opts.send or nil
  state.exec = opts and opts.exec or nil
  state.is_term_open = opts and opts.is_term_open or nil
  state.registered = false
  state.needs_sync = true
  Breakpoints.sync_with_kernel()
end

function Breakpoints.detach_session()
  state.term_send = nil
  state.exec = nil
  state.is_term_open = nil
  state.registered = false
  state.needs_sync = false
end

function Breakpoints.sync_with_kernel()
  if not state.needs_sync then
    return
  end
  if not state.term_send and not state.exec then
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
  local function fallback_send()
    if state.term_send then
      state.term_send(payload)
    end
  end
  if state.exec then
    state.exec(payload, { fallback = fallback_send })
  else
    fallback_send()
  end
  state.needs_sync = false
  state.registered = true
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
  state.map[norm] = state.map[norm] or {}
  if state.map[norm][line] then
    state.map[norm][line] = nil
    if next(state.map[norm]) == nil then
      state.map[norm] = nil
    end
  else
    state.map[norm][line] = true
  end
  refresh_signs_for(bufnr)
  Breakpoints.push()
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
