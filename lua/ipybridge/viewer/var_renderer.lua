-- Variable explorer renderer.
-- Produces lines and drill-down mappings for variable snapshots.

local VarRenderer = {}

local sequence_kinds = {
  list = true,
  tuple = true,
  set = true,
}

local function fmt_shape(shp)
  if type(shp) ~= 'table' then
    return ''
  end
  if #shp == 2 then
    return string.format('%sx%s', tostring(shp[1]), tostring(shp[2]))
  end
  local ok, list = pcall(vim.tbl_map, tostring, shp)
  if ok then
    return table.concat(list, 'x')
  end
  return ''
end

local function header_line()
  return 'Name                Type            Shape     Preview'
end

local function underline()
  return string.rep('-', 72)
end

local function sanitize_inline(value)
  if value == nil then
    return ''
  end
  local text = tostring(value)
  return text:gsub('[\r\n]', ' ')
end

local function truncate(text, limit)
  if #text > limit then
    return text:sub(1, limit - 3) .. '...'
  end
  return text
end

local function sequence_items(entry)
  local items = entry.sequence_items
  if type(items) ~= 'table' then
    items = entry.list_items
  end
  if type(items) ~= 'table' then
    return {}
  end
  return items
end

local function mapping_items(entry)
  local items = entry.mapping_items
  if type(items) ~= 'table' then
    return {}
  end
  return items
end

local function sequence_preview_summary(entry)
  local parts = {}
  local length = tonumber(entry.length) or (type(entry.shape) == 'table' and tonumber(entry.shape[1])) or nil
  if length then
    table.insert(parts, string.format('len=%d', length))
  end
  local preview_items = sequence_items(entry)
  local added = 0
  for _, item in ipairs(preview_items) do
    if item.placeholder then
      local more = tonumber(item.more)
      if more and more > 0 then
        table.insert(parts, string.format('+%d more', more))
      end
      break
    end
    local idx = item.index or '?'
    local kind = sanitize_inline(item.kind or '')
    local ty = sanitize_inline(item.type or '')
    local label = string.format('[%s]=%s', tostring(idx), (#kind > 0 and kind) or ty)
    table.insert(parts, label)
    added = added + 1
    if added >= 3 then
      break
    end
  end
  if #parts == 0 then
    local kind = sanitize_inline(entry.kind or 'sequence')
    return kind ~= '' and kind or 'sequence'
  end
  return table.concat(parts, ' ')
end

local function mapping_preview_summary(entry)
  local parts = {}
  local length = tonumber(entry.length) or (type(entry.shape) == 'table' and tonumber(entry.shape[1])) or nil
  if length then
    table.insert(parts, string.format('len=%d', length))
  end
  local items = mapping_items(entry)
  local added = 0
  for _, item in ipairs(items) do
    if item.placeholder then
      local more = tonumber(item.more)
      if more and more > 0 then
        table.insert(parts, string.format('+%d more', more))
      end
      break
    end
    local key_display = truncate(sanitize_inline(item.key or ''), 60)
    local kind = sanitize_inline(item.kind or '')
    local ty = sanitize_inline(item.type or '')
    local label = key_display
    if kind ~= '' then
      label = label .. '=' .. kind
    elseif ty ~= '' then
      label = label .. '=' .. ty
    end
    table.insert(parts, label)
    added = added + 1
    if added >= 3 then
      break
    end
  end
  if #parts == 0 then
    return 'dict'
  end
  return table.concat(parts, ' ')
end

local function render_entry(name, entry)
  local lines = {}
  local mappings = {}

  local ty = sanitize_inline(entry.type or '')
  local shp = fmt_shape(entry.shape)
  local preview = sanitize_inline(entry.repr or '')
  local kind = sanitize_inline(entry.kind or '')
  if sequence_kinds[kind] then
    preview = sequence_preview_summary(entry)
  elseif kind == 'dict' then
    preview = mapping_preview_summary(entry)
  end
  local row = string.format('%-20s %-14s %-9s %s', name, ty, shp, preview)
  table.insert(lines, row)
  -- Keep mapping for root variable only; child rows are intentionally omitted.
  table.insert(mappings, { name = name, path = name })

  return lines, mappings
end

function VarRenderer.render(vars)
  local lines = {}
  local map = {}
  local names = {}
  for name in pairs(vars or {}) do
    table.insert(names, name)
  end
  table.sort(names)

  table.insert(lines, header_line())
  table.insert(lines, underline())

  for _, name in ipairs(names) do
    local entry = vars[name] or {}
    local entry_lines, entry_map = render_entry(name, entry)
    for idx, line in ipairs(entry_lines) do
      table.insert(lines, line)
      local mapping = entry_map[idx]
      if mapping then
        map[#lines] = mapping
      end
    end
  end

  if #lines <= 2 then
    table.insert(lines, '(No user variables) -- press r to refresh')
  end

  return lines, map
end

return VarRenderer
