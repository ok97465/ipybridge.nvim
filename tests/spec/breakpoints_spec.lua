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

local function stub_vim(ctx)
  local prev_vim = _G.vim
  local vim_stub = {
    notify = function() end,
    log = { levels = { WARN = 'WARN' } },
    schedule = function(cb) if type(cb) == 'function' then cb() end end,
    fn = {
      tempname = function()
        ctx.temp_index = ctx.temp_index + 1
        return string.format('/tmp/bp_%d', ctx.temp_index)
      end,
      writefile = function(lines, path)
        table.insert(ctx.file_writes, { lines = lines, path = path })
        return true
      end,
      sign_define = function(name, opts)
        ctx.sign_define = { name = name, opts = opts }
      end,
      sign_place = function(id, group, name, bufnr, opts)
        table.insert(ctx.sign_place_calls, { id = id, group = group, name = name, bufnr = bufnr, opts = opts })
        return id
      end,
      sign_unplace = function(group, opts)
        table.insert(ctx.sign_unplace_calls, { group = group, opts = opts })
      end,
      fnamemodify = function(path)
        return path
      end,
    },
    uv = {
      fs_stat = function(path)
        if ctx.fs_existing[path] then
          return { type = 'file' }
        end
        return nil
      end,
    },
    json = {
      encode = function(tbl)
        ctx.last_encoded = tbl
        local parts = {}
        for key, value in pairs(tbl) do
          table.sort(value)
          table.insert(parts, string.format('"%s":[%s]', key, table.concat(value, ',')))
        end
        table.sort(parts)
        return '{' .. table.concat(parts, ',') .. '}'
      end,
    },
  }

  vim_stub.api = {
    nvim_create_autocmd = function() end,
    nvim_create_augroup = function() return 1 end,
    nvim_buf_is_loaded = function()
      return true
    end,
    nvim_buf_get_name = function()
      return ctx.buffer_name
    end,
    nvim_get_current_buf = function()
      return ctx.bufnr
    end,
    nvim_win_get_cursor = function()
      return { ctx.cursor_line, 0 }
    end,
  }

  local bo_store = {}
  vim_stub.bo = setmetatable({}, {
    __index = function(_, key)
      if not bo_store[key] then
        bo_store[key] = { buftype = '', filetype = 'python' }
      end
      return bo_store[key]
    end,
    __newindex = function(_, key, value)
      bo_store[key] = value
    end,
  })

  _G.vim = vim_stub
  return prev_vim
end

local function fresh_breakpoints()
  local ctx = {
    temp_index = 0,
    file_writes = {},
    sign_place_calls = {},
    sign_unplace_calls = {},
    fs_existing = {},
    buffer_name = '/workspace/example.py',
    bufnr = 5,
    cursor_line = 3,
  }

  package.loaded['ipybridge.utils'] = nil
  package.preload['ipybridge.utils'] = function()
    return {
      py_quote_single = function(path)
        ctx.quoted_path = path
        return path
      end,
    }
  end

  package.loaded['ipybridge.breakpoints'] = nil
  local prev_vim = stub_vim(ctx)
  local mod = require('ipybridge.breakpoints')
  _G.vim = prev_vim

  return mod, ctx
end

it('sync_with_kernel uses exec and fallback', function()
  local breakpoints, ctx = fresh_breakpoints()
  local fallback_called = false
  local exec_calls = {}
  breakpoints.attach_session({
    send = function(payload)
      ctx.term_payload = payload
    end,
    exec = function(payload, opts)
      table.insert(exec_calls, { payload = payload, opts = opts })
      if opts and opts.fallback then
        fallback_called = true
        opts.fallback()
      end
    end,
    is_term_open = function()
      return true
    end,
  })

  assert(exec_calls[1], 'exec should be invoked during attach_session')
  assert(exec_calls[1].payload:match("_myipy_register_breakpoints_file"), 'expected register breakpoints command')
  assert(fallback_called == true, 'fallback should be triggered')
  assert(ctx.term_payload and ctx.term_payload:match("_myipy_register_breakpoints_file"), 'fallback send should reach terminal')
  assert(ctx.quoted_path:match('breakpoints'), 'path should be normalised')
end)

it('toggle_current_line tracks lines and writes file', function()
  local breakpoints, ctx = fresh_breakpoints()
  breakpoints.attach_session({
    send = function() end,
    exec = function() end,
    is_term_open = function()
      return true
    end,
  })

  breakpoints.toggle_current_line()
  local encoded = ctx.last_encoded[ctx.buffer_name]
  assert(encoded and encoded[1] == 3, 'expected encoded payload to include current line')
  assert(ctx.sign_place_calls[1] and ctx.sign_place_calls[1].opts.lnum == 3, 'sign should be placed at current line')
  assert(ctx.file_writes[#ctx.file_writes].lines[1]:find('%['), 'file should be written with encoded payload')

  breakpoints.toggle_current_line()
  assert(ctx.last_encoded and next(ctx.last_encoded) == nil, 'encoded payload should be empty after removing breakpoint')
  assert(ctx.file_writes[#ctx.file_writes].lines[1] == '{}', 'second write should persist empty map')
end)

local all_ok = true
for _, result in ipairs(results) do
  if not result.ok then
    all_ok = false
    break
  end
end

if not all_ok then
  error('breakpoints_spec failed')
end

return true
