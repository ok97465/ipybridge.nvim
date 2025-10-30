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
    defer_fn = function(cb, _) if type(cb) == 'function' then cb() end end,
    o = { columns = 120, lines = 40 },
    keymap = {
      set = function() end,
    },
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
      prompt_setprompt = function() end,
      prompt_setcallback = function() end,
      prompt_setinterrupt = function() end,
      prompt_settext = function(_, text)
        table.insert(ctx.prompt_text_calls, text)
        ctx.prompt_buffer_lines = { text }
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
          local entry_parts = {}
          if type(value) == 'table' then
            for _, entry in ipairs(value) do
              if type(entry) == 'table' then
                if entry.condition then
                  table.insert(entry_parts, string.format('{"line":%d,"condition":"%s"}', entry.line or 0, entry.condition))
                else
                  table.insert(entry_parts, string.format('{"line":%d}', entry.line or 0))
                end
              else
                table.insert(entry_parts, tostring(entry))
              end
            end
          end
          table.insert(parts, string.format('"%s":[%s]', key, table.concat(entry_parts, ',')))
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
    nvim_buf_is_valid = function()
      return true
    end,
    nvim_buf_get_lines = function(_, start_idx, end_idx, _)
      local lines = ctx.prompt_buffer_lines or { '' }
      local result = {}
      local first = math.max(1, start_idx + 1)
      local last = end_idx
      if end_idx < 0 or end_idx > #lines then
        last = #lines
      end
      for i = first, last do
        result[#result + 1] = lines[i] or ''
      end
      if #result == 0 then
        result[1] = lines[1] or ''
      end
      return result
    end,
    nvim_buf_set_lines = function(_, start_idx, end_idx, _, new_lines)
      ctx.prompt_buffer_lines = {}
      for _, line in ipairs(new_lines or {}) do
        ctx.prompt_buffer_lines[#ctx.prompt_buffer_lines + 1] = line
      end
      if #ctx.prompt_buffer_lines == 0 then
        ctx.prompt_buffer_lines = { '' }
      end
    end,
    nvim_feedkeys = function(keys, _, _)
      local text = type(keys) == 'string' and keys or ''
      local ctrl_u = string.char(21)
      if text:find(ctrl_u, 1, true) then
        text = text:gsub(ctrl_u, '')
        ctx.prompt_buffer_lines = { '' }
      end
      ctx.prompt_buffer_lines = ctx.prompt_buffer_lines or { '' }
      local current = ctx.prompt_buffer_lines[1] or ''
      ctx.prompt_buffer_lines[1] = current .. text
    end,
    nvim_replace_termcodes = function(keys)
      local text = type(keys) == 'string' and keys or ''
      local ctrl_u = string.char(21)
      return text:gsub('<C%-u>', ctrl_u)
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
    prompt_text_calls = {},
    prompt_buffer_lines = { '' },
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

it('sync_with_kernel uses exec callbacks', function()
  local breakpoints, ctx = fresh_breakpoints()
  local exec_calls = {}
  local captured_opts
  breakpoints.attach_session({
    exec = function(payload, opts)
      table.insert(exec_calls, payload)
      captured_opts = opts
    end,
    is_term_open = function()
      return true
    end,
  })

  assert(exec_calls[1], 'exec should be invoked during attach_session')
  assert(exec_calls[1]:match("_myipy_register_breakpoints_file"), 'expected register breakpoints command')
  assert(captured_opts and type(captured_opts.on_error) == 'function', 'on_error callback should be provided')
  assert(captured_opts and type(captured_opts.on_success) == 'function', 'on_success callback should be provided')
  assert(not captured_opts or captured_opts.fallback == nil, 'fallback should not be provided')
  assert(ctx.term_payload == nil, 'terminal fallback should not be triggered')
  assert(ctx.quoted_path:match('breakpoints'), 'path should be normalised')

  captured_opts.on_error('failure')
  breakpoints.sync_with_kernel()
  assert(#exec_calls == 2, 'sync should retry after error')
end)

it('set_conditional_current_line stores condition and removes breakpoint on blank input', function()
  local breakpoints, ctx = fresh_breakpoints()
  local inputs = { 'x > 1', '' }
  local index = 1
  local seen_opts = {}
  breakpoints._set_condition_input(function(opts, cb)
    table.insert(seen_opts, opts)
    local value = inputs[index]
    index = index + 1
    cb(value)
  end)

  breakpoints.set_conditional_current_line()
  assert(seen_opts[1] and seen_opts[1].default == '', 'initial prompt should start empty')
  local first = ctx.last_encoded[ctx.buffer_name]
  assert(first and first[1] and first[1].line == 3, 'conditional breakpoint should target current line')
  assert(first[1].condition == 'x > 1', 'condition should be stored in payload')
  assert(ctx.sign_place_calls[#ctx.sign_place_calls] and ctx.sign_place_calls[#ctx.sign_place_calls].name == 'IpybridgeConditionalBreakpoint', 'conditional sign should be used')
  assert(seen_opts[2] == nil, 'second prompt should not be scheduled yet')

  breakpoints.set_conditional_current_line()
  assert(seen_opts[2] and seen_opts[2].default == 'x > 1', 'second prompt should prefill existing condition')
  local second_payload = ctx.last_encoded
  assert(second_payload and next(second_payload) == nil, 'blank input should remove breakpoint entry')
  assert(ctx.file_writes[#ctx.file_writes].lines[1] == '{}', 'blank condition should write empty payload')
  assert(ctx.prompt_text_calls[1] == 'x > 1', 'existing condition should be inserted into prompt buffer')
  assert(#ctx.sign_place_calls == 1, 'no new sign should be placed when removing breakpoint')
  local last_unplace = ctx.sign_unplace_calls[#ctx.sign_unplace_calls]
  assert(last_unplace and last_unplace.opts and last_unplace.opts.buffer == ctx.bufnr, 'signs should be cleared on removal')

  breakpoints._set_condition_input(nil)
end)

it('toggle_current_line tracks lines and writes file', function()
  local breakpoints, ctx = fresh_breakpoints()
  breakpoints.attach_session({
    exec = function() end,
    is_term_open = function()
      return true
    end,
  })

  breakpoints.toggle_current_line()
  local encoded = ctx.last_encoded[ctx.buffer_name]
  assert(encoded and encoded[1] and encoded[1].line == 3, 'expected encoded payload to include current line')
  assert(encoded[1] and encoded[1].condition == nil, 'unconditional breakpoint should not have a condition')
  assert(ctx.sign_place_calls[1] and ctx.sign_place_calls[1].opts.lnum == 3, 'sign should be placed at current line')
  assert(ctx.sign_place_calls[1] and ctx.sign_place_calls[1].name == 'IpybridgeBreakpoint', 'should use regular breakpoint sign')
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
