-- Utility helpers shared across the plugin.
-- Covers filesystem checks, Python quoting helpers, selection math, and Python
-- exec payload builders.

local uv = (vim and (vim.uv or vim.loop)) or nil
local api = vim.api
local fn = vim.fn
-- Detect Windows even when uv.os_uname is unavailable in stripped test shims.
local function detect_windows()
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
local is_windows = detect_windows()

local M = {}

-- Fast file existence check using libuv.
local function _ensure_dir(path)
	if not path or path == "" then
		return
	end
	-- Try mkdir -p semantics with whichever API is available.
	if uv and uv.fs_stat and uv.fs_mkdir then
		if not uv.fs_stat(path) then
			pcall(uv.fs_mkdir, path, 448)
		end
	end
	if fn and fn.mkdir then
		pcall(fn.mkdir, path, "p")
	end
end

local function _state_dir()
	local base = nil
	if fn and fn.stdpath then
		local ok, data_dir = pcall(fn.stdpath, "data")
		if ok and type(data_dir) == "string" and data_dir ~= "" then
			base = data_dir
		end
	end
	if base == nil or base == "" then
		local ok_home, home = pcall(fn.expand, "~")
		if ok_home and type(home) == "string" and home ~= "" then
			base = home .. "/.local/share"
		else
			base = "."
		end
	end
	local dir = tostring(base):gsub("\\", "/") .. "/ipybridge"
	_ensure_dir(dir)
	return dir
end

function M.file_exists(path)
	if not (uv and uv.fs_stat) then
		return false
	end
	return uv.fs_stat(path) and true or false
end

-- Return a path inside the plugin's persistent state directory, creating it if needed.
function M.state_path(filename)
	local dir = _state_dir()
	if not dir or dir == "" then
		return nil
	end
	if not filename or filename == "" then
		return dir
	end
	return (dir .. "/" .. tostring(filename)):gsub("\\", "/")
end

-- Normalize a filesystem path for Python literals (portable across OS).
-- 1) Convert Windows backslashes to forward slashes
-- 2) Quote helpers for single or double-quoted Python strings as needed
local function _norm_path(p)
	return tostring(p or ""):gsub("\\", "/")
end

function M.py_quote_single(p)
	return _norm_path(p):gsub("'", "\\'")
end

function M.py_quote_double(p)
	return _norm_path(p):gsub('"', '\\"')
end

-- Return a 0-indexed (start_row, end_row_exclusive) line range for visual selection.
-- Works reliably even when called directly from a visual-mode mapping by using getpos('v').
function M.selection_line_range()
	local mode = fn.mode()
	-- Visual modes: 'v' (charwise), 'V' (linewise), CTRL-V (blockwise).
	-- Use string.char(22) to match blockwise visual without escape ambiguity.
	if mode == "v" or mode == "V" or mode == string.char(22) then
		local vpos = fn.getpos("v")
		local cpos = fn.getpos(".")
		local srow = vpos[2]
		local erow = cpos[2]
		if srow > erow then
			srow, erow = erow, srow
		end
		return srow - 1, erow -- end is exclusive when passed to nvim_buf_get_lines
	end
	-- Fallback when not in visual: use the last visual marks ('<' and '>').
	local srow = (api.nvim_buf_get_mark(0, "<") or { 0, 0 })[1]
	local erow = (api.nvim_buf_get_mark(0, ">") or { 0, 0 })[1]
	if srow == 0 or erow == 0 then
		return nil
	end
	if srow > erow then
		srow, erow = erow, srow
	end
	return srow - 1, erow
end

-- Encode a Lua string to hex for safe transport via Python exec/compile.
local function to_hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

-- Build a Python exec(compile(...)) that decodes a hex-encoded block and executes it in globals().
function M.send_exec_block(py_src)
	local hex = to_hex(py_src)
	local stmt = string.format(
		"exec(compile(bytes.fromhex('%s').decode('utf-8'), '<ipybridge>', 'exec'), globals(), globals())",
		hex
	)
	return stmt
end

-- Build a short Python statement to exec a file's contents in globals().
function M.exec_file_stmt(path)
	-- Read and exec file contents in globals(); path is single-quoted
	local safe = M.py_quote_single(path)
	return string.format("exec(open('%s', 'r', encoding='utf-8').read(), globals(), globals())", safe)
end

-- Build a bracketed-paste payload for multiple lines.
-- Used when multiline selections are sent in 'paste' mode so prompts stay aligned.
function M.paste_block(lines_tbl)
	if not lines_tbl or #lines_tbl == 0 then
		return ""
	end
	local separator = is_windows and "\r" or "\n"
	local body = table.concat(lines_tbl, separator)
	return "\x1b[200~" .. body .. "\n\x1b[201~"
end

-- Check for missing python dependencies.
-- Returns a table of missing modules, or nil if all are present.
function M.check_python_deps(python_cmd, modules)
	local py_module = require("ipybridge.py_module")
	local ok_path, script_path = pcall(py_module.path, "check_deps.py")
	if not ok_path or not script_path then
		return nil, "could not find check_deps.py"
	end

	local cmd = { python_cmd, script_path }
	vim.list_extend(cmd, modules)

	local output = fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		-- Fallback to assuming dependencies are present if the check script fails
		return nil
	end

	if output == "" then
		return nil
	end

	local missing = {}
	for s in vim.gsplit(output, "\n") do
		if s ~= "" then
			table.insert(missing, s)
		end
	end

	if #missing > 0 then
		return missing
	end

	return nil
end

return M
