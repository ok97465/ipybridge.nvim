-- Platform helpers for ipybridge utilities.
-- Provides OS detection and line separator helpers.

local M = {}

local function resolve_uv()
	return (vim and (vim.uv or vim.loop)) or nil
end

---Detect if the current host is Windows.
---@return boolean
function M.is_windows()
	local uv = resolve_uv()
	if uv and uv.os_uname then
		local ok, uname = pcall(uv.os_uname)
		if ok and uname and uname.sysname == "Windows_NT" then
			return true
		end
	end
	if jit and jit.os then
		return jit.os == "Windows"
	end
	local sep = package.config and package.config:sub(1, 1) or "/"
	return sep == "\\"
end

---Return the line separator for the host OS.
---@return string
function M.line_separator()
	return M.is_windows() and "\r" or "\n"
end

return M
