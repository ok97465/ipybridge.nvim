-- Python string and payload helpers for ipybridge.
-- Covers path quoting and exec payload builders.

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

-- Encode a Lua string to hex for safe transport via Python exec/compile.
local function to_hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

---Build a Python exec(compile(...)) statement that runs a hex-encoded block.
---@param py_src string
---@return string
function M.send_exec_block(py_src)
	local hex = to_hex(py_src)
	local stmt = string.format(
		"exec(compile(bytes.fromhex('%s').decode('utf-8'), '<ipybridge>', 'exec'), globals(), globals())",
		hex
	)
	if stmt:sub(-1) ~= "\n" then
		stmt = stmt .. "\n"
	end
	return stmt
end

---Build a short Python statement to exec a file's contents in globals().
---@param path string
---@return string
function M.exec_file_stmt(path)
	-- Read and exec file contents in globals(); path is single-quoted
	local safe = M.py_quote_single(path)
	return string.format("exec(open('%s', 'r', encoding='utf-8').read(), globals(), globals())", safe)
end

return M
