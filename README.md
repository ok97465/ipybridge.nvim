# my_ipy.nvim

Minimal helper to run IPython/Jupyter in a terminal split and send code from the current buffer, tuned for Neovim 0.11+.

Requirements
- Neovim 0.11 or newer
- Python with Jupyter/IPython
  - `jupyter` (for `jupyter console`)
  - `ipykernel`, `jupyter_client`, `pyzmq` (for variable explorer / preview)
  - `ipython` (for the console experience)

Installation (lazy.nvim)
- Example:
  ```lua
  {
    "ok97465/my_ipy.nvim",
    config = function()
      require("my_ipy").setup({
        profile_name = "vim",           -- or nil to omit --profile
        startup_script = "import_in_console.py", -- looked up in CWD
        sleep_ms_after_open = 1000,      -- defer init to allow IPython to start
        set_default_keymaps = true,      -- applies by default (can set false)

        -- Matplotlib backend / ion
        matplotlib_backend = nil,        -- 'qt'|'tk'|'macosx'|'inline' or 'QtAgg'|'TkAgg'|'MacOSX'
        matplotlib_ion = true,           -- call plt.ion() on startup

        -- Spyder-like runcell support
        prefer_runcell_magic = false,    -- run cells via helper instead of raw text
        runcell_save_before_run = true,  -- save buffer before runcell to use up-to-date file

        -- Variable explorer / preview (ZMQ backend)
        use_zmq = true,                  -- requires ipykernel + jupyter_client + pyzmq
        viewer_max_rows = 30,
        viewer_max_cols = 20,
      })
    end,
  }
  ```

Configuration
- `profile_name` (string|nil): IPython profile passed as `--profile=<name>`. If `nil`, the flag is omitted.
- `startup_script` (string): If this file exists under current working directory, `ipython -i <startup_script>` is used.
- `startup_cmd` (string): Deprecated/unused. If `startup_script` is missing, the plugin sends minimal numeric imports instead.
- `sleep_ms_after_open` (number): Milliseconds to wait (non-blocking) before running initial setup such as `plt.ion()`.
- `set_default_keymaps` (boolean, default: `true`): Apply buffer-local keymaps for Python files only.

Additional options
- `matplotlib_backend` (string|nil): `'qt'|'tk'|'macosx'|'inline'` via IPython magic, or backend name `'QtAgg'|'TkAgg'|'MacOSX'` via `matplotlib.use()`.
- `matplotlib_ion` (boolean): If `true`, `plt.ion()` is called on startup (default `true`).
- `prefer_runcell_magic` (boolean): If `true`, run cells via an IPython helper (`runcell(index, path)` / `%runcell`).
- `runcell_save_before_run` (boolean): Save the buffer before runcell execution (default `true`).
- `exec_cwd_mode` (string): Working directory behavior for `run_cell` / `run_file`.
  - `'file'`: change directory to the current file's directory before executing
  - `'pwd'`: change directory to Neovim's `getcwd()` (default)
  - `'none'`: do not change directory
- `use_zmq` (boolean): Enable ZMQ backend for variable explorer/preview (default `true`). Requires `ipykernel`, `jupyter_client`, `pyzmq`.
- `viewer_max_rows` / `viewer_max_cols` (numbers): DataFrame/ndarray preview limits.

Cell Syntax
- Lines beginning with `# %%` (one or more `%`) mark cell boundaries.
- A “cell” runs from the most recent `# %%` (or file start) up to the line before the next `# %%` (or file end).

API
- `require('my_ipy').setup(opts)` — Configure the plugin.
- `require('my_ipy').toggle()` — Toggle the IPython terminal split.
- `require('my_ipy').open(go_back)` — Open the terminal. If `go_back` is `true`, jump back to the previous window after initialization.
- `require('my_ipy').close()` — Close the terminal job if running.
- `require('my_ipy').goto_ipy()` — Focus the IPython split and enter insert mode.
- `require('my_ipy').goto_vi()` — Return focus from the IPython split to the previous window.
- `require('my_ipy').run_file()` — Run the current file via `%run <filebase>` in IPython.
- `require('my_ipy').run_line()` — Send the current line, then move the cursor down.
- `require('my_ipy').run_lines()` — Send the current visual selection (linewise) to IPython.
- `require('my_ipy').send_lines(start_line, end_line)` — Send lines `[start_line, end_line)` by 0-indexed range.
- `require('my_ipy').run_cmd(cmd)` — Send an arbitrary command string.
- `require('my_ipy').run_cell()` — Run the current cell and move the cursor to the beginning of the next one.
- `require('my_ipy').up_cell()` / `down_cell()` — Move to the previous/next cell.

