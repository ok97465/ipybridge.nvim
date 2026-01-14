-- Platform helpers for ipybridge utilities.
-- Provides OS detection and line separator helpers.

local M = {}

local uv = vim.uv

---Detect if the current host is Windows.
---@return boolean
function M.is_windows()
	return uv.os_uname().sysname == "Windows_NT"
end

---Return the line separator for the host OS.
---@return string
function M.line_separator()
	return M.is_windows() and "\r" or "\n"
end

return M
