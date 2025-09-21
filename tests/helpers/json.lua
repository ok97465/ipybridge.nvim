local Json = {}

local fallback_nil = setmetatable({}, {
  __tostring = function()
    return 'vim.NIL'
  end,
})

Json.NIL = fallback_nil

local function json_null()
  local ok, value = pcall(function()
    return _G and _G.vim and _G.vim.NIL
  end)
  if ok and value ~= nil then
    return value
  end
  return fallback_nil
end

local function decode_error(str, idx, msg)
  error(string.format('JSON decode error at position %d: %s', idx or 0, msg), 2)
end

local function skip_ws(str, idx)
  while idx <= #str do
    local c = str:sub(idx, idx)
    if c ~= ' ' and c ~= '\n' and c ~= '\r' and c ~= '\t' then
      break
    end
    idx = idx + 1
  end
  return idx
end

local function parse_string(str, idx)
  idx = idx + 1
  local buf = {}
  while idx <= #str do
    local c = str:sub(idx, idx)
    if c == '"' then
      return table.concat(buf), idx + 1
    elseif c == '\\' then
      idx = idx + 1
      if idx > #str then
        decode_error(str, idx, 'unterminated escape sequence')
      end
      local esc = str:sub(idx, idx)
      if esc == '"' or esc == '\\' or esc == '/' then
        table.insert(buf, esc)
      elseif esc == 'b' then
        table.insert(buf, '\b')
      elseif esc == 'f' then
        table.insert(buf, '\f')
      elseif esc == 'n' then
        table.insert(buf, '\n')
      elseif esc == 'r' then
        table.insert(buf, '\r')
      elseif esc == 't' then
        table.insert(buf, '\t')
      elseif esc == 'u' then
        local hex = str:sub(idx + 1, idx + 4)
        if #hex < 4 or not hex:match('^[0-9a-fA-F]+$') then
          decode_error(str, idx, 'invalid unicode escape')
        end
        local code = tonumber(hex, 16)
        if not code then
          decode_error(str, idx, 'invalid unicode value')
        end
        if code < 0x80 then
          table.insert(buf, string.char(code))
        elseif type(utf8) == 'table' and type(utf8.char) == 'function' then
          table.insert(buf, utf8.char(code))
        else
          decode_error(str, idx, 'utf8 library unavailable')
        end
        idx = idx + 4
      else
        decode_error(str, idx, 'invalid escape character')
      end
    else
      table.insert(buf, c)
    end
    idx = idx + 1
  end
  decode_error(str, idx, 'unterminated string')
end

local function parse_number(str, idx)
  local start_idx = idx
  local c = str:sub(idx, idx)
  if c == '-' then
    idx = idx + 1
  end
  if idx > #str then
    decode_error(str, idx, 'unexpected end while parsing number')
  end
  c = str:sub(idx, idx)
  if c == '0' then
    idx = idx + 1
  elseif c:match('%d') then
    repeat
      idx = idx + 1
      c = str:sub(idx, idx)
    until c == '' or not c:match('%d')
  else
    decode_error(str, idx, 'invalid number')
  end
  if str:sub(idx, idx) == '.' then
    idx = idx + 1
    c = str:sub(idx, idx)
    if not c:match('%d') then
      decode_error(str, idx, 'invalid fractional part')
    end
    repeat
      idx = idx + 1
      c = str:sub(idx, idx)
    until c == '' or not c:match('%d')
  end
  c = str:sub(idx, idx)
  if c == 'e' or c == 'E' then
    idx = idx + 1
    c = str:sub(idx, idx)
    if c == '+' or c == '-' then
      idx = idx + 1
      c = str:sub(idx, idx)
    end
    if not c:match('%d') then
      decode_error(str, idx, 'invalid exponent')
    end
    repeat
      idx = idx + 1
      c = str:sub(idx, idx)
    until c == '' or not c:match('%d')
  end
  local number = tonumber(str:sub(start_idx, idx - 1))
  if number == nil then
    decode_error(str, start_idx, 'failed to parse number')
  end
  return number, idx
end

local parse_value

local function parse_array(str, idx)
  idx = idx + 1
  local arr = {}
  idx = skip_ws(str, idx)
  if str:sub(idx, idx) == ']' then
    return arr, idx + 1
  end
  while true do
    local value
    value, idx = parse_value(str, idx)
    table.insert(arr, value)
    idx = skip_ws(str, idx)
    local c = str:sub(idx, idx)
    if c == ']' then
      return arr, idx + 1
    elseif c == ',' then
      idx = skip_ws(str, idx + 1)
    else
      decode_error(str, idx, 'expected comma or closing bracket')
    end
  end
end

local function parse_object(str, idx)
  idx = idx + 1
  local obj = {}
  idx = skip_ws(str, idx)
  if str:sub(idx, idx) == '}' then
    return obj, idx + 1
  end
  while true do
    if str:sub(idx, idx) ~= '"' then
      decode_error(str, idx, 'expected string key')
    end
    local key
    key, idx = parse_string(str, idx)
    idx = skip_ws(str, idx)
    if str:sub(idx, idx) ~= ':' then
      decode_error(str, idx, 'expected colon after key')
    end
    idx = skip_ws(str, idx + 1)
    local value
    value, idx = parse_value(str, idx)
    obj[key] = value
    idx = skip_ws(str, idx)
    local c = str:sub(idx, idx)
    if c == '}' then
      return obj, idx + 1
    elseif c == ',' then
      idx = skip_ws(str, idx + 1)
    else
      decode_error(str, idx, 'expected comma or closing brace')
    end
  end
end

function parse_value(str, idx)
  idx = skip_ws(str, idx)
  local c = str:sub(idx, idx)
  if c == '"' then
    local value
    value, idx = parse_string(str, idx)
    return value, idx
  elseif c == '{' then
    return parse_object(str, idx)
  elseif c == '[' then
    return parse_array(str, idx)
  elseif c == '-' or c:match('%d') then
    return parse_number(str, idx)
  elseif str:sub(idx, idx + 3) == 'null' then
    return json_null(), idx + 4
  elseif str:sub(idx, idx + 3) == 'true' then
    return true, idx + 4
  elseif str:sub(idx, idx + 4) == 'false' then
    return false, idx + 5
  else
    decode_error(str, idx, 'unexpected character')
  end
end

function Json.decode(str)
  if type(str) ~= 'string' then
    error('JSON decode expects a string', 2)
  end
  local idx = skip_ws(str, 1)
  local value
  value, idx = parse_value(str, idx)
  idx = skip_ws(str, idx)
  if idx <= #str then
    decode_error(str, idx, 'trailing characters')
  end
  return value
end

return Json
