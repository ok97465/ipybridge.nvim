-- This plugin requires Neovim 0.11 or newer.
-- Fail fast on older versions to prevent undefined behavior.
if vim.fn.has('nvim-0.11') ~= 1 then
  error('my_ipy.nvim requires Neovim 0.11 or newer')
end

local vim = vim
local api = vim.api
local fn = vim.fn
local term_helper = require("my_ipy.term_ipy")
local fs = vim.fs
local uv = vim.uv

local M = { term_instance = nil, _helpers_sent = false, _conn_file = nil, _kernel_job = nil, _helpers_path = nil, _runcell_sent = false, _runcell_path = nil, _last_cwd_sent = nil }
-- Cell markers must be exactly: start of line '#', one space, then at least '%%'.
-- Examples matched: '# %%', '# %% Import'. Examples NOT matched: '  # %%', '#%%'.
local CELL_PATTERN = [[^# %%\+]]
local CELL_RE = vim.regex(CELL_PATTERN)

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
    -- Working directory mode for executing run_cell/run_file: 'file' | 'pwd' | 'none'
    --  - 'file': cd to the current file's directory before executing
    --  - 'pwd' : cd to Neovim's current working directory before executing
    --  - 'none': do not change directory
    exec_cwd_mode = 'pwd',
    -- Console prompt/color options
    -- Use a rich prompt (colors, toolbar) by default; set true to simplify.
    simple_prompt = false,
    -- Optional color scheme for ZMQTerminalInteractiveShell (e.g., 'Linux', 'LightBG', 'NoColor').
    ipython_colors = nil,
    -- Variable explorer: hide variables by exact name or type name (supports '*' suffix as prefix wildcard)
    hidden_var_names = { 'pi', 'newaxis' },
    hidden_type_names = { 'ZMQInteractiveShell', 'Axes', 'Figure', 'AxesSubplot' },
    -- ZMQ backend debug logs (Python client prints to stderr)
    zmq_debug = false,
    
}

-- Fast file existence check using libuv.
local function file_exists(path)
  return uv.fs_stat(path) and true or false
end

-- Normalize a filesystem path for Python literals (portable across OS).
-- 1) Convert Windows backslashes to forward slashes
-- 2) Quote for single or double-quoted Python strings as needed
local function _norm_path(p)
  return tostring(p or ''):gsub('\\', '/')
end

local function _py_quote_single(p)
  return _norm_path(p):gsub("'", "\\'")
end

local function _py_quote_double(p)
  return _norm_path(p):gsub('"', '\\"')
end

-- Return normalized 0-indexed (start_row, start_col, end_row, end_col) of visual selection.
-- Return a 0-indexed (start_row, end_row_exclusive) line range for visual selection.
-- Works reliably even when called directly from a visual-mode mapping by using getpos('v').
local function selection_line_range()
  local mode = fn.mode()
  -- Visual modes: 'v' (charwise), 'V' (linewise), CTRL-V (blockwise).
  -- Use string.char(22) to match blockwise visual without escape ambiguity.
  if mode == 'v' or mode == 'V' or mode == string.char(22) then
    local vpos = fn.getpos('v')
    local cpos = fn.getpos('.')
    local srow = vpos[2]
    local erow = cpos[2]
    if srow > erow then srow, erow = erow, srow end
    return srow - 1, erow -- end is exclusive when passed to nvim_buf_get_lines
  end
  -- Fallback when not in visual: use the last visual marks ('<' and '>').
  local srow = (api.nvim_buf_get_mark(0, '<') or { 0, 0 })[1]
  local erow = (api.nvim_buf_get_mark(0, '>') or { 0, 0 })[1]
  if srow == 0 or erow == 0 then return nil end
  if srow > erow then srow, erow = erow, srow end
  return srow - 1, erow
end

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

