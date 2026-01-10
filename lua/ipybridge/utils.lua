-- Utility facade shared across the plugin.
-- Delegates to focused helper modules to keep responsibilities small.

local fs = require("ipybridge.utils.fs")
local selection = require("ipybridge.utils.selection")
local py = require("ipybridge.utils.py")
local paste = require("ipybridge.utils.paste")
local deps = require("ipybridge.utils.deps")

local M = {}

M.file_exists = fs.file_exists
M.state_path = fs.state_path
M.selection_line_range = selection.selection_line_range
M.py_quote_single = py.py_quote_single
M.py_quote_double = py.py_quote_double
M.send_exec_block = py.send_exec_block
M.exec_file_stmt = py.exec_file_stmt
M.paste_block = paste.paste_block
M.check_python_deps = deps.check_python_deps

return M
