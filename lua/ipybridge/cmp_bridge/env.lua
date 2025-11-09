local M = {}

function M.current_bridge()
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" then
		return nil
	end
	return rawget(bridge, "term_instance")
end

local function raw_bridge()
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" then
		return nil
	end
	return bridge
end

function M.is_ipybridge_terminal(bufnr)
	local term = M.current_bridge()
	return term and term.buf_id == bufnr or false
end

function M.is_debug_session()
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" then
		return false
	end
	return bridge._debug_active == true
end

function M.is_active_ipy_terminal()
	local ok_mode, info = pcall(vim.api.nvim_get_mode)
	local mode = ok_mode and tostring(info.mode or ""):sub(1, 1) or ""
	if mode ~= "t" then
		return false
	end
	local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
	if not ok_buf then
		return false
	end
	return M.is_ipybridge_terminal(buf)
end

function M.feed_terminal(keys)
	local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(termcodes, "tn", false)
end

local function collect_names(scope, acc)
	if type(scope) ~= "table" then
		return
	end
	for key, _ in pairs(scope) do
		if type(key) == "string" and key ~= "" and not key:match("^__") then
			acc[key] = true
		end
	end
end

function M.debug_variable_names()
	local bridge = raw_bridge()
	if not bridge then
		return {}
	end
	local names = {}
	collect_names(bridge._latest_vars, names)
	local locals_snapshot = bridge._debug_locals_snapshot
	if type(locals_snapshot) == "table" then
		collect_names(locals_snapshot.__locals__, names)
	end
	local globals_snapshot = bridge._debug_globals_snapshot
	if type(globals_snapshot) == "table" then
		collect_names(globals_snapshot.__globals__, names)
	end
	return names
end

return M
