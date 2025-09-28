#!/usr/bin/env lua
package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local specs = {
  'tests.spec.dispatch_spec',
  'tests.spec.term_ipy_spec',
  'tests.spec.utils_spec',
  'tests.spec.kernel_spec',
  'tests.spec.zmq_client_spec',
  'tests.spec.data_viewer_spec',
  'tests.spec.var_explorer_spec',
}

local any_fail = false
for _, spec in ipairs(specs) do
  local ok, err = pcall(require, spec)
  if not ok then
    any_fail = true
    io.stderr:write(string.format('Error running %s: %s\n', spec, err))
  end
end

if any_fail then
  os.exit(1)
else
  print('Lua tests completed successfully.')
end
