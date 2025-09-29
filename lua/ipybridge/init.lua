-- This plugin requires Neovim 0.11 or newer.
-- Fail fast on older versions to prevent undefined behavior.
if vim.fn.has('nvim-0.11') ~= 1 then
  error('ipybridge.nvim requires Neovim 0.11 or newer')
end

local vim = vim
local api = vim.api
local fn = vim.fn
local term_helper = require("ipybridge.term_ipy")
local dispatch = require("ipybridge.dispatch")
-- Refactored internal modules (utilities, keymaps, kernel manager)
local utils = require("ipybridge.utils")
local keymaps = require("ipybridge.keymaps")
local kernel = require("ipybridge.kernel")
local py_module = require("ipybridge.py_module")
local debug_scope = require("ipybridge.debug_scope")
local breakpoints = require("ipybridge.breakpoints")
local fs = vim.fs
local uv = vim.uv

-- Core state for the plugin. Comments are in English; see README for usage.
local M = {
  term_instance = nil,
  _helpers_sent = false,
  _conn_file = nil,
  _kernel_job = nil,
  _helpers_path = nil,
  _helpers_pending = false,
  _runcell_sent = false,
  _runcell_path = nil,
  _last_cwd_sent = nil,
  _debug_active = false,
  _latest_vars = {},
  _debug_locals_snapshot = nil,
  _debug_globals_snapshot = nil,
  _debug_scope = 'globals',
  _last_filters_signature = nil,
  _pending_exec = {},
  _helpers_waiters = {},
}
-- Cell markers must be exactly: start of line '#', one space, then at least '%%'.
-- Examples matched: '# %%', '# %% Import'. Examples NOT matched: '  # %%', '#%%'.
local CELL_PATTERN = [[^# %%\+]]
local CELL_RE = vim.regex(CELL_PATTERN)
local sanitize_scope = debug_scope.sanitize_scope

local function normalize_path(path)
  if not path or path == '' then return nil end
  local abs = fn.fnamemodify(path, ':p')
  if not abs or abs == '' then return nil end
  return abs:gsub("\\", "/")
end

local function get_debug_preview_payload(name)
  if not name or name == '' then
    return nil
  end
  local function lookup(scope_tbl)
    if type(scope_tbl) ~= 'table' then
      return nil
    end
    local entry = scope_tbl[name]
    if type(entry) == 'table' then
      local cache = entry._preview_cache
      if cache then
        return cache
      end
    end
    for _, item in pairs(scope_tbl) do
      if type(item) == 'table' then
        local children = item._preview_children
        if type(children) == 'table' then
          local payload = children[name]
          if payload then
            return payload
          end
        end
      end
    end
    return nil
  end
  local scopes = {}
  if type(M._debug_locals_snapshot) == 'table' and type(M._debug_locals_snapshot.__locals__) == 'table' then
    table.insert(scopes, M._debug_locals_snapshot.__locals__)
  end
  if type(M._debug_globals_snapshot) == 'table' then
    local gscope = M._debug_globals_snapshot.__globals__
    if type(gscope) == 'table' then
      table.insert(scopes, gscope)
    else
      table.insert(scopes, M._debug_globals_snapshot)
    end
  end
  if type(M._latest_vars) == 'table' then
    table.insert(scopes, M._latest_vars)
  end
  for _, scope in ipairs(scopes) do
    local payload = lookup(scope)
    if payload then
      return payload
    end
  end
  return nil
end

local queue_exec_request -- forward declaration for deferred ZMQ exec
local after_helpers      -- forward declaration for helper gating

---Toggle a breakpoint at the current cursor line for the active Python buffer.
function M.toggle_breakpoint()
  breakpoints.toggle_current_line()
end

M.config = {
	profile_name = "vim",
	startup_script = "import_in_console.py",
	startup_cmd = "\"import numpy as np;" ..
		"import matplotlib.pyplot as plt;" ..
		"from scipy.special import sindg, cosdg, tandg;" ..
		"from matplotlib.pyplot import plot, subplots, figure, hist;" ..
		"from numpy import (" ..
		"pi, deg2rad, rad2deg, unwrap, angle, zeros, array, ones, linspace, cumsum," ..
		"diff, arange, interp, conj, exp, sqrt, vstack, hstack, dot, cross, newaxis);" ..
		"from numpy import cos, sin, tan, arcsin, arccos, arctan;" ..
		"from numpy import amin, amax, argmin, argmax, mean;" ..
		"from numpy.linalg import svd, norm;" ..
		"from numpy.fft import fftshift, ifftshift, fft, ifft, fft2, ifft2;" ..
		"from numpy.random import randn, standard_normal, randint, choice, uniform;\"",
	sleep_ms_after_open = 1000,
	set_default_keymaps = true,
	viewer_max_rows = 30,
    viewer_max_cols = 20,
    var_repr_limit = 120,
    use_zmq = true,
    python_cmd = "python3",
    -- Matplotlib backend/ion control for the interactive console.
    -- Set to 'qt' | 'tk' | 'macosx' | 'inline' to use IPython magic,
    -- or a Matplotlib backend name like 'QtAgg' | 'TkAgg' | 'MacOSX'.
    matplotlib_backend = nil,
    -- Whether to enable interactive mode (plt.ion()) on startup.
    matplotlib_ion = true,
    -- Prefer Spyder-like runcell helper over sending raw lines
    prefer_runcell_magic = false,
    -- Save buffer before calling runcell to ensure the file content is current
    runcell_save_before_run = true,
    -- Save buffer before calling runfile to ensure the file content is current
    runfile_save_before_run = true,
    -- Save buffer before calling debugfile to ensure the file content is current
    debugfile_save_before_run = true,
    -- Working directory mode for executing run_cell/run_file: 'file' | 'pwd' | 'none'
    --  - 'file': cd to the current file's directory before executing
    --  - 'pwd' : cd to Neovim's current working directory before executing
    --  - 'none': do not change directory
    exec_cwd_mode = 'pwd',
    -- Console prompt/color options
    -- Use a rich prompt (colors, toolbar) by default; set true to simplify.
    simple_prompt = false,
    -- Optional color scheme for ZMQTerminalInteractiveShell (e.g., 'Linux', 'LightBG', 'NoColor').
    ipython_colors = 'Linux',
    -- Variable explorer: hide variables by exact name or type name (supports '*' suffix as prefix wildcard)
    hidden_var_names = { 'pi', 'newaxis', 'MODULE_B64' },
    hidden_type_names = { 'ZMQInteractiveShell', 'Axes', 'Figure', 'AxesSubplot' },
    -- ZMQ backend debug logs (Python client prints to stderr)
    zmq_debug = false,
    -- IPython autoreload: 1, 2, or 'disable' (default 2)
    --  - 1: Reload modules imported with %aimport
    --  - 2: Reload all modules (except those excluded)
    --  - 'disable': Do not configure autoreload
    autoreload = 2,
    -- How to send multi-line selections/cells to IPython.
    -- 'exec'  : send as hex-encoded Python and exec() it (robust, default)
    -- 'paste' : send as plain text using bracketed paste so the console shows
    --           the code exactly as if it was typed (Spyder-like echo).
    multiline_send_mode = 'paste',
    
}

local function get_start_line_cell(idx_seed)
    local lines = api.nvim_buf_get_lines(0, 0, idx_seed, false)
    for idx, line in vim.iter(lines):enumerate():rev() do
        local s, e = CELL_RE:match_str(line)
        if s ~= nil then
            return idx
        end
    end
    return 1
end

-- Return the last line index of the current cell
-- and whether there is a next cell following it.
---@param idx_offset number
---@return number, boolean
local function get_stop_line_cell(idx_offset)
    local n_lines = api.nvim_buf_line_count(0)
    local lines = api.nvim_buf_get_lines(0, idx_offset - 1, n_lines, false)
    for idx, line in vim.iter(lines):enumerate() do
        local s, e = CELL_RE:match_str(line)
        if s ~= nil then
            return idx + idx_offset - 1, true
        end
    end
    return n_lines, false
end

-- Quietly set IPython working directory according to config.
local function set_exec_cwd_for(file_path)
  if not M.is_open() then return end
  local mode = M.config.exec_cwd_mode or 'pwd'
  local dir = nil
  if mode == 'file' and file_path and #file_path > 0 then
    dir = fn.fnamemodify(file_path, ':p:h')
  elseif mode == 'pwd' then
    dir = fn.getcwd()
  else
    return
  end
  if not dir or #dir == 0 then return end
  if M._last_cwd_sent == dir then return end
  local safe = utils.py_quote_single(dir)
  -- Use IPython magic with quiet flag; avoid extra output
  M.term_instance:send(string.format("%%cd -q '%s'\n", safe))
  M._last_cwd_sent = dir
end

M.setup = function(config)
    if config ~= nil then
        vim.validate({
            profile_name = { config.profile_name, 's', true },
            startup_script = { config.startup_script, 's', true },
            startup_cmd = { config.startup_cmd, 's', true },
            sleep_ms_after_open = { config.sleep_ms_after_open, 'n', true },
            set_default_keymaps = { config.set_default_keymaps, 'b', true },
            viewer_max_rows = { config.viewer_max_rows, 'n', true },
            viewer_max_cols = { config.viewer_max_cols, 'n', true },
            var_repr_limit = { config.var_repr_limit, 'n', true },
            use_zmq = { config.use_zmq, 'b', true },
            python_cmd = { config.python_cmd, 's', true },
            debugfile_save_before_run = { config.debugfile_save_before_run, 'b', true },
        })
    end
    M.config = vim.tbl_deep_extend("force", M.config, config or {})

    breakpoints.ensure_support()

    if M.config.set_default_keymaps then
        M.apply_default_keymaps()
        -- Also apply to any already-open Python buffers
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(b) then
                local ft = (vim.bo[b] and vim.bo[b].filetype) or ""
                if ft == 'python' then
                    M.apply_buffer_keymaps(b)
                    breakpoints.refresh_signs(b)
                end
            end
        end
    end

    if M.is_open() then
        M._sync_var_filters()
    end
end

---Apply a set of sensible default keymaps.
M.apply_default_keymaps = function()
  keymaps.apply_defaults()
end

---Apply buffer-local keymaps for Python files.
---@param bufnr integer
M.apply_buffer_keymaps = function(bufnr)
  keymaps.apply_buffer(bufnr)
end

---Return whether the IPython terminal is currently open.
---@return boolean
M.is_open = function()
    return M.term_instance ~= nil and type(M.term_instance.job_id) == 'number' and M.term_instance.job_id > 0
end

---Open the IPython terminal split.
---@param go_back boolean|nil # if true, jump back to previous window after init
M.open = function(go_back, cb)
    local cwd = fn.getcwd()
    -- Ensure we have a kernel running and a connection file
    kernel.ensure(M.config.python_cmd, function(ok, conn_file)
        if not ok then
            vim.notify('ipybridge: failed to start Jupyter kernel', vim.log.levels.ERROR)
            if cb then cb(false) end
            return
        end
        -- Open jupyter console attached to this kernel
        local extra = ''
        if M.config.simple_prompt then extra = extra .. ' --simple-prompt' end
        local cmd_console = string.format("jupyter console --existing %s%s", conn_file, extra)
        local bp_file = breakpoints.get_file_path()
        local env = {
          IPYBRIDGE_CONSOLE_PATCH = '1',
          IPYBRIDGE_CONSOLE_PATCH_SILENT = '1',
        }
        if bp_file and #bp_file > 0 then
          env.IPYBRIDGE_BREAKPOINT_FILE = bp_file
        end
        local ok_py_path, py_module_path = pcall(py_module.path, 'bootstrap_helpers.py')
        if ok_py_path and type(py_module_path) == 'string' and #py_module_path > 0 then
            local py_root = vim.fs.dirname(py_module_path)
            if py_root and #py_root > 0 then
                local sep = vim.loop.os_uname().sysname == 'Windows_NT' and ';' or ':'
                local current = vim.loop.os_getenv('PYTHONPATH') or ''
                if current:find(py_root, 1, true) then
                    env.PYTHONPATH = current
                elseif current ~= '' then
                    env.PYTHONPATH = py_root .. sep .. current
                else
                    env.PYTHONPATH = py_root
                end
            end
        end
        M.term_instance = term_helper.TermIpy:new(cmd_console, cwd, {
            on_message = dispatch.handle,
            env = env,
        })
        -- Reset helper state and cached paths for new session
        M._helpers_sent = false
        M._helpers_pending = false
        if M._helpers_path then pcall(os.remove, M._helpers_path); M._helpers_path = nil end
        M._runcell_sent = false
        if M._runcell_path then pcall(os.remove, M._runcell_path); M._runcell_path = nil end
        M._last_cwd_sent = nil
        M._zmq_ready = false
        M._last_filters_signature = nil
        M._pending_exec = {}
        M._helpers_waiters = {}
        breakpoints.attach_session({
          send = function(payload)
            if type(payload) ~= 'string' or payload == '' then
              return
            end
            after_helpers(function(ok_helpers)
              if not ok_helpers then
                if M.term_instance then
                  M.term_instance:send(payload)
                end
                return
              end
              queue_exec_request(payload, {
                fallback = function()
                  if not M.term_instance then return end
                  M.term_instance:send(payload)
                end,
              })
            end)
          end,
          ensure_helpers = function()
            M._send_helpers_if_needed()
          end,
          is_term_open = M.is_open,
        })
        -- Start ZMQ backend for programmatic requests
        M.ensure_zmq(function(ok2)
            if not ok2 then
                vim.schedule(function()
                    vim.notify('ipybridge: failed to start ZMQ backend', vim.log.levels.WARN)
                end)
            end
        end)

        -- Terminal-buffer keymaps (terminal mode) for quick return to editor
        pcall(function()
            local buf = M.term_instance.buf_id
            vim.keymap.set('t', '<leader>iv', function()
                M.goto_vi()
            end, { buffer = buf, silent = true, desc = 'IPy: Back to editor' })
        end)
        -- Defer initial setup to avoid blocking UI while the terminal spins up.
        vim.defer_fn(function()
            if not M.is_open() then return end
            M._send_helpers_if_needed()
            breakpoints.sync_with_kernel()
            M._sync_var_filters()
            -- Enable interactive plotting and minimal numeric imports for convenience
            local cwd = fn.getcwd()
            local path_startup_script = fs.joinpath(cwd, M.config.startup_script)
            -- Ensure the IPython working directory matches Neovim's CWD (or file dir per config)
            -- This helps resolve package imports that rely on project root.
            -- Apply before running any startup scripts/imports.
            set_exec_cwd_for(fn.expand('%:p'))
            -- Ensure current CWD is at the very front of sys.path.
            -- Use a single-line statement to avoid IPython auto-indent issues.
            M.term_instance:send(
              "import sys, os; p=os.getcwd(); sys.path=[p]+[x for x in sys.path if x!=p]\n"
            )
            -- Configure Matplotlib backend before importing pyplot
            if M.config.matplotlib_backend and #tostring(M.config.matplotlib_backend) > 0 then
              local b = tostring(M.config.matplotlib_backend)
              if b == 'qt' or b == 'tk' or b == 'macosx' or b == 'inline' then
                -- Use IPython magic via API to avoid literal % in sent code
                local stmt = string.format("from IPython import get_ipython; ip=get_ipython();\nif ip is not None: ip.run_line_magic('matplotlib','%s')\n", b)
                M.term_instance:send(stmt)
              else
                -- Fallback to Matplotlib backend name
                local stmt = string.format("import matplotlib as _mpl; _mpl.use('%s')\n", b)
                M.term_instance:send(stmt)
              end
            end
            -- Configure IPython color scheme via %colors magic (portable across jupyter-console versions)
            if M.config.ipython_colors and #tostring(M.config.ipython_colors) > 0 then
              local c = tostring(M.config.ipython_colors)
              local stmt = string.format("from IPython import get_ipython; ip=get_ipython();\nif ip is not None: ip.run_line_magic('colors','%s')\n", c)
              M.term_instance:send(stmt)
            end
            -- Configure autoreload extension per user config (default: 2)
            do
              local ar = M.config.autoreload
              if ar == nil then ar = 2 end
              local mode = tostring(ar)
              if mode == '1' or mode == '2' then
                local stmt = string.format(
                  "from IPython import get_ipython; ip=get_ipython();\n" ..
                  "if ip is not None: ip.run_line_magic('load_ext','autoreload'); ip.run_line_magic('autoreload','%s')\n",
                  mode
                )
                M.term_instance:send(stmt)
              end
            end
            -- Optionally enable interactive mode
            if M.config.matplotlib_ion ~= false then
              M.term_instance:send("import matplotlib.pyplot as plt; plt.ion()\n")
            end
            if utils.file_exists(path_startup_script) then
              M.term_instance:send(utils.exec_file_stmt(path_startup_script))
            else
              -- Common numerics so user snippets like `array([...])` work
              M.term_instance:send("import numpy as np; from numpy import array\n")
            end
            -- Optionally seed runcell helpers for Spyder-like behavior
            if M.config.prefer_runcell_magic then
              M._ensure_runcell_helpers()
            end
            M.term_instance:scroll_to_bottom()
            if go_back == true then
                vim.cmd("wincmd p")
            end
            if cb then cb(true) end
        end, M.config.sleep_ms_after_open)
    end)
end

local function _helpers_py_code()
  local template = py_module.source('bootstrap_helpers.py')
  local module_b64 = py_module.base64('ipybridge_ns.py')
  return template:gsub('__MODULE_B64__', module_b64)
end

-- Define a Spyder-like runcell helper and register an IPython line magic.
local function _runcell_py_code()
  return require('ipybridge.exec_magics').build()
end

local function default_exec_fallback(code)
  if not M.term_instance then return end
  M.term_instance:send(code)
end

local function dispatch_exec_request(code, opts)
  opts = opts or {}
  local fallback = opts.fallback or function()
    default_exec_fallback(code)
  end
  local function handle_error(reason)
    if fallback then fallback(reason) end
    if opts.on_error then opts.on_error(reason) end
  end
  local ok, z = pcall(require, 'ipybridge.zmq_client')
  if not ok or not z then
    handle_error('zmq_client_unavailable')
    return
  end
  local dispatched = z.request('exec', { code = code }, function(msg)
    if msg and msg.ok then
      if opts.on_success then opts.on_success() end
    else
      local err = (msg and msg.error) or 'exec_failed'
      handle_error(err)
    end
  end)
  if not dispatched then
    handle_error('dispatch_failed')
  end
end

queue_exec_request = function(code, opts)
  opts = opts or {}
  if M._zmq_ready then
    dispatch_exec_request(code, opts)
    return
  end
  table.insert(M._pending_exec, { code = code, opts = opts })
  M.ensure_zmq(function(ok)
    if ok then
      M._flush_pending_exec()
    else
      M._fail_pending_exec('zmq_unavailable')
    end
  end)
end

function M._flush_pending_exec()
  if not M._zmq_ready then return end
  if not M._pending_exec or #M._pending_exec == 0 then return end
  local queue = M._pending_exec
  M._pending_exec = {}
  for _, entry in ipairs(queue) do
    dispatch_exec_request(entry.code, entry.opts or {})
  end
end

function M._fail_pending_exec(reason)
  if not M._pending_exec or #M._pending_exec == 0 then return end
  local queue = M._pending_exec
  M._pending_exec = {}
  for _, entry in ipairs(queue) do
    local opts = entry.opts or {}
    local fallback = opts.fallback
    if fallback then
      fallback(reason)
    else
      default_exec_fallback(entry.code)
    end
    if opts.on_error then opts.on_error(reason) end
  end
end

local function send_helpers_via_console(script)
  if not M.term_instance then return false end
  if not M._helpers_path then
    M._helpers_path = fn.tempname() .. '.myipy_helpers.py'
    local ok = pcall(fn.writefile, vim.split(script, "\n", { plain = true }), M._helpers_path)
    if not ok then
      M._helpers_path = nil
      return false
    end
  end
  M.term_instance:send(utils.exec_file_stmt(M._helpers_path))
  return true
end

local function run_helper_waiters(success)
  if not M._helpers_waiters or #M._helpers_waiters == 0 then return end
  local waiters = M._helpers_waiters
  M._helpers_waiters = {}
  for _, cb in ipairs(waiters) do
    local ok, err = pcall(cb, success)
    if not ok then
      vim.schedule(function()
        vim.notify('ipybridge: helper callback failed: ' .. tostring(err), vim.log.levels.WARN)
      end)
    end
  end
end

after_helpers = function(cb)
  if M._helpers_sent then
    local ok, err = pcall(cb, true)
    if not ok then
      vim.schedule(function()
        vim.notify('ipybridge: helper callback failed: ' .. tostring(err), vim.log.levels.WARN)
      end)
    end
    return
  end
  table.insert(M._helpers_waiters, cb)
  M._send_helpers_if_needed()
end

function M._ensure_runcell_helpers()
  if M._runcell_sent then return end
  if not M.is_open() then return end
  local code = _runcell_py_code()
  local function fallback()
    if M._runcell_sent then return end
    if not M.term_instance then return end
    if not M._runcell_path then
      M._runcell_path = fn.tempname() .. '.myipy_runcell.py'
      pcall(fn.writefile, vim.split(code, "\n", { plain = true }), M._runcell_path)
    end
    M.term_instance:send(utils.exec_file_stmt(M._runcell_path))
    M._runcell_sent = true
  end
  after_helpers(function(ok_helpers)
    if not ok_helpers then
      fallback()
      return
    end
    queue_exec_request(code, {
      on_success = function()
        M._runcell_sent = true
      end,
      on_error = fallback,
      fallback = fallback,
    })
  end)
end

function M._send_helpers_if_needed()
  if M._helpers_sent or M._helpers_pending then return end
  if not M.is_open() then return end
  local code = _helpers_py_code()
  M._helpers_pending = true
  local handled = false
  local function finalize_ok()
    handled = true
    M._helpers_pending = false
    M._helpers_sent = true
    run_helper_waiters(true)
  end
  local function do_fallback()
    if handled then return end
    handled = true
    M._helpers_pending = false
    if M._helpers_sent then return end
    local ok_console = send_helpers_via_console(code)
    if ok_console then
      M._helpers_sent = true
      run_helper_waiters(true)
    else
      run_helper_waiters(false)
      vim.schedule(function()
        vim.notify('ipybridge: failed to load helper script', vim.log.levels.WARN)
      end)
    end
  end
  queue_exec_request(code, {
    on_success = finalize_ok,
    on_error = do_fallback,
    fallback = do_fallback,
  })
end

local function encode_json(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok or not encoded then
    return '[]'
  end
  return encoded
end

function M._sync_var_filters()
  if not M.is_open() then return end
  M._send_helpers_if_needed()
  local names = M.config.hidden_var_names
  if type(names) ~= 'table' then names = {} end
  local types = M.config.hidden_type_names
  if type(types) ~= 'table' then types = {} end
  local max_repr = tonumber(M.config.var_repr_limit) or 120
  if max_repr <= 0 then max_repr = 120 end
  local enable_logs = M.config.zmq_debug and true or false
  local names_json = encode_json(names)
  local types_json = encode_json(types)
  local signature = table.concat({ names_json, '\0', types_json, '\0', tostring(max_repr), '\0', enable_logs and '1' or '0' })
  if M._last_filters_signature == signature then
    return
  end
  local template = py_module.source('sync_filters.py')
  local script = template
    :gsub('__NAMES_JSON__', names_json)
    :gsub('__TYPES_JSON__', types_json)
    :gsub('__MAX_REPR__', tostring(max_repr))
    :gsub('__ENABLE_LOGS__', enable_logs and 'True' or 'False')
  after_helpers(function(ok_helpers)
    if not ok_helpers then
      local payload = utils.send_exec_block(script)
      if M.term_instance then
        M.term_instance:send(payload)
      end
      return
    end
    queue_exec_request(script, {
      fallback = function()
        local payload = utils.send_exec_block(script)
        if M.term_instance then
          M.term_instance:send(payload)
        end
      end,
    })
  end)
  M._last_filters_signature = signature
end

local function current_debug_scope(prefer_locals)
  return debug_scope.resolve_scope(prefer_locals, M._debug_locals_snapshot, M._debug_globals_snapshot)
end

function M._digest_vars_snapshot(snapshot)
  if type(snapshot) ~= 'table' then
    M._latest_vars = {}
    return M._latest_vars
  end
  local has_debug_meta = snapshot.__scoped__ ~= nil or snapshot.__locals__ ~= nil or snapshot.__globals__ ~= nil
  if not has_debug_meta then
    M._debug_locals_snapshot = nil
    M._debug_globals_snapshot = nil
    M._latest_vars = sanitize_scope(snapshot)
    return M._latest_vars
  end
  local scoped_flag = snapshot.__scoped__
  local locals_scope = snapshot.__locals__
  local globals_scope = snapshot.__globals__
  if scoped_flag == true or (type(locals_scope) == 'table' and next(locals_scope)) then
    M._debug_locals_snapshot = snapshot
  end
  if scoped_flag == false or type(globals_scope) == 'table' or (not scoped_flag and snapshot.__locals__ == nil) then
    M._debug_globals_snapshot = snapshot
  end
  local prefer_locals = (M._debug_scope == 'locals')
  M._latest_vars = current_debug_scope(prefer_locals)
  return M._latest_vars
end

function M._update_latest_vars(data)
  return M._digest_vars_snapshot(data)
end

-- Ensure a standalone Jupyter kernel is running and return its connection file.
function M._ensure_kernel(cb)
  if M._kernel_job and M._conn_file and uv.fs_stat(M._conn_file) then
    if cb then cb(true, M._conn_file) end
    return
  end
  local cf = fn.tempname() .. '.json'
  local cmd = { M.config.python_cmd or 'python3', '-m', 'ipykernel_launcher', '-f', cf }
  local job = fn.jobstart(cmd, {
    on_exit = function() M._kernel_job = nil end,
  })
  if job <= 0 then
    if cb then cb(false) end
    return
  end
  M._kernel_job = job
  M._conn_file = cf
  local timer = uv.new_timer()
  local start = uv.now()
  local function tick()
    if (uv.now() - start) > 5000 then
      pcall(timer.stop, timer); pcall(timer.close, timer)
      if cb then cb(false) end
      return
    end
    local st = uv.fs_stat(cf)
    if st and st.type == 'file' and st.size and st.size > 0 then
      pcall(timer.stop, timer); pcall(timer.close, timer)
      if cb then cb(true, cf) end
    end
  end
  timer:start(50, 100, vim.schedule_wrap(tick))
end

-- Request the kernel connection file path once and cache it.
function M._ensure_conn_file(cb)
  -- Delegate to kernel manager: it owns the lifecycle of the kernel process.
  kernel.ensure_conn_file(M.config.python_cmd, cb)
end

---Close the IPython terminal if running.
M.close = function()
	if M.is_open() then
		fn.jobstop(M.term_instance.job_id)
	end
    M._zmq_ready = false
    pcall(function() require('ipybridge.zmq_client').stop() end)
    -- Stop the background kernel process
    pcall(kernel.stop)
    if M._helpers_path then
        pcall(os.remove, M._helpers_path)
        M._helpers_path = nil
    end
    M._helpers_pending = false
    M._helpers_sent = false
    if M._runcell_path then
        pcall(os.remove, M._runcell_path)
        M._runcell_path = nil
    end
    breakpoints.on_session_close()
    M._last_cwd_sent = nil
    M._latest_vars = nil
    M._pending_exec = {}
    M._helpers_waiters = {}
end

---Toggle the IPython terminal split.
M.toggle = function()
	if M.is_open() then
		M.close()
	else
		M.open(false, function(ok)
			if ok and M.term_instance then
				M.term_instance:startinsert()
			end
		end)
	end
end

---Jump to the IPython terminal split and enter insert mode.
M.goto_ipy = function()
	if M.term_instance and api.nvim_win_get_buf(0) == M.term_instance.buf_id then
		return
	end
	local function focus()
		if not M.term_instance then return end
		M.term_instance:show()
		api.nvim_set_current_win(M.term_instance.win_id)
		M.term_instance:scroll_to_bottom()
		M.term_instance:startinsert()
	end
	if not M.is_open() then
		M.open(false, function(ok)
			if ok then focus() end
		end)
	else
		focus()
	end
end

---Return focus from IPython split to previous window.
M.goto_vi = function()
    local curbuf = api.nvim_win_get_buf(0)
    local bt = vim.bo[curbuf] and vim.bo[curbuf].buftype or ''
    -- If we're in any terminal buffer, leave terminal-mode and jump back.
    if bt == 'terminal' then
        vim.cmd('stopinsert!')
        vim.cmd('wincmd p')
        return
    end
    -- Fallback: handle explicitly for our IPython terminal buffer if matched.
    if M.term_instance and curbuf == M.term_instance.buf_id then
        M.term_instance:stopinsert()
        vim.cmd('wincmd p')
    end
end

---Run the current file in IPython via %run.
M.run_file = function()
	local abs_path = fn.expand('%:p')
	-- Save buffer before run if requested
	if vim.bo.modified and M.config.runfile_save_before_run ~= false then
		pcall(vim.cmd, 'write')
	end
	local function after()
		if not M.is_open() then return end
		if M.config.prefer_runcell_magic then
			-- Use runfile helper with optional cwd argument; avoid global %cd
			M._ensure_runcell_helpers()
			local cwd_arg = nil
			local mode = M.config.exec_cwd_mode or 'pwd'
			if mode == 'file' then
				cwd_arg = fn.fnamemodify(abs_path, ':p:h')
			elseif mode == 'pwd' then
				cwd_arg = fn.getcwd()
			end
			local safe = utils.py_quote_single(abs_path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = utils.py_quote_single(cwd_arg)
				M.term_instance:send(string.format("runfile('%s','%s')\n", safe, safecwd))
			else
				M.term_instance:send(string.format("runfile('%s')\n", safe))
			end
		else
			-- Adjust working directory as configured and use %run
			set_exec_cwd_for(abs_path)
			local safe = utils.py_quote_double(abs_path)
			M.term_instance:send(string.format("%%run \"%s\"\n", safe))
		end
		M._debug_active = false
	end
	if not M.is_open() then
		M.open(true, function(ok) if ok then after() end end)
	else
		after()
	end
end

---Run the current file under IPython debugger via %debugfile.
M.debug_file = function()
	local abs_path = fn.expand('%:p')
	if vim.bo.modified and M.config.debugfile_save_before_run ~= false then
		pcall(vim.cmd, 'write')
	end
	local function after()
		if not M.is_open() then return end
		M._ensure_runcell_helpers()
		M._send_helpers_if_needed()
		breakpoints.push()
		M.term_instance:send("_myipy_reset_debug_baseline()\n")
		local cwd_arg = nil
		local mode = M.config.exec_cwd_mode or 'pwd'
		if mode == 'file' then
			cwd_arg = fn.fnamemodify(abs_path, ':p:h')
		elseif mode == 'pwd' then
			cwd_arg = fn.getcwd()
		end
		local safe = utils.py_quote_single(abs_path)
		if cwd_arg and #cwd_arg > 0 then
			local safecwd = utils.py_quote_single(cwd_arg)
			M.term_instance:send(string.format("debugfile('%s','%s')\n", safe, safecwd))
		else
			M.term_instance:send(string.format("debugfile('%s')\n", safe))
		end
		local was_debug = M._debug_active
		M._debug_active = true
		if not was_debug then
			M._sync_var_filters()
		end
	end
	if not M.is_open() then
		M.open(true, function(ok) if ok then after() end end)
	else
		after()
	end
end

---Send lines [line_start, line_stop) to IPython.
---@param line_start integer
---@param line_stop integer
M.send_lines = function(line_start, line_stop)
	local tb_lines = api.nvim_buf_get_lines(0, line_start, line_stop, false)
	if not tb_lines or #tb_lines == 0 then return end

	M._debug_active = false

  local function do_send()
    if not M.is_open() then return end
    -- Choose how to deliver multi-line code to IPython.
    -- 'exec' ensures reliability across terminals; 'paste' mirrors typed input.
    local mode = tostring(M.config.multiline_send_mode or 'exec')
    if mode == 'paste' then
      -- Use bracketed paste so IPython displays the pasted block with prompts.
      local payload = utils.paste_block(tb_lines)
      M.term_instance:send(payload)
    else
      -- Default: ship as hex-encoded Python and execute via exec().
      local block = table.concat(tb_lines, "\n") .. "\n"
      local payload = utils.send_exec_block(block)
      M.term_instance:send(payload)
    end
  end

	if not M.is_open() then
		M.open(true, function(ok) if ok then do_send() end end)
	else
		do_send()
	end
end

---Send the current visual selection (linewise) to IPython.
M.run_lines = function()
	local line_start0, line_end_excl0 = utils.selection_line_range()
	if not line_start0 then return end
	M.send_lines(line_start0, line_end_excl0)
end

---Send the current line and move cursor down one line.
M.run_line = function()
	local n_lines = api.nvim_buf_line_count(0)
	local line = api.nvim_get_current_line()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]

	local function after()
		if not M.is_open() then return end
		M.term_instance:send(line .. "\n")
		if idx_line_cursor < n_lines then
			api.nvim_win_set_cursor(0, { idx_line_cursor + 1, 0 })
		end
		M._debug_active = false
	end

	if not M.is_open() then
		M.open(true, function(ok) if ok then after() end end)
	else
		after()
	end
end

---Send an arbitrary command string to IPython.
---@param cmd string
M.run_cmd = function(cmd)
	local function after()
		if not M.is_open() then return end
		M.term_instance:send(cmd .. "\n")
	end
	if not M.is_open() then
		M.open(true, function(ok) if ok then after() end end)
	else
		after()
	end
end

local function send_debug_command(cmd, opts)
  if not M._debug_active then
    vim.notify('ipybridge: Debugger is not active', vim.log.levels.WARN)
    return
  end
  if not M.is_open() then
    vim.notify('ipybridge: IPython terminal is not open', vim.log.levels.WARN)
    return
  end
  M.term_instance:send(cmd .. '\n')
  if opts and opts.deactivate then
    M._debug_active = false
  end
end

---Debugger step over (F10 equivalent).
M.debug_step_over = function()
  send_debug_command('!next')
end

---Debugger step into (F11 equivalent).
M.debug_step_into = function()
  send_debug_command('!step')
end

---Debugger continue (F12 equivalent).
M.debug_continue = function()
  send_debug_command('!continue', { deactivate = true })
end

local function clamp_cursor_line(bufnr, line)
  local max_line = api.nvim_buf_line_count(bufnr)
  if line < 1 then
    return 1
  end
  if line > max_line then
    return max_line
  end
  return line
end

local function calc_column_from_source(source)
  if type(source) ~= 'string' or source == '' then
    return 0
  end
  local first = source:find('%S')
  if not first then
    return 0
  end
  return first - 1
end

---Handle debug location payload emitted from the embedded debugger.
---@param info table
function M.on_debug_location(info)
  if type(info) ~= 'table' then
    return
  end
  local file = info.file or info.filename
  local line = info.line
  if not file or not line then
    return
  end
  if type(line) ~= 'number' then
    line = tonumber(line)
  end
  if not line then
    return
  end
  local abs = normalize_path(file)
  if not abs then
    return
  end
  local bufnr = fn.bufadd(abs)
  if bufnr <= 0 then
    return
  end
  fn.bufload(bufnr)
  line = clamp_cursor_line(bufnr, line)
  local col = calc_column_from_source(info.source)
  local target_win = nil
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
      target_win = win
      break
    end
  end
  if not target_win then
    target_win = api.nvim_get_current_win()
    if not api.nvim_win_is_valid(target_win) then
      return
    end
    if api.nvim_win_get_buf(target_win) ~= bufnr then
      pcall(api.nvim_win_set_buf, target_win, bufnr)
    end
  end
  api.nvim_win_call(target_win, function()
    pcall(api.nvim_win_set_cursor, target_win, { line, col })
    pcall(vim.cmd, 'normal! zv')
    pcall(vim.cmd, 'normal! zz')
  end)
  local was_debug = M._debug_active
  M._debug_active = true
  if not was_debug then
    M._sync_var_filters()
  end
  local func_name = info['function'] or info.func
  if type(func_name) == 'string' and func_name ~= '' and func_name ~= '<module>' then
    M._debug_scope = 'locals'
  else
    M._debug_scope = 'globals'
  end
  if M._debug_active then
    M._latest_vars = current_debug_scope(M._debug_scope == 'locals')
    local ok, vx = pcall(require, 'ipybridge.var_explorer')
    if ok and vx and vx.on_vars then
      vx.on_vars(M._latest_vars)
    end
  end
end

-- Public: open the variable explorer window and refresh data.
M.var_explorer_open = function()
  require('ipybridge.var_explorer').open()
  if M._debug_active then
    if M._latest_vars then
      local ok, vx = pcall(require, 'ipybridge.var_explorer')
      if ok and vx and vx.on_vars then
        vx.on_vars(M._latest_vars)
      end
    end
    return
  end
  M.request_vars()
end

-- Public: refresh variable list.
M.var_explorer_refresh = function()
  if M._debug_active then
    local ok, vx = pcall(require, 'ipybridge.var_explorer')
    if ok and vx and vx.on_vars and M._latest_vars then
      vx.on_vars(M._latest_vars)
    end
    return
  end
  M.request_vars()
end

-- Internal: request variable list from kernel.
function M.request_vars()
  M._sync_var_filters()
  if M._debug_active then
    return
  end
  if M.config.use_zmq and M._zmq_ready then
    local z = require('ipybridge.zmq_client')
    local max_repr = tonumber(M.config.var_repr_limit) or 120
    local ok_req = z.request('vars', {
      max_repr = max_repr,
      hide_names = M.config.hidden_var_names,
      hide_types = M.config.hidden_type_names,
    }, function(msg)
      if msg and msg.ok and msg.tag == 'vars' then
        local ok, vx = pcall(require, 'ipybridge.var_explorer')
        if ok and vx and vx.on_vars then
          vim.schedule(function()
            vx.on_vars(msg.data or {})
          end)
        end
      else
        vim.schedule(function()
          vim.notify('ipybridge: ZMQ vars request failed', vim.log.levels.WARN)
        end)
      end
    end)
    if not ok_req then
      vim.notify('ipybridge: ZMQ request send failed', vim.log.levels.WARN)
    end
    return
  end
  -- If ZMQ not ready, attempt to prepare once; do not fall back to typing helper calls.
  M.ensure_zmq(function(ok)
    if ok then
      M.request_vars()
    else
      vim.notify('ipybridge: ZMQ backend not available; vars unavailable', vim.log.levels.WARN)
    end
  end)
end

-- Internal: request preview for a variable name from kernel.
function M.request_preview(name, opts)
  if not name or #name == 0 then return end
  opts = opts or {}
  local row_offset = tonumber(opts.row_offset) or 0
  local col_offset = tonumber(opts.col_offset) or 0
  if row_offset < 0 then row_offset = 0 end
  if col_offset < 0 then col_offset = 0 end
  local max_rows = tonumber(M.config.viewer_max_rows) or 30
  local max_cols = tonumber(M.config.viewer_max_cols) or 20
  local debug_mode = M._debug_active == true
  if debug_mode then
    local use_cache = (row_offset == 0 and col_offset == 0)
    local payload = nil
    if use_cache then
      payload = get_debug_preview_payload(name)
      if type(payload) == 'table' then
        payload.row_offset = payload.row_offset or 0
        payload.col_offset = payload.col_offset or 0
      end
    end
    if payload then
      vim.schedule(function()
        local ok, dv = pcall(require, 'ipybridge.data_viewer')
        if ok and dv and dv.on_preview then
          dv.on_preview(payload)
        end
      end)
      return
    end
    if not M.config.use_zmq then
      vim.schedule(function()
        local ok, dv = pcall(require, 'ipybridge.data_viewer')
        if ok and dv and dv.on_preview then
          dv.on_preview({ name = name, error = 'ZMQ backend disabled for debug preview' })
        end
      end)
      return
    end
    local function dispatch_response(msg)
      if msg and msg.ok and msg.tag == 'preview' then
        local ok, dv = pcall(require, 'ipybridge.data_viewer')
        if ok and dv and dv.on_preview then
          vim.schedule(function()
            dv.on_preview(msg.data or {})
          end)
        end
        return
      end
      vim.schedule(function()
        local ok, dv = pcall(require, 'ipybridge.data_viewer')
        if ok and dv and dv.on_preview then
          dv.on_preview({ name = name, error = 'Debug preview request failed' })
        end
      end)
      if msg and msg.error then
        vim.notify('ipybridge: ZMQ debug preview failed - ' .. tostring(msg.error), vim.log.levels.WARN)
      else
        vim.notify('ipybridge: ZMQ debug preview failed', vim.log.levels.WARN)
      end
    end
    local function send_debug_request()
      local z = require('ipybridge.zmq_client')
      local payload_dbg = {
        name = name,
        max_rows = max_rows,
        max_cols = max_cols,
        debug = true,
        row_offset = row_offset,
        col_offset = col_offset,
      }
      local ok_req = z.request('preview', payload_dbg, dispatch_response)
      if not ok_req then
        vim.schedule(function()
          local ok, dv = pcall(require, 'ipybridge.data_viewer')
          if ok and dv and dv.on_preview then
            dv.on_preview({ name = name, error = 'Failed to send debug preview request' })
          end
        end)
        vim.notify('ipybridge: failed to send ZMQ debug preview request', vim.log.levels.WARN)
      end
    end
    if M._zmq_ready then
      send_debug_request()
    else
      M.ensure_zmq(function(ok)
        if ok then
          send_debug_request()
        else
          vim.schedule(function()
            local ok_mod, dv = pcall(require, 'ipybridge.data_viewer')
            if ok_mod and dv and dv.on_preview then
              dv.on_preview({ name = name, error = 'ZMQ backend unavailable in debug' })
            end
          end)
          vim.notify('ipybridge: ZMQ backend not available; debug preview unavailable', vim.log.levels.WARN)
        end
      end)
    end
    return
  else
    M._sync_var_filters()
  end
  if M.config.use_zmq and M._zmq_ready then
    local z = require('ipybridge.zmq_client')
    local payload = {
      name = name,
      max_rows = max_rows,
      max_cols = max_cols,
      row_offset = row_offset,
      col_offset = col_offset,
    }
    local ok_req = z.request('preview', payload, function(msg)
      if msg and msg.ok and msg.tag == 'preview' then
        local ok, dv = pcall(require, 'ipybridge.data_viewer')
        if ok and dv and dv.on_preview then
          vim.schedule(function()
            dv.on_preview(msg.data or {})
          end)
        end
      else
        vim.schedule(function()
          vim.notify('ipybridge: ZMQ preview request failed', vim.log.levels.WARN)
        end)
      end
    end)
    if not ok_req then
      vim.notify('ipybridge: ZMQ request send failed', vim.log.levels.WARN)
    end
    return
  end
  -- Ensure ZMQ then retry once; do not fall back to typing helper calls.
  M.ensure_zmq(function(ok)
    if ok then
      M.request_preview(name, opts)
    else
      vim.notify('ipybridge: ZMQ backend not available; preview unavailable', vim.log.levels.WARN)
    end
  end)
end

-- Ensure ZMQ client: fetch connection file and spawn backend.
function M.ensure_zmq(cb)
  if not M.config.use_zmq then
    M._fail_pending_exec('zmq_disabled')
    if cb then cb(false) end
    return
  end
  if M._zmq_ready then
    M._flush_pending_exec()
    if cb then cb(true) end
    return
  end
  M._ensure_conn_file(function(ok, conn_file)
    if not ok or not conn_file then
      M._fail_pending_exec('conn_file_unavailable')
      if cb then cb(false) end
      return
    end
    local z = require('ipybridge.zmq_client')
    -- Resolve backend path relative to repo root: ../../ -> python/myipy_kernel_client.py
    local this = debug.getinfo(1, 'S').source:sub(2)
    local plugin_dir = fn.fnamemodify(this, ':h')           -- /repo/lua/ipybridge
    local repo_root = fn.fnamemodify(plugin_dir, ':h:h')     -- /repo
    local backend = repo_root .. '/python/myipy_kernel_client.py'
    local ok_start = z.start(M.config.python_cmd, conn_file, backend, M.config.zmq_debug)
    if not ok_start then
      M._fail_pending_exec('zmq_start_failed')
      if cb then cb(false) end
      return
    end
    -- Probe readiness with a ping
    local tried = 0
    local function try_ping()
      tried = tried + 1
      if tried > 20 then
        M._fail_pending_exec('zmq_ping_timeout')
        if cb then cb(false) end
        return
      end
      local sent = z.request('ping', {}, function(msg)
        if msg and msg.ok and msg.tag == 'pong' then
          M._zmq_ready = true
          M._flush_pending_exec()
          if cb then cb(true) end
        else
          vim.defer_fn(try_ping, 100)
        end
      end)
      if not sent then
        vim.defer_fn(try_ping, 100)
      end
    end
    try_ping()
  end)
end

---Run the current cell delimited by lines starting with "# %%".
M.run_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)
	local file_path = fn.expand('%:p')

	-- Prefer IPython runcell helper when configured and viable.
	if M.config.prefer_runcell_magic then
		local path = fn.expand('%:p')
		if path and #path > 0 then
			-- Save buffer before run if requested
			if vim.bo.modified and M.config.runcell_save_before_run ~= false then
				pcall(vim.cmd, 'write')
			end
			if (not vim.bo.modified) and utils.file_exists(path) then
				-- Determine working directory to pass into runcell (no global %cd)
				local cwd_arg = nil
				local mode = M.config.exec_cwd_mode or 'pwd'
				if mode == 'file' then
					cwd_arg = fn.fnamemodify(path, ':p:h')
				elseif mode == 'pwd' then
					cwd_arg = fn.getcwd()
				end
				-- Count cell index by markers strictly matching '^# %%+'
				local pre_lines = api.nvim_buf_get_lines(0, 0, math.max(line_start - 1, 0), false)
				local idx = 0
				for _, ln in ipairs(pre_lines) do
					local s = CELL_RE:match_str(ln)
					if s ~= nil then idx = idx + 1 end
				end
				M._ensure_runcell_helpers()
				local safe = utils.py_quote_single(path)
				if cwd_arg and #cwd_arg > 0 then
					local safecwd = utils.py_quote_single(cwd_arg)
					M.term_instance:send(string.format("runcell(%d, '%s', '%s')\n", idx, safe, safecwd))
				else
					M.term_instance:send(string.format("runcell(%d, '%s')\n", idx, safe))
				end
				if has_next_cell then
					local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
					api.nvim_win_set_cursor(0, { idx_line, 0 })
				end
				return
			end
		end
	end

	-- Fallback: send cell text directly.
	set_exec_cwd_for(file_path)
	local end_excl = has_next_cell and (line_stop - 1) or line_stop
	M.send_lines(line_start - 1, end_excl)

	if has_next_cell then
		local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
		api.nvim_win_set_cursor(0, { idx_line, 0 })
	end
end

---Move cursor to the start of the previous cell.
M.up_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor - 2)

	local idx_line = math.min(line_start + 1, api.nvim_buf_line_count(0))
	api.nvim_win_set_cursor(0, { idx_line, 0 })
end

---Move cursor to the start of the next cell.
M.down_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	if has_next_cell then
		local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
		api.nvim_win_set_cursor(0, { idx_line, 0 })
	end
end

return M
