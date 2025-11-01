-- Neovim 0.11+ is required by the plugin entry.
-- This module assumes those APIs are available.
local vim = vim
local api = vim.api
local fn = vim.fn

local M = {}

local OscParser = require("ipybridge.osc_parser")

local function default_on_message(msg)
	local ok, dispatch = pcall(require, "ipybridge.dispatch")
	if not ok or not dispatch then
		return
	end
	local handler = dispatch.handle
	if type(handler) ~= "function" then
		return
	end
	pcall(handler, msg)
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
	if opts and type(opts.on_message) == "function" then
		tb._on_message = opts.on_message
	else
		tb._on_message = default_on_message
	end
	if opts and type(opts.env) == "table" then
		tb._env = opts.env
	else
		tb._env = nil
	end
	if opts and type(opts.on_exit) == "function" then
		-- Allow callers to react when the terminal job terminates (e.g. user typed exit).
		tb._on_exit = opts.on_exit
	else
		tb._on_exit = nil
	end
	if opts and type(opts.on_stdout_chunk) == "function" then
		tb._on_stdout_chunk = opts.on_stdout_chunk
	else
		tb._on_stdout_chunk = noop
	end
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
	if type(handler) ~= "function" then
		return
	end
	local ok, err = pcall(handler, { tag = tag, data = payload })
	if not ok then
		vim.notify(
			"ipybridge: hidden message handler failed for " .. tostring(tag) .. ": " .. tostring(err),
			vim.log.levels.WARN
		)
	end
end

function TermIpy:__extract_hidden(text)
	local decoder = self._decoder
	if not decoder then
		return text
	end
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
	if type(self._on_stdout_chunk) ~= "function" then
		return
	end
	if type(text) ~= "string" or text == "" then
		return
	end
	local sanitized = text:gsub("\r", "")
	if sanitized == "" then
		return
	end
	pcall(self._on_stdout_chunk, sanitized)
end

function TermIpy:__on_stdout(data)
	for _, line in ipairs(data) do
		if line ~= nil and line ~= "" then
			local decoder = self._decoder
			local visible = decoder and decoder:ingest(line) or line
			if visible and visible ~= "" then
				self:__notify_stdout(visible)
			end
		end
	end
end

M.TermIpy = TermIpy

return M