-- Build a bracketed-paste payload for multiple lines.
-- This is safer across terminals and shells than simulating keystrokes.
-- See: xterm bracketed paste mode (ESC [ 200 ~ ... ESC [ 201 ~)
local function paste_block(lines_tbl)
  if not lines_tbl or #lines_tbl == 0 then return "" end
  return "\x1b[200~" .. table.concat(lines_tbl, "\n") .. "\n\x1b[201~\n"
end

-- Encode a Lua string to hex for safe transport via Python exec/compile.
local function to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Send a Python exec(compile(...)) that decodes a hex-encoded block and executes it in globals().
local function send_exec_block(py_src)
  local hex = to_hex(py_src)
  local stmt = string.format("exec(compile(bytes.fromhex('%s').decode('utf-8'), '<my_ipy>', 'exec'), globals(), globals())\n", hex)
  return stmt
end

-- Build a short Python statement to exec a file's contents in globals().
local function exec_file_stmt(path)
  -- Read and exec file contents in globals(); path is single-quoted
  local safe = _py_quote_single(path)
  return string.format("exec(open('%s', 'r', encoding='utf-8').read(), globals(), globals())\n", safe)
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
  local safe = _py_quote_single(dir)
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
            use_zmq = { config.use_zmq, 'b', true },
            python_cmd = { config.python_cmd, 's', true },
        })
    end
    M.config = vim.tbl_deep_extend("force", M.config, config or {})

    if M.config.set_default_keymaps then
        M.apply_default_keymaps()
        -- Also apply to any already-open Python buffers
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(b) then
                local ft = (vim.bo[b] and vim.bo[b].filetype) or ""
                if ft == 'python' then
                    M.apply_buffer_keymaps(b)
                end
            end
        end
    end
end

---Apply a set of sensible default keymaps.
M.apply_default_keymaps = function()
    local group = api.nvim_create_augroup('MyIpyKeymaps', { clear = true })
    -- Apply Python buffer keymaps
    api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = 'python',
        callback = function(args)
            M.apply_buffer_keymaps(args.buf)
        end,
    })
    -- Map <leader>iv globally: back to editor
    pcall(vim.keymap.set, 'n', '<leader>iv', M.goto_vi, { silent = true, desc = 'IPy: Back to editor' })
    pcall(vim.keymap.set, 't', '<leader>iv', function() M.goto_vi() end, { silent = true, desc = 'IPy: Back to editor' })
    -- Provide global access to Variable Explorer even outside Python buffers
    pcall(vim.keymap.set, 'n', '<leader>vx', function() require('my_ipy').var_explorer_open() end, { silent = true, desc = 'IPy: Variable explorer' })
    pcall(vim.keymap.set, 'n', '<leader>vr', function() require('my_ipy').var_explorer_refresh() end, { silent = true, desc = 'IPy: Refresh variables' })
    -- User commands for discoverability
    pcall(api.nvim_create_user_command, 'MyIpyVars', function() require('my_ipy').var_explorer_open() end, {})
    pcall(api.nvim_create_user_command, 'MyIpyVarsRefresh', function() require('my_ipy').var_explorer_refresh() end, {})
    -- Preview arbitrary name/path (supports dotted/indexed paths, e.g., `yy.b`, `hh.h2`)
    pcall(api.nvim_create_user_command, 'MyIpyPreview', function(opts)
      local name = (opts and opts.args) or ''
      if name ~= '' then require('my_ipy').request_preview(name) end
    end, { nargs = 1, complete = 'buffer' })
end

