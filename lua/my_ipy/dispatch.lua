-- Dispatch decoded JSON messages from the IPython terminal to UI modules.
local M = {}

-- Simple router by message tag.
function M.handle(msg)
  -- msg: { tag = 'vars'|'preview'|..., data = table|nil, error = string|nil }
  if type(msg) ~= 'table' or not msg.tag then return end
  if msg.tag == 'vars' then
    local ok, mod = pcall(require, 'my_ipy.var_explorer')
    if ok and mod and mod.on_vars then
      pcall(mod.on_vars, msg.data or {})
    end
    return
  end
  if msg.tag == 'preview' then
    local ok, mod = pcall(require, 'my_ipy.data_viewer')
    if ok and mod and mod.on_preview then
      pcall(mod.on_preview, msg.data or { error = msg.error })
    end
    return
  end
end

return M

