-- Manages the sign shown for the current debug line inside tracked buffers.
-- Encapsulates sign definition, placement, and temporary signcolumn tweaks.
local vim = vim
local api = vim.api
local fn = vim.fn

local SIGN_GROUP = "IpybridgeDebugLine"
local SIGN_NAME = "IpybridgeDebugArrow"
local SIGN_ID = 90210
local DEBUG_SIGNCOLUMN = "yes:3"

local state = {
	defined = false,
	bufnr = nil,
	lnum = nil,
	win = nil,
	prev_signcolumn = nil,
}

local function ensure_defined()
	if state.defined then
		return
	end
	state.defined = true
	pcall(api.nvim_set_hl, 0, "IpybridgeDebugArrow", { default = true, link = "DiagnosticHint" })
	pcall(fn.sign_define, SIGN_NAME, { text = "=>", texthl = "IpybridgeDebugArrow", numhl = "" })
end

local function ensure_signcolumn(win)
	if type(win) ~= "number" or not api.nvim_win_is_valid(win) then
		return
	end
	local current = vim.api.nvim_get_option_value("signcolumn", { scope = "local", win = win })
	if state.win ~= win then
		if state.win and api.nvim_win_is_valid(state.win) and state.prev_signcolumn ~= nil then
			pcall(vim.api.nvim_set_option_value, "signcolumn", state.prev_signcolumn, { scope = "local", win = state.win })
		end
		state.win = win
		state.prev_signcolumn = current
	elseif state.prev_signcolumn == nil then
		state.prev_signcolumn = current
	end
	if current ~= DEBUG_SIGNCOLUMN then
		pcall(vim.api.nvim_set_option_value, "signcolumn", DEBUG_SIGNCOLUMN, { scope = "local", win = win })
	end
end

local M = {}

function M.place(bufnr, lnum, win)
	if type(bufnr) ~= "number" or type(lnum) ~= "number" then
		return
	end
	ensure_defined()
	ensure_signcolumn(win)
	pcall(fn.sign_unplace, SIGN_GROUP)
	local ok = pcall(fn.sign_place, SIGN_ID, SIGN_GROUP, SIGN_NAME, bufnr, {
		lnum = lnum,
		priority = 100,
	})
	if ok then
		state.bufnr = bufnr
		state.lnum = lnum
	else
		state.bufnr = nil
		state.lnum = nil
	end
end

function M.clear(opts)
	opts = type(opts) == "table" and opts or {}
	local restore = opts.restore_signcolumn
	if restore == nil then
		restore = true
	end
	state.bufnr = nil
	state.lnum = nil
	pcall(fn.sign_unplace, SIGN_GROUP)
	if restore and state.win and api.nvim_win_is_valid(state.win) and state.prev_signcolumn ~= nil then
		pcall(vim.api.nvim_set_option_value, "signcolumn", state.prev_signcolumn, { scope = "local", win = state.win })
		state.win = nil
		state.prev_signcolumn = nil
	end
end

return M
