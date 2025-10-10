-- Debugger completion helper for ipybridge.nvim.

local unpack = unpack or table.unpack

local M = {
  generation = 0,
}

local function schedule(cb, ...)
  if type(cb) ~= 'function' then
    return
  end
  local args = { ... }
  vim.schedule(function()
    cb(unpack(args))
  end)
end

local function respond_if_current(state, generation, cb, payload, err)
  if state.generation ~= generation then
    return
  end
  schedule(cb, payload, err)
end

function M.fetch(params, cb)
  params = params or {}
  local code = params.code or ''
  local cursor_pos = params.cursor_pos
  if type(cursor_pos) ~= 'number' then
    cursor_pos = #code
  end
  local debug_mode = params.debug ~= false
  M.generation = (M.generation or 0) + 1
  local generation = M.generation

  local bridge = package.loaded['ipybridge']
  if type(bridge) ~= 'table' or type(bridge.ensure_zmq) ~= 'function' then
    respond_if_current(M, generation, cb, nil, 'bridge_unavailable')
    return generation
  end

  bridge.ensure_zmq(function(ok)
    if M.generation ~= generation then
      return
    end
    if not ok then
      respond_if_current(M, generation, cb, nil, 'zmq_unavailable')
      return
    end
    local ok_zmq, z = pcall(require, 'ipybridge.zmq_client')
    if not ok_zmq or not z or type(z.request) ~= 'function' then
      respond_if_current(M, generation, cb, nil, 'zmq_client_missing')
      return
    end
    local sent = z.request('complete', {
      code = code,
      cursor_pos = cursor_pos,
      debug = debug_mode,
      debug_style = 'internal',
    }, function(msg)
      if M.generation ~= generation then
        return
      end
      if msg and msg.ok and msg.tag == 'complete' then
        respond_if_current(M, generation, cb, msg.data or {}, nil)
      else
        respond_if_current(M, generation, cb, nil, (msg and msg.error) or 'complete_failed')
      end
    end)
    if not sent then
      respond_if_current(M, generation, cb, nil, 'send_failed')
    end
  end)

  return generation
end

return M
