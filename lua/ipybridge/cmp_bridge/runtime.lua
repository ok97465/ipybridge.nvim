local engines = require("ipybridge.cmp_bridge.engines")
local env = require("ipybridge.cmp_bridge.env")

local Runtime = {}

local state = {
	key_listener_attached = false,
	mapped_buffers = {},
	autocmd_buffers = {},
}

local function ensure_key_listener()
	if state.key_listener_attached then
		return
	end
	local ns = vim.api.nvim_create_namespace("ipybridge_cmp_keys")
	vim.on_key(function(char)
		if not char or char == "" then
			return
		end
		if char == "\x0e" or char == "\x10" or char == "\r" or char == "\27" then
			return
		end
		if char:match("%c") then
			return
		end
		if not env.is_active_ipy_terminal() then
			return
		end
		vim.schedule(function()
			if not env.is_active_ipy_terminal() then
				return
			end
			if engines.is_visible() then
				engines.abort()
			end
		end)
	end, ns)
	state.key_listener_attached = true
end

local function setup_terminal_keymaps()
	local buf = vim.api.nvim_get_current_buf()
	if state.mapped_buffers[buf] then
		return
	end
	local function termcodes(lhs)
		return vim.api.nvim_replace_termcodes(lhs, true, false, true)
	end
	local opts = { buffer = buf, noremap = true, silent = true, expr = true }

	vim.keymap.set("t", "<C-n>", function()
		if engines.is_visible() then
			vim.schedule(function()
				engines.select("next")
			end)
			return ""
		end
		return termcodes("<C-n>")
	end, opts)

	vim.keymap.set("t", "<C-p>", function()
		if engines.is_visible() then
			vim.schedule(function()
				engines.select("prev")
			end)
			return ""
		end
		return termcodes("<C-p>")
	end, opts)

	vim.keymap.set("t", "<CR>", function()
		if engines.is_visible() then
			engines.accept()
			return ""
		end
		return termcodes("<CR>")
	end, opts)

	vim.keymap.set("t", "<Esc>", function()
		if engines.is_visible() then
			vim.schedule(function()
				engines.abort()
			end)
			return ""
		end
		return termcodes("<Esc>")
	end, opts)

	state.mapped_buffers[buf] = true
end

local function setup_buffer_autocmds()
	local buf = vim.api.nvim_get_current_buf()
	if state.autocmd_buffers[buf] then
		return
	end
	local group = vim.api.nvim_create_augroup("ipybridge_cmp_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "BufLeave", "TermClose", "TermLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			engines.abort()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			state.mapped_buffers[buf] = nil
			state.autocmd_buffers[buf] = nil
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})
	state.autocmd_buffers[buf] = group
end

function Runtime.ensure_bindings()
	setup_terminal_keymaps()
	setup_buffer_autocmds()
	ensure_key_listener()
end

function Runtime.ensure()
	if not engines.ensure() then
		return false
	end
	Runtime.ensure_bindings()
	return true
end

function Runtime.trigger()
	if not Runtime.ensure() then
		return false
	end
	return engines.trigger()
end

return Runtime

