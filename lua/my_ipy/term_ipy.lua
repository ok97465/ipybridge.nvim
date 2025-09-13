-- Neovim 0.11+ is required by the plugin entry.
-- This module assumes those APIs are available.
local vim = vim
local api = vim.api
local fn = vim.fn

local M = {}

-- Simple terminal wrapper for running IPython in a split.
local TermIpy = {job_id = nil, buf_id = nil, win_id = nil}
TermIpy.__index = TermIpy
local split_cmd = "botright vsplit"

-- Strip ANSI escape sequences from a string (CSI/OSC common forms).
local function strip_ansi(s)
  if type(s) ~= 'string' then return s end
  -- Remove CSI sequences: ESC [ ... cmd
  s = s:gsub("\27%[[%d;?]*[%@-~]", "")
  -- Remove OSC sequences: ESC ] ... BEL or ST
  s = s:gsub("\27%].-", "")
  s = s:gsub("\27%].-\27\\", "")
  return s
end

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

function TermIpy:new(cmd, cwd)
	local tb = setmetatable({}, TermIpy)
	tb._acc = ""
	tb:__spawn(cmd, cwd)
	return tb
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
  -- Accumulate chunks and extract sentinel-wrapped JSON messages.
  -- Other outputs are ignored by this parser and left in terminal buffer.
  -- Expected format: __MYIPY_JSON_START__{...}__MYIPY_JSON_END__
  for _, line in ipairs(data) do
    if line ~= nil and line ~= '' then
      self._acc = self._acc .. strip_ansi(line) .. "\n"
    end
  end
  local start_tok = "__MYIPY_JSON_START__"
  local end_tok = "__MYIPY_JSON_END__"
  while true do
    local s = self._acc:find(start_tok, 1, true)
    if not s then break end
    local e = self._acc:find(end_tok, s + #start_tok, true)
    if not e then break end
    local payload = self._acc:sub(s + #start_tok, e - 1)
    -- Trim potential newlines around payload
    payload = payload:gsub("^\n+", ""):gsub("\n+$", "")
    local ok, msg = pcall(vim.json.decode, payload)
    if ok and type(msg) == 'table' and msg.tag then
      pcall(function()
        require('my_ipy.dispatch').handle(msg)
      end)
    end
    -- Drop up to end token
    self._acc = self._acc:sub(e + #end_tok)
  end
  -- Prevent unbounded growth
  if #self._acc > 2 * 1024 * 1024 then
    self._acc = self._acc:sub(-1024 * 1024)
  end
end

M.TermIpy = TermIpy

return M
