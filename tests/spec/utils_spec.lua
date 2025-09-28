package.path = table.concat({
  'tests/?.lua',
  'tests/?/init.lua',
  'lua/?.lua',
  'lua/?/init.lua',
  package.path,
}, ';')

local results = {}

local function record(name, ok, err)
  table.insert(results, { name = name, ok = ok, err = err })
  if ok then
    io.write(string.format('[PASS] %s\n', name))
  else
    io.write(string.format('[FAIL] %s: %s\n', name, err))
  end
end

local function it(name, fn)
  local ok, err = pcall(fn)
  record(name, ok, err)
end

local function fresh_utils(opts)
  opts = opts or {}
  _G.vim = {
    uv = {
      fs_stat = function(path)
        return opts.fs_stat and opts.fs_stat(path) or nil
      end,
    },
    api = {
      nvim_buf_get_lines = function(_, s, e)
        local lines = opts.lines or {}
        local out = {}
        for i = s + 1, e do
          out[#out + 1] = lines[i] or ''
        end
        return out
      end,
      nvim_buf_get_mark = function(_, mark)
        local marks = opts.marks or {}
        return marks[mark] or { 0, 0 }
      end,
    },
    fn = {
      mode = function()
        return opts.mode or 'n'
      end,
      getpos = function(sym)
        local positions = opts.positions or {}
        return positions[sym] or { 0, 1, 0, 0 }
      end,
    },
  }
  package.loaded['ipybridge.utils'] = nil
  return require('ipybridge.utils')
end

it('send_exec_block wraps payload as exec compile call', function()
  local utils = fresh_utils()
  local stmt = utils.send_exec_block('print(123)\n')
  assert(stmt:match("exec%(compile%(bytes.fromhex%('%x+'%)"), 'expected exec compile wrapper')
  assert(stmt:sub(-1) == '\n', 'expected trailing newline')
end)

it('py_quote helpers normalise slashes and escape quotes', function()
  local utils = fresh_utils()
  local sample = "C:\\temp\\mix'\""
  assert(utils.py_quote_single(sample) == "C:/temp/mix\\'\"", 'single quote helper did not escape correctly')
  assert(utils.py_quote_double(sample) == "C:/temp/mix'\\\"", 'double quote helper did not escape correctly')
end)

it('selection_line_range honours visual selection order', function()
  local utils = fresh_utils({
    mode = 'v',
    positions = {
      ['v'] = { 0, 5, 0, 0 },
      ['.'] = { 0, 2, 0, 0 },
    },
  })
  local s, e = utils.selection_line_range()
  assert(s == 1, 'expected start row adjusted to 0-index')
  assert(e == 5, 'expected end row preserved')
end)

it('selection_line_range falls back to marks when not visual', function()
  local utils = fresh_utils({
    mode = 'n',
    marks = {
      ['<'] = { 3, 0 },
      ['>'] = { 7, 0 },
    },
  })
  local s, e = utils.selection_line_range()
  assert(s == 2 and e == 7, 'expected marks translated into range')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('utils_spec failed')
end

return true
