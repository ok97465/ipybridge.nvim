-- Dispatch decoded JSON messages from the IPython terminal to UI modules.
local M = {}

-- Simple router by message tag.
function M.handle(msg)
  -- msg: { tag = 'vars'|'preview'|..., data = table|nil, error = string|nil }
  if type(msg) ~= 'table' or not msg.tag then return end
  if msg.tag == 'vars' then
    local ok, mod = pcall(require, 'ipybridge.var_explorer')
    if ok and mod and mod.on_vars then
      pcall(mod.on_vars, msg.data or {})
    end
    return
  end
  if msg.tag == 'preview' then
    local ok, mod = pcall(require, 'ipybridge.data_viewer')
    if ok and mod and mod.on_preview then
      pcall(mod.on_preview, msg.data or { error = msg.error })
    end
    return
  end
  if msg.tag == 'debug_location' then
    local bridge = package.loaded['ipybridge']
    if bridge and type(bridge.on_debug_location) == 'function' then
      vim.schedule(function()
        pcall(bridge.on_debug_location, msg.data or {})
      end)
    end
    return
  end
end

return M
