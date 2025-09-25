-- IPython execution magics for ipybridge.nvim
-- Provides Python code string that defines runcell/runfile line magics.

local py_module = require('ipybridge.py_module')

local M = {}

function M.build()
  local template = py_module.source('exec_magics.py')
  local module_b64 = py_module.base64('ipybridge_ns.py')
  return template:gsub('__MODULE_B64__', module_b64)
end

return M