---Apply buffer-local keymaps for Python files.
---@param bufnr integer
M.apply_buffer_keymaps = function(bufnr)
    local function set(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true, buffer = bufnr })
    end
    -- Toggle terminal
    set('n', '<leader>ti', M.toggle, 'IPy: Toggle terminal')
    -- Jump to IPython / back to editor
    set('n', '<leader>ii', M.goto_ipy, 'IPy: Focus terminal')
    set('n', '<leader>iv', M.goto_vi,  'IPy: Back to editor')
    -- Run current cell
    set('n', '<leader><CR>', M.run_cell, 'IPy: Run cell')
    -- Run current file
    set('n', '<F5>', M.run_file, 'IPy: Run file (%run)')
    -- Run current line (normal) / selection (visual)
    set('n', '<leader>r', M.run_line, 'IPy: Run line')
    set('v', '<leader>r', M.run_lines, 'IPy: Run selection')
    -- F9 as alternative for line/selection
    set('n', '<F9>', M.run_line, 'IPy: Run line (F9)')
    set('v', '<F9>', M.run_lines, 'IPy: Run selection (F9)')
    -- Cell navigation in normal and visual modes
    set('n', ']c', M.down_cell, 'IPy: Next cell')
    set('n', '[c', M.up_cell,  'IPy: Prev cell')
    set('v', ']c', M.down_cell, 'IPy: Next cell (visual)')
    set('v', '[c', M.up_cell,  'IPy: Prev cell (visual)')
    -- Variable explorer and refresh
    set('n', '<leader>vx', function() M.var_explorer_open() end, 'IPy: Variable explorer')
    set('n', '<leader>vr', function() M.var_explorer_refresh() end, 'IPy: Refresh variables')
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
    M._ensure_kernel(function(ok, conn_file)
        if not ok then
            vim.notify('my_ipy: failed to start Jupyter kernel', vim.log.levels.ERROR)
            if cb then cb(false) end
            return
        end
        -- Open jupyter console attached to this kernel
        local extra = ''
        if M.config.simple_prompt then extra = extra .. ' --simple-prompt' end
        local cmd_console = string.format("jupyter console --existing %s%s", conn_file, extra)
        M.term_instance = term_helper.TermIpy:new(cmd_console, cwd)
        -- Reset helper state and cached paths for new session
        M._helpers_sent = false
        if M._helpers_path then pcall(os.remove, M._helpers_path); M._helpers_path = nil end
        M._runcell_sent = false
        if M._runcell_path then pcall(os.remove, M._runcell_path); M._runcell_path = nil end
        M._last_cwd_sent = nil
        M._zmq_ready = false
        -- Start ZMQ backend for programmatic requests
        M.ensure_zmq(function(ok2)
            if not ok2 then
                vim.schedule(function()
                    vim.notify('my_ipy: failed to start ZMQ backend', vim.log.levels.WARN)
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
            -- Enable interactive plotting and minimal numeric imports for convenience
            local cwd = fn.getcwd()
            local path_startup_script = fs.joinpath(cwd, M.config.startup_script)
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
            -- Optionally enable interactive mode
            if M.config.matplotlib_ion ~= false then
              M.term_instance:send("import matplotlib.pyplot as plt; plt.ion()\n")
            end
            if file_exists(path_startup_script) then
              M.term_instance:send(exec_file_stmt(path_startup_script))
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

-- Build the Python helper code to be injected into IPython session.
-- It defines JSON emit, variable listing, and preview for DataFrame/ndarray.
local function _helpers_py_code()
  return [[
import json, inspect, types
try:
    import numpy as _np
except Exception:
    _np = None
try:
    import pandas as _pd
except Exception:
    _pd = None

_S = "__MYIPY_JSON_START__"
_E = "__MYIPY_JSON_END__"
_HIDE_ON = "\x1b[8m"   # SGR conceal on
_HIDE_OFF = "\x1b[0m"  # reset attributes

def _myipy_emit(tag, payload):
    # Print sentinel-wrapped JSON, visually hidden in most terminals (SGR 8).
    msg = json.dumps({"tag": tag, "data": payload}) if not isinstance(payload, Exception) else json.dumps({"tag": tag, "error": str(payload)})
    try:
        print(_HIDE_ON + _S + msg + _E + _HIDE_OFF, flush=True)
    except Exception as e:
        print(_HIDE_ON + _S + json.dumps({"tag": tag, "error": str(e)}) + _E + _HIDE_OFF, flush=True)

def _myipy_srepr(x, n=120):
    try:
        r = repr(x)
        if len(r) > n:
            r = r[:n] + "..."
        return r
    except Exception:
        return "<unrepr>"

def _myipy_shape(x):
    try:
        if _np is not None and isinstance(x, _np.ndarray):
            return list(getattr(x, 'shape', []))
        if _pd is not None and isinstance(x, _pd.DataFrame):
            return [int(x.shape[0]), int(x.shape[1])]
        if hasattr(x, '__len__') and not isinstance(x, (str, bytes, dict)):
            return [len(x)]
    except Exception:
        pass
    return None

def _myipy_list_vars(max_repr=120, __path=None):
    import builtins, types, sys
    g = globals()
    out = {}
    for k, v in g.items():
        if not isinstance(k, str):
            continue
        if k.startswith('_'):
            continue
        if k in ('In','Out','exit','quit','get_ipython'):
            continue
        t = type(v).__name__
        # Skip modules/functions/classes to reduce noise
        # Skip modules/functions/classes/callables (e.g., numpy ufunc)
        if isinstance(v, (types.ModuleType, types.FunctionType, type)) or callable(v):
            continue
        shp = _myipy_shape(v)
        br = _myipy_srepr(v, max_repr)
        try:
            dtype = None
            if _np is not None and isinstance(v, _np.ndarray):
                dtype = str(v.dtype)
            elif _pd is not None and isinstance(v, _pd.DataFrame):
                dtype = str(v.dtypes.to_dict())
        except Exception:
            dtype = None
        out[k] = {"type": t, "shape": shp, "dtype": dtype, "repr": br}
    if __path:
        _myipy_write_json(__path, out)
    else:
        _myipy_emit("vars", out)
    _myipy_purge_last_history()

def _myipy_write_json(path, obj):
    try:
        import io, os
        with io.open(path, 'w', encoding='utf-8') as f:
            json.dump(obj, f, ensure_ascii=False)
    except Exception as e:
        # As a last resort, emit an error (hidden)
        _myipy_emit('preview', { 'name': obj.get('name') if isinstance(obj, dict) else None, 'error': str(e) })

def _myipy_get_conn_file(__path=None):
    try:
        ip = get_ipython()
        cf = getattr(ip.kernel, 'connection_file', None)
    except Exception as e:
        cf = None
    data = { 'connection_file': cf }
    if __path:
        _myipy_write_json(__path, data)
    else:
        _myipy_emit('conn', data)

def _myipy_purge_last_history():
    try:
        ip = get_ipython()
        hm = ip.history_manager
        cur = hm.db.cursor() if hasattr(hm, 'db') else hm.get_db_cursor()
        sess = hm.session_number
        cur.execute("SELECT max(line) FROM input WHERE session=?", (sess,))
        row = cur.fetchone()
        maxline = row[0] if row else None
        if maxline:
            cur.execute("DELETE FROM input WHERE session=? AND line=?", (sess, maxline))
            try:
                hm.db.commit()
            except Exception:
                pass
        try:
            if getattr(hm, 'input_hist_parsed', None):
                hm.input_hist_parsed.pop()
        except Exception:
            pass
        try:
            if getattr(hm, 'input_hist_raw', None):
                hm.input_hist_raw.pop()
        except Exception:
            pass
    except Exception:
        pass

def _myipy_preview(name, max_rows=50, max_cols=20, __path=None):
    g = globals()
    if name not in g:
        _myipy_emit("preview", {"name": name, "error": "Name not found"})
        _myipy_purge_last_history()
        return
    obj = g[name]
    try:
        if _pd is not None and isinstance(obj, _pd.DataFrame):
            df = obj.iloc[:max_rows, :max_cols]
            data = {
                "name": name,
                "kind": "dataframe",
                "shape": [int(df.shape[0]), int(df.shape[1])],
                "columns": [str(c) for c in df.columns.to_list()],
                "rows": [ [ None if _pd.isna(v) else (str(v) if not isinstance(v, (int,float,bool)) else v) for v in row ] for row in df.itertuples(index=False, name=None) ]
            }
            if __path:
                _myipy_write_json(__path, data)
            else:
                _myipy_emit("preview", data)
            _myipy_purge_last_history()
            return
    except Exception as e:
        if __path:
            _myipy_write_json(__path, {"name": name, "error": str(e)})
        else:
            _myipy_emit("preview", {"name": name, "error": str(e)})
        _myipy_purge_last_history()
        return
    try:
        if _np is not None and isinstance(obj, _np.ndarray):
            arr = obj
            info = {"name": name, "kind": "ndarray", "dtype": str(arr.dtype), "shape": list(arr.shape)}
            if getattr(arr, 'ndim', 0) == 1:
                info["values1d"] = arr[:max_rows].tolist()
            elif getattr(arr, 'ndim', 0) == 2:
                info["rows"] = arr[:max_rows, :max_cols].tolist()
            else:
                info["repr"] = _myipy_srepr(arr, 300)
            if __path:
                _myipy_write_json(__path, info)
            else:
                _myipy_emit("preview", info)
            _myipy_purge_last_history()
            return
    except Exception as e:
        if __path:
            _myipy_write_json(__path, {"name": name, "error": str(e)})
        else:
            _myipy_emit("preview", {"name": name, "error": str(e)})
        _myipy_purge_last_history()
        return
    # Generic fallback: show repr
    data = {"name": name, "kind": "object", "repr": _myipy_srepr(obj, 300)}
    if __path:
        _myipy_write_json(__path, data)
    else:
        _myipy_emit("preview", data)
    _myipy_purge_last_history()
  ]]
end

-- Define a Spyder-like runcell helper and register an IPython line magic.
local function _runcell_py_code()
  return [[
import io, os, re, shlex, contextlib, sys, traceback
from IPython.core.magic import register_line_magic

_CELL_RE = re.compile(r'^# %%+')

@contextlib.contextmanager
def _mi_cwd(path):
    if not path:
        yield; return
    try:
        old = os.getcwd()
    except Exception:
        old = None
    try:
        os.chdir(path)
        yield
    finally:
        if old is not None:
            try:
                os.chdir(old)
            except Exception:
                pass

@contextlib.contextmanager
def _mi_exec_env(filename):
    g = globals()
    prev_file = g.get('__file__', None)
    added = False
    try:
        fdir = os.path.dirname(os.path.abspath(filename))
        if fdir and fdir not in sys.path:
            sys.path.insert(0, fdir)
            added = True
        g['__file__'] = filename
        yield
    finally:
        if added:
            try:
                sys.path.remove(fdir)
            except Exception:
                pass
        if prev_file is None:
            g.pop('__file__', None)
        else:
            g['__file__'] = prev_file

def runcell(index, filename, cwd=None):
    try:
        idx = int(index)
    except Exception:
        print('runcell: invalid index'); return
    try:
        with io.open(filename, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
    except Exception as e:
        print(f'runcell: cannot read {filename}: {e}'); return
    # Compute cell starts using only explicit markers ('# %%'), index is 0-based over markers
    starts = [i for i, ln in enumerate(lines) if _CELL_RE.match(ln)]
    starts = sorted(set(starts))
    if idx < 0 or idx >= len(starts):
        print(f'runcell: index out of range: {idx}'); return
    s = starts[idx]
    # Next marker (or EOF)
    e = (starts[idx + 1] - 1) if (idx + 1) < len(starts) else (len(lines) - 1)
    code = '\n'.join(lines[s:e+1]) + '\n'
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(code, filename, 'exec'), globals(), globals())
            except SystemExit:
                # Allow graceful exits without noisy tracebacks
                pass
            except Exception:
                traceback.print_exc()

@register_line_magic('runcell')
def _runcell_magic(line):
    try:
        parts = shlex.split(line)
    except Exception:
        print('Usage: %runcell <index> <path> [cwd]'); return
    if len(parts) < 2:
        print('Usage: %runcell <index> <path> [cwd]'); return
    try:
        idx = int(parts[0])
    except Exception:
        print('runcell: invalid index'); return
    cwd = parts[2] if len(parts) > 2 else None
    runcell(idx, parts[1], cwd)
 
def runfile(filename, cwd=None):
    try:
        with io.open(filename, 'r', encoding='utf-8') as f:
            src = f.read()
    except Exception as e:
        print(f'runfile: cannot read {filename}: {e}'); return
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(src, filename, 'exec'), globals(), globals())
            except SystemExit:
                pass
            except Exception:
                traceback.print_exc()

@register_line_magic('runfile')
def _runfile_magic(line):
    try:
        parts = shlex.split(line)
    except Exception:
        print('Usage: %runfile <path> [cwd]'); return
    if len(parts) < 1:
        print('Usage: %runfile <path> [cwd]'); return
    path = parts[0]
    cwd = parts[1] if len(parts) > 1 else None
    runfile(path, cwd)
  ]]
end

function M._ensure_runcell_helpers()
  if M._runcell_sent then return end
  if not M.is_open() then return end
  local code = _runcell_py_code()
  if not M._runcell_path then
    M._runcell_path = fn.tempname() .. '.myipy_runcell.py'
    pcall(fn.writefile, vim.split(code, "\n", { plain = true }), M._runcell_path)
  end
  M.term_instance:send(exec_file_stmt(M._runcell_path))
  M._runcell_sent = true
end

function M._send_helpers_if_needed()
  if M._helpers_sent then return end
  if not M.is_open() then return end
  local code = _helpers_py_code()
  -- Write helpers to a temp file and exec it to avoid huge one-liners.
  -- Keep the file until session close to avoid race with console reading.
  if not M._helpers_path then
    M._helpers_path = fn.tempname() .. '.myipy_helpers.py'
    pcall(fn.writefile, vim.split(code, "\n", { plain = true }), M._helpers_path)
  end
  M.term_instance:send(exec_file_stmt(M._helpers_path))
  M._helpers_sent = true
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
  -- Delegate to kernel manager: we start the kernel ourselves and own the conn file.
  M._ensure_kernel(cb)
end

---Close the IPython terminal if running.
M.close = function()
	if M.is_open() then
		fn.jobstop(M.term_instance.job_id)
	end
    M._conn_file = nil
    M._zmq_ready = false
    pcall(function() require('my_ipy.zmq_client').stop() end)
    if M._kernel_job then
        pcall(fn.jobstop, M._kernel_job)
        M._kernel_job = nil
    end
    if M._helpers_path then
        pcall(os.remove, M._helpers_path)
        M._helpers_path = nil
    end
    if M._runcell_path then
        pcall(os.remove, M._runcell_path)
        M._runcell_path = nil
    end
    M._last_cwd_sent = nil
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
			local safe = _py_quote_single(abs_path)
			if cwd_arg and #cwd_arg > 0 then
				local safecwd = _py_quote_single(cwd_arg)
				M.term_instance:send(string.format("runfile('%s','%s')\n", safe, safecwd))
			else
				M.term_instance:send(string.format("runfile('%s')\n", safe))
			end
		else
			-- Adjust working directory as configured and use %run
			set_exec_cwd_for(abs_path)
			local safe = _py_quote_double(abs_path)
			M.term_instance:send(string.format("%%run \"%s\"\n", safe))
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

  local function do_send()
    if not M.is_open() then return end
    -- Execute multi-line selection robustly by shipping as hex-encoded Python and exec() it.
    local block = table.concat(tb_lines, "\n") .. "\n"
    local payload = send_exec_block(block)
    M.term_instance:send(payload)
  end

	if not M.is_open() then
		M.open(true, function(ok) if ok then do_send() end end)
	else
		do_send()
	end
end

---Send the current visual selection (linewise) to IPython.
M.run_lines = function()
	local line_start0, line_end_excl0 = selection_line_range()
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

-- Public: open the variable explorer window and refresh data.
M.var_explorer_open = function()
  require('my_ipy.var_explorer').open()
  -- Trigger a vars request; request_vars() self-ensures ZMQ readiness.
  -- Avoid redundant readiness checks here.
  M.request_vars()
end

-- Public: refresh variable list.
M.var_explorer_refresh = function()
  -- Avoid repeated ensure calls; delegate to request_vars() which ensures ZMQ.
  M.request_vars()
end

-- Internal: request variable list from kernel.
function M.request_vars()
  if M.config.use_zmq and M._zmq_ready then
    local z = require('my_ipy.zmq_client')
    local ok_req = z.request('vars', {
      max_repr = 120,
      hide_names = M.config.hidden_var_names,
      hide_types = M.config.hidden_type_names,
    }, function(msg)
      if msg and msg.ok and msg.tag == 'vars' then
        local ok, vx = pcall(require, 'my_ipy.var_explorer')
        if ok and vx and vx.on_vars then
          vim.schedule(function()
            vx.on_vars(msg.data or {})
          end)
        end
      else
        vim.schedule(function()
          vim.notify('my_ipy: ZMQ vars request failed', vim.log.levels.WARN)
        end)
      end
    end)
    if not ok_req then
      vim.notify('my_ipy: ZMQ request send failed', vim.log.levels.WARN)
    end
    return
  end
  -- If ZMQ not ready, attempt to prepare once; do not fall back to typing helper calls.
  M.ensure_zmq(function(ok)
    if ok then
      M.request_vars()
    else
      vim.notify('my_ipy: ZMQ backend not available; vars unavailable', vim.log.levels.WARN)
    end
  end)
end

-- Internal: request preview for a variable name from kernel.
function M.request_preview(name)
  if not name or #name == 0 then return end
  if M.config.use_zmq and M._zmq_ready then
    local z = require('my_ipy.zmq_client')
    local ok_req = z.request('preview', { name = name, max_rows = M.config.viewer_max_rows, max_cols = M.config.viewer_max_cols }, function(msg)
      if msg and msg.ok and msg.tag == 'preview' then
        local ok, dv = pcall(require, 'my_ipy.data_viewer')
        if ok and dv and dv.on_preview then
          vim.schedule(function()
            dv.on_preview(msg.data or {})
          end)
        end
      else
        vim.schedule(function()
          vim.notify('my_ipy: ZMQ preview request failed', vim.log.levels.WARN)
        end)
      end
    end)
    if not ok_req then
      vim.notify('my_ipy: ZMQ request send failed', vim.log.levels.WARN)
    end
    return
  end
  -- Ensure ZMQ then retry once; do not fall back to typing helper calls.
  M.ensure_zmq(function(ok)
    if ok then
      M.request_preview(name)
    else
      vim.notify('my_ipy: ZMQ backend not available; preview unavailable', vim.log.levels.WARN)
    end
  end)
end

-- Ensure ZMQ client: fetch connection file and spawn backend.
function M.ensure_zmq(cb)
  if not M.config.use_zmq then if cb then cb(false) end; return end
  if M._zmq_ready then if cb then cb(true) end; return end
  M._ensure_conn_file(function(ok, conn_file)
    if not ok or not conn_file then if cb then cb(false) end; return end
    local z = require('my_ipy.zmq_client')
    -- Resolve backend path relative to repo root: ../../ -> python/myipy_kernel_client.py
    local this = debug.getinfo(1, 'S').source:sub(2)
    local plugin_dir = fn.fnamemodify(this, ':h')           -- /repo/lua/my_ipy
    local repo_root = fn.fnamemodify(plugin_dir, ':h:h')     -- /repo
    local backend = repo_root .. '/python/myipy_kernel_client.py'
    local ok_start = z.start(M.config.python_cmd, conn_file, backend, M.config.zmq_debug)
    if not ok_start then if cb then cb(false) end; return end
    -- Probe readiness with a ping
    local tried = 0
    local function try_ping()
      tried = tried + 1
      if tried > 20 then if cb then cb(false) end; return end
      local sent = z.request('ping', {}, function(msg)
        if msg and msg.ok and msg.tag == 'pong' then
          M._zmq_ready = true
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
			if (not vim.bo.modified) and file_exists(path) then
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
				local safe = _py_quote_single(path)
				if cwd_arg and #cwd_arg > 0 then
					local safecwd = _py_quote_single(cwd_arg)
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
