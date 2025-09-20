-- Neovim 0.11+ is required by the plugin entry.
-- This module assumes those APIs are available.
local vim = vim
local api = vim.api
local fn = vim.fn

local M = {}

local function default_on_message(msg)
  local ok, dispatch = pcall(require, 'ipybridge.dispatch')
  if not ok or not dispatch then return end
  local handler = dispatch.handle
  if type(handler) ~= 'function' then return end
  pcall(handler, msg)
end

-- Simple terminal wrapper for running IPython in a split.
local TermIpy = {job_id = nil, buf_id = nil, win_id = nil}
TermIpy.__index = TermIpy
local split_cmd = "botright vsplit"

local OSC_PREFIX = "\27]5379;ipybridge:"
local OSC_PREFIX_LEN = #OSC_PREFIX
local OSC_SUFFIX = "\7"

local function __handle_exit(term)
	return function(...)
		if term:isshow() then
			api.nvim_win_close(term.win_id, true)
		end
		term:stopinsert()
		if api.nvim_buf_is_loaded(term.buf_id) then
			api.nvim_buf_delete(term.buf_id, {force=true})
		end
		term.buf_id = nil
		term.win_id = nil
		term.job_id = nil
	end
end

function TermIpy:new(cmd, cwd, opts)
  local tb = setmetatable({}, TermIpy)
  tb._osc_pending = ""
  if opts and type(opts.on_message) == 'function' then
    tb._on_message = opts.on_message
  else
    tb._on_message = default_on_message
  end
  tb:__spawn(cmd, cwd)
  return tb
end

function TermIpy:__handle_hidden_payload(payload)
  if type(payload) ~= 'string' or payload == '' then return end
  local sep = payload:find(':', 1, true)
  if not sep then return end
  local tag = payload:sub(1, sep - 1)
  local body = payload:sub(sep + 1)
  if not tag or tag == '' then return end
  if not body or #body == 0 then return end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then
    vim.schedule(function()
      vim.notify('ipybridge: failed to decode hidden payload for ' .. tag, vim.log.levels.WARN)
    end)
    return
  end
  local handler = self._on_message
  if type(handler) ~= 'function' then return end
  local message = { tag = tag, data = decoded }
  vim.schedule(function()
    pcall(handler, message)
  end)
end

local function longest_prefix_suffix(s)
  local max_keep = math.min(#s, OSC_PREFIX_LEN - 1)
  for len = max_keep, 1, -1 do
    if OSC_PREFIX:sub(1, len) == s:sub(-len) then
      return len
    end
  end
  return 0
end

function TermIpy:__extract_hidden(text)
  if type(text) ~= 'string' or text == '' then return text end
  local combined = (self._osc_pending or '') .. text
  local output = {}
  local idx = 1
  while true do
    local start = combined:find(OSC_PREFIX, idx, true)
    if not start then
      break
    end
    local before = combined:sub(idx, start - 1)
    local search_from = start + OSC_PREFIX_LEN
    local stop = combined:find(OSC_SUFFIX, search_from, true)
    if not stop then
      self._osc_pending = combined:sub(start)
      if before ~= '' then table.insert(output, before) end
      return table.concat(output, "")
    end
    if before ~= '' then
      table.insert(output, before)
    end
    local payload = combined:sub(search_from, stop - 1)
    self:__handle_hidden_payload(payload)
    idx = stop + 1
  end
  local remainder = combined:sub(idx)
  local keep = longest_prefix_suffix(remainder)
  if keep > 0 then
    self._osc_pending = remainder:sub(-keep)
    remainder = remainder:sub(1, #remainder - keep)
  else
    self._osc_pending = ''
  end
  if remainder ~= '' then
    table.insert(output, remainder)
  end
  return table.concat(output, "")
end

function TermIpy:send(cmd)
  -- Send raw text to terminal channel and move cursor to bottom.
  if not self.job_id then return end
  api.nvim_chan_send(self.job_id, cmd)
  if api.nvim_buf_is_loaded(self.buf_id) and api.nvim_win_is_valid(self.win_id) then
    local n_lines = api.nvim_buf_line_count(self.buf_id)
    pcall(api.nvim_win_set_cursor, self.win_id, { n_lines, 0 })
  end
end

function TermIpy:scroll_to_bottom()
  -- Scroll to bottom without leaving terminal-mode.
  if not (api.nvim_win_is_valid(self.win_id) and api.nvim_buf_is_loaded(self.buf_id)) then
    return
  end
  local n_lines = api.nvim_buf_line_count(self.buf_id)
  pcall(api.nvim_win_set_cursor, self.win_id, { n_lines, 0 })
end

function TermIpy:startinsert()
  vim.cmd("startinsert")
end

function TermIpy:stopinsert()
  vim.cmd("stopinsert!")
end

function TermIpy:isshow()
  return api.nvim_win_is_valid(self.win_id) and api.nvim_win_get_buf(self.win_id) == self.buf_id
end

function TermIpy:show()
  if not self:isshow() then
    vim.cmd(split_cmd)
    self.win_id = api.nvim_get_current_win()
    api.nvim_set_current_buf(self.buf_id)
  end
end

function TermIpy:__spawn(cmd, cwd)
  -- Create a split, attach a scratch buffer, and launch terminal job.
  vim.cmd(split_cmd)
  self.win_id = api.nvim_get_current_win()
  self.buf_id = api.nvim_create_buf(false, false)
  api.nvim_set_current_buf(self.buf_id)
  local this = self
  self.job_id = fn.termopen(cmd, {
    detach = false,
    cwd = cwd,
    on_exit = __handle_exit(self),
    on_stdout = function(job_id, data, event)
      -- Forward to instance parser. `data` is an array of lines.
      if not data then return end
      this:__on_stdout(data)
    end,
    on_stderr = function(job_id, data, event)
      if not data then return end
      this:__on_stdout(data)
    end,
  })
end

function TermIpy:__on_stdout(data)
  for _, line in ipairs(data) do
    if line ~= nil and line ~= '' then
      self:__extract_hidden(line)
    end
  end
end

M.TermIpy = TermIpy

return M
