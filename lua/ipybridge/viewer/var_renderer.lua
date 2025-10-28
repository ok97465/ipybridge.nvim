-- Variable explorer renderer.
-- Produces lines and drill-down mappings for variable snapshots.

local VarRenderer = {}

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
    local kind = tostring(item.kind or ''):gsub('[\r\n]', ' ')
    local ty = tostring(item.type or ''):gsub('[\r\n]', ' ')
    local label = string.format('[%s]=%s', tostring(idx), (#kind > 0 and kind) or ty)
    table.insert(parts, label)
    added = added + 1
    if added >= 3 then
      break
    end
  end
  if #parts == 0 then
    return tostring(entry.kind or 'sequence')
  end
  return table.concat(parts, ' ')
end

local function render_entry(name, entry)
  local lines = {}
  local mappings = {}

  local ty = tostring(entry.type or ''):gsub('[\r\n]', ' ')
  local shp = fmt_shape(entry.shape)
  local preview = tostring(entry.repr or ''):gsub('[\r\n]', ' ')
  local kind = tostring(entry.kind or '')
  if kind == 'list' or kind == 'tuple' or kind == 'set' then
    preview = sequence_preview_summary(entry)
  end
  local row = string.format('%-20s %-14s %-9s %s', name, ty, shp, preview)
  table.insert(lines, row)
  table.insert(mappings, { name = name, path = name })

  if kind ~= 'list' and kind ~= 'tuple' and kind ~= 'set' then
    return lines, mappings
  end

  local items = sequence_items(entry)
  local allow_index = entry.sequence_index_paths
  if allow_index == nil then
    allow_index = kind ~= 'set'
  end

  if #items == 0 then
    table.insert(lines, string.format('  (empty %s)', kind))
    table.insert(mappings, false)
    return lines, mappings
  end

  for _, item in ipairs(items) do
    if item.placeholder then
      local more = tonumber(item.more) or 0
      if more > 0 then
        table.insert(lines, string.format('  ... (+%d more)', more))
      else
        table.insert(lines, '  ...')
      end
      table.insert(mappings, false)
    else
      local idx = item.index
      local idx_str
      if type(idx) == 'number' then
        idx_str = string.format('%d', idx)
      else
        idx_str = tostring(idx or '?')
      end
      local item_type = tostring(item.type or ''):gsub('[\r\n]', ' ')
      local item_kind = tostring(item.kind or ''):gsub('[\r\n]', ' ')
      local repr = tostring(item.repr or ''):gsub('[\r\n]', ' ')
      if #repr > 120 then
        repr = repr:sub(1, 117) .. '...'
      end
      local parts = { string.format('  [%s] <%s>', idx_str, item_type) }
      if item_kind ~= '' then
        table.insert(parts, 'kind=' .. item_kind)
      end
      if repr ~= '' then
        table.insert(parts, 'repr=' .. repr)
      end
      table.insert(lines, table.concat(parts, ' '))
      if allow_index and item.path_index ~= nil and item.previewable then
        local mapping = {
          name = name,
          path = string.format('%s[%s]', name, idx_str),
          previewable = item.previewable == true,
        }
        table.insert(mappings, mapping)
      else
        table.insert(mappings, false)
      end
    end
  end

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
