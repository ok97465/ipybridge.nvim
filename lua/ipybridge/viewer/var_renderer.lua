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
    local ty = tostring(entry.type or ''):gsub('[\r\n]', ' ')
    local shp = fmt_shape(entry.shape)
    local pv = tostring(entry.repr or ''):gsub('[\r\n]', ' ')
    local row = string.format('%-20s %-14s %-9s %s', name, ty, shp, pv)
    table.insert(lines, row)
    map[#lines] = name
  end

  if #lines <= 2 then
    table.insert(lines, '(No user variables) — press r to refresh')
  end

  return lines, map
end

return VarRenderer
