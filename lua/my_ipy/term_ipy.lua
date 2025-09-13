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
  self.job_id = fn.termopen(cmd, {
    detach = false,
    cwd = cwd,
    on_exit = __handle_exit(self),
    -- on_stdout = self.on_stdout,
    -- on_stderr = self.on_stderr,
  })
end

M.TermIpy = TermIpy

return M
