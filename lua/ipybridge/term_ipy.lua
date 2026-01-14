-- Thin wrapper around a dedicated terminal buffer used to host IPython.
-- Handles OSC parsing, split/window/bookkeeping, and message dispatch to the
-- rest of the plugin.
-- Neovim 0.11+ is required by the plugin entry.
-- This module assumes those APIs are available.
local vim = vim
local api = vim.api
local fn = vim.fn

local M = {}

local OscParser = require("ipybridge.osc_parser")
local dispatch = require("ipybridge.core.dispatch")

local function default_on_message(msg)
	dispatch.handle(msg)
end

local function noop() end

-- Simple terminal wrapper for running IPython in a split.
local TermIpy = { job_id = nil, buf_id = nil, win_id = nil }
TermIpy.__index = TermIpy
local split_cmd = "botright vsplit"

local function __handle_exit(term)
	return function(job_id, code, event)
		if term:isshow() then
			api.nvim_win_close(term.win_id, true)
		end
		term:stopinsert()
		if term.buf_id and api.nvim_buf_is_loaded(term.buf_id) then
			api.nvim_buf_delete(term.buf_id, { force = true })
		end
		term.buf_id = nil
		term.win_id = nil
		term.job_id = nil
		local cb = term._on_exit
		if type(cb) == "function" then
			-- Defer to main loop so plugin cleanup runs outside termopen callback.
			vim.schedule(function()
				pcall(cb, job_id, code, event)
			end)
		end
	end
end

function TermIpy:new(cmd, cwd, opts)
	local tb = setmetatable({}, TermIpy)
	opts = opts or {}
	tb._on_message = opts.on_message or default_on_message
	tb._env = opts.env
	-- Allow callers to react when the terminal job terminates (e.g. user typed exit).
	tb._on_exit = opts.on_exit
	tb._on_stdout_chunk = opts.on_stdout_chunk or noop
	tb._osc_pending = ""
	tb._decoder = OscParser:new({
		on_message = function(tag, payload)
			tb:_handle_hidden_message(tag, payload)
		end,
	})
	tb:__spawn(cmd, cwd)
	return tb
end

function TermIpy:_handle_hidden_message(tag, payload)
	local handler = self._on_message or default_on_message
	handler({ tag = tag, data = payload })
end

function TermIpy:__extract_hidden(text)
	local decoder = self._decoder
	local visible = decoder:ingest(text)
	self._osc_pending = decoder:pending()
	return visible
end

function TermIpy:send(cmd)
	-- Send raw text to terminal channel and move cursor to bottom.
	if not self.job_id then
		return
	end
	api.nvim_chan_send(self.job_id, cmd)
	if api.nvim_buf_is_loaded(self.buf_id) and api.nvim_win_is_valid(self.win_id) then
		local n_lines = api.nvim_buf_line_count(self.buf_id)
		api.nvim_win_set_cursor(self.win_id, { n_lines, 0 })
	end
end

function TermIpy:scroll_to_bottom()
	-- Scroll to bottom without leaving terminal-mode.
	if not (api.nvim_win_is_valid(self.win_id) and api.nvim_buf_is_loaded(self.buf_id)) then
		return
	end
	local n_lines = api.nvim_buf_line_count(self.buf_id)
	api.nvim_win_set_cursor(self.win_id, { n_lines, 0 })
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
		env = self._env,
		on_exit = __handle_exit(self),
		on_stdout = function(job_id, data, event)
			-- Forward to instance parser. `data` is an array of lines.
			if not data then
				return
			end
			this:__on_stdout(data)
		end,
		on_stderr = function(job_id, data, event)
			if not data then
				return
			end
			this:__on_stdout(data)
		end,
	})
end

function TermIpy:__notify_stdout(text)
	local sanitized = text:gsub("\r", "")
	if sanitized ~= "" then
		self._on_stdout_chunk(sanitized)
	end
end

function TermIpy:__on_stdout(data)
	local decoder = self._decoder
	for _, line in ipairs(data) do
		local visible = decoder:ingest(line)
		if visible ~= "" then
			self:__notify_stdout(visible)
		end
	end
end

M.TermIpy = TermIpy

return M