Notes
- On open, the plugin starts a Jupyter kernel and attaches a `jupyter console --existing` in a `botright vsplit`.
- Matplotlib: if configured, the backend is set first (IPython magic or `matplotlib.use()`), then `plt.ion()` is called (configurable).
- If `startup_script` exists in the current working directory, it is executed in the console; otherwise minimal numeric imports are sent.
- Multi-line sending uses bracketed paste sequences (ESC[200~ ... ESC[201~) for reliable block input across terminals.
- Cell detection uses a `# %%`-style marker and is implemented with `vim.regex` and `vim.iter` (Neovim 0.11+ APIs) for clarity and performance.
- When `set_default_keymaps` is enabled, keymaps are also applied to already-open Python buffers at startup.

Matplotlib Backend / GUI Windows
- Set `matplotlib_backend = 'qt'|'tk'|'macosx'|'inline'` to use IPython magic, or `'QtAgg'|'TkAgg'|'MacOSX'` for `matplotlib.use()`.
- `matplotlib_ion = true` enables interactive mode. For GUI windows instead of inline PNGs, use a GUI backend (e.g. `'qt'`).
- Qt requires `PyQt5` or `PySide6`. Tk requires Tk support. macOS may require framework build Python.

Spyder-like Runcell
- Enable `prefer_runcell_magic = true` to execute cells via a helper registered in IPython.
- The helper defines `runcell(index, path, cwd=None)` and a `%runcell` line magic. Cells are delimited by lines matching `^# %%+`.
- The plugin computes the current cell index (0-based) and calls `runcell(index, <current file path>, <cwd according to exec_cwd_mode>)`.
- If `runcell_save_before_run = true` (default), the buffer is saved first to ensure the helper runs the latest contents.
- If the buffer is unsaved or the file path is missing, the plugin falls back to sending the cell text directly.

Variable Explorer & Data Viewer (ZMQ)
- Open the variable explorer and request current variables from the kernel over a lightweight ZMQ backend.
- Requirements: `ipykernel`, `jupyter_client`, `pyzmq` (in the Python environment of the kernel).
- Default keymaps:
  - `<leader>vx` → open variable explorer
  - `<leader>vr` → refresh variables
- Explorer buffer shortcuts:
  - `q` → close, `r` → refresh, `<CR>` → open preview for the selected variable
- Preview window shows DataFrame/ndarray/object summaries; press `r` to refresh, `q` to close.

Default Keymaps (Python buffers only)
- Normal:
  - `<leader>ti` → toggle IPython terminal
  - `<leader>ii` → focus IPython terminal
  - `<leader><CR>` → run current cell (`# %%` delimited)
  - `F5` → run current file (`%run`)
  - `<leader>r` → run current line
  - `F9` → run current line
  - `]c` / `[c` → next/prev cell
  - `<leader>vx` → variable explorer (global command also available)
  - `<leader>vr` → refresh variables
- Visual:
  - `<leader>r` → run selection
  - `F9` → run selection
  - `]c` / `[c` → next/prev cell

Global
- Normal/Terminal:
  - `<leader>iv` → back to editor (works anywhere; exits terminal and jumps back)

User Commands
- `:MyIpyVars` → open variable explorer
- `:MyIpyVarsRefresh` → refresh variables

Terminal Buffers
- Terminal mode:
  - `<leader>iv` → back to editor (works in any terminal buffer)

Manual Mappings Example
```lua
local my_ipy = require('my_ipy')
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'python',
  callback = function()
    vim.keymap.set('n', '<leader>ti', my_ipy.toggle, { buffer = true })
    vim.keymap.set('n', '<leader>ii', my_ipy.goto_ipy, { buffer = true })
    vim.keymap.set('n', '<leader>iv', my_ipy.goto_vi,  { buffer = true })
    vim.keymap.set('n', '<leader><CR>', my_ipy.run_cell, { buffer = true })
    vim.keymap.set('n', '<F5>', my_ipy.run_file, { buffer = true })
    vim.keymap.set('n', '<leader>r', my_ipy.run_line, { buffer = true })
    vim.keymap.set('v', '<leader>r', my_ipy.run_lines, { buffer = true })
    vim.keymap.set('n', '<F9>', my_ipy.run_line, { buffer = true })
    vim.keymap.set('v', '<F9>', my_ipy.run_lines, { buffer = true })
    vim.keymap.set('n', ']c', my_ipy.down_cell, { buffer = true })
    vim.keymap.set('n', '[c', my_ipy.up_cell,   { buffer = true })
    vim.keymap.set('v', ']c', my_ipy.down_cell, { buffer = true })
    vim.keymap.set('v', '[c', my_ipy.up_cell,   { buffer = true })
    -- In the terminal buffer, set this (example):
    -- vim.keymap.set('t', '<leader>iv', my_ipy.goto_vi, { buffer = <ipy_bufnr> })
  end,
})
```

Troubleshooting
- Ensure `ipython` is installed and discoverable in your environment.
- For variable explorer and preview, ensure `ipykernel`, `jupyter_client`, and `pyzmq` are installed in the kernel’s environment.
- If the split opens but does not accept input, check your terminal integration or try a different shell.
- Windows console sequences are handled, but some terminals may require different escape behavior.
