-- Python string helpers for ipybridge.
-- Covers path quoting and startup script statements.

local M = {}

-- Normalize a filesystem path for Python literals (portable across OS).
-- 1) Convert Windows backslashes to forward slashes
-- 2) Quote helpers for single or double-quoted Python strings as needed
local function norm_path(p)
	return tostring(p or ""):gsub("\\", "/")
end

---Escape a path for use inside single-quoted Python literals.
---@param p string
---@return string
function M.py_quote_single(p)
	return norm_path(p):gsub("'", "\\'")
end

---Escape a path for use inside double-quoted Python literals.
---@param p string
---@return string
function M.py_quote_double(p)
	return norm_path(p):gsub('"', '\\"')
end

---Build a Python statement that execs a file's contents in globals().
---@param path string
---@return string
function M.exec_file_stmt(path)
	-- Read and exec file contents in globals(); path is single-quoted.
	local safe = M.py_quote_single(path)
	return string.format("exec(open('%s', 'r', encoding='utf-8').read(), globals(), globals())", safe)
end

return M
