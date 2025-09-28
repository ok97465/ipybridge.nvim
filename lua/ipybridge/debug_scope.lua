local M = {}

-- Remove private/sentinel entries so the explorer only sees user facing bindings.
local function sanitize_scope(scope)
  if type(scope) ~= 'table' then
    return {}
  end
  local out = {}
  for name, value in pairs(scope) do
    if type(name) == 'string' and not name:match('^__') then
      out[name] = value
    end
  end
  return out
end

-- Return a sanitized table when the input has meaningful entries; otherwise nil.
local function sanitize_scope_nonempty(scope)
  if type(scope) ~= 'table' then
    return nil
  end
  local cleaned = sanitize_scope(scope)
  if next(cleaned) then
    return cleaned
  end
  return nil
end

function M.sanitize_scope(scope)
  return sanitize_scope(scope)
end

function M.resolve_scope(prefer_locals, locals_snapshot, globals_snapshot)
  local local_scope = sanitize_scope_nonempty(locals_snapshot and locals_snapshot.__locals__)
  local global_scope = sanitize_scope_nonempty(globals_snapshot and globals_snapshot.__globals__)

  -- Prefer locals when the current debug frame lives inside a function and captures values.
  if prefer_locals and local_scope then
    return local_scope
  end

  -- Otherwise show globals first, matching the previous behaviour for module-level frames.
  if global_scope then
    return global_scope
  end

  if local_scope then
    return local_scope
  end

  local fallback_globals = sanitize_scope_nonempty(globals_snapshot)
  if fallback_globals then
    return fallback_globals
  end

  local fallback_locals = sanitize_scope_nonempty(locals_snapshot)
  if fallback_locals then
    return fallback_locals
  end

  return {}
end

return M
