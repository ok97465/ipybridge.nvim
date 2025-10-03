-- Utility helpers for ipybridge.nvim
-- All comments are written in English per user request.

local uv = vim.uv
local api = vim.api
local fn = vim.fn

local M = {}

-- Fast file existence check using libuv.
function M.file_exists(path)
  return uv.fs_stat(path) and true or false
end

-- Normalize a filesystem path for Python literals (portable across OS).
-- 1) Convert Windows backslashes to forward slashes
-- 2) Quote helpers for single or double-quoted Python strings as needed
local function _norm_path(p)
  return tostring(p or ''):gsub('\\', '/')
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
  if mode == 'v' or mode == 'V' or mode == string.char(22) then
    local vpos = fn.getpos('v')
    local cpos = fn.getpos('.')
    local srow = vpos[2]
    local erow = cpos[2]
    if srow > erow then srow, erow = erow, srow end
    return srow - 1, erow -- end is exclusive when passed to nvim_buf_get_lines
  end
  -- Fallback when not in visual: use the last visual marks ('<' and '>').
  local srow = (api.nvim_buf_get_mark(0, '<') or { 0, 0 })[1]
  local erow = (api.nvim_buf_get_mark(0, '>') or { 0, 0 })[1]
  if srow == 0 or erow == 0 then return nil end
  if srow > erow then srow, erow = erow, srow end
  return srow - 1, erow
end

-- Encode a Lua string to hex for safe transport via Python exec/compile.
local function to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Build a Python exec(compile(...)) that decodes a hex-encoded block and executes it in globals().
function M.send_exec_block(py_src)
  local hex = to_hex(py_src)
  local stmt = string.format("exec(compile(bytes.fromhex('%s').decode('utf-8'), '<ipybridge>', 'exec'), globals(), globals())\n", hex)
  return stmt
end

-- Build a short Python statement to exec a file's contents in globals().
function M.exec_file_stmt(path)
  -- Read and exec file contents in globals(); path is single-quoted
  local safe = M.py_quote_single(path)
  return string.format("exec(open('%s', 'r', encoding='utf-8').read(), globals(), globals())\n", safe)
end

-- Build a bracketed-paste payload for multiple lines.
-- Used when multiline selections are sent in 'paste' mode so prompts stay aligned.
function M.paste_block(lines_tbl)
  if not lines_tbl or #lines_tbl == 0 then return "" end
  return "\x1b[200~" .. table.concat(lines_tbl, "\n") .. "\n\x1b[201~\n"
end

return M
