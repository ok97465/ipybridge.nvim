# ipybridge.nvim

Minimal helper to run IPython/Jupyter in a terminal split and send code from the current buffer, tuned for Neovim 0.11+.

## Requirements

- Neovim 0.11 or newer
- Completion engine: [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) or [`blink.cmp`](https://github.com/Saghen/blink.cmp). ipybridge auto-detects whichever is available (defaults to nvim-cmp when both are installed, but you can reorder via `completion.engine_priority`).
- Python with Jupyter/IPython
  - `jupyter` (for `jupyter console`)
  - `ipykernel`, `jupyter_client`, `pyzmq` (for variable explorer / preview)
  - `ipython` (for the console experience)

## Demo

`demo` captures the day-to-day workflow: Neovim buffers on the left, the IPython console on the right. Cells run with `runfile()`/`runcell()` helpers, and the console echoes section markers so you can see each phase finish. While the script executes, a preview overlay lists numpy arrays, dataclasses, and ctypes structures so you can drill into live data without leaving the editor.

![demo gif](https://github.com/ok97465/ipybridge.nvim/raw/main/doc/demo.gif)

`demo_debug` dives into the debugger integration:

- Debug sessions run through IPython's `debugfile`, so this plugin natively supports step-by-step debugging.
- Breakpoints you toggle in Neovim are respected; the gutter indicator in the GIF shows the active stop line.
- Matplotlib stays interactive even while the debugger pauses execution, letting you pan and zoom figures mid-inspection.
- The variable explorer examines arrays and custom structures.
- Completions inside `ipdb` come from your completion engine (`nvim-cmp` or `blink.cmp`), giving you the suggestions.

![demo debugger gif](https://github.com/ok97465/ipybridge.nvim/raw/main/doc/demo_debug.gif)

- Plots Pane

![plot_viewer_png](https://github.com/ok97465/ipybridge.nvim/raw/main/doc/plot_viewer.png)

## Debugger Completion Engines

ipybridge streams ipdb suggestions into whichever completion engine you use in the terminal window.

- **nvim-cmp** – ipybridge ships the `ipybridge_debug_hint` source. Include it in the sources you enable for terminal buffers. Example:

  ```lua
  local cmp = require("cmp")
  cmp.setup({
    sources = cmp.config.sources({
      { name = "ipybridge_debug_hint" },
    }, {
      { name = "buffer" },
      { name = "path" },
    }),
  })
  ```

- **blink.cmp** – enable terminal support (`term.enabled = true`) and blink will consume the `IpyBridge` provider that ipybridge registers automatically. Example:

  ```lua
  require("blink.cmp").setup({
    term = {
      enabled = true,
      sources = {
        default = { "ipybridge_debug_hint" }, -- shows up in the UI as “IpyBridge”
      },
    },
  })
  ```

When both engines are installed, nvim-cmp is preferred by default. Override the order inside `require("ipybridge").setup` to pick your favorite engine. The list is also an allow-list, so engines you omit are ignored entirely:

```lua
require("ipybridge").setup({
  completion = {
    engine_priority = { "blink.cmp", "nvim-cmp" },
  },
})
```

## Installation (lazy.nvim)
- Example:
  ```lua
  {
    "ok97465/ipybridge.nvim",
    config = function()
      require("ipybridge").setup({
        profile_name = "vim",           -- or nil to omit --profile
        startup_script = "import_in_console.py", -- looked up in CWD
        sleep_ms_after_open = 1000,      -- defer init to allow IPython to start
        set_default_keymaps = true,      -- applies by default (can set false)

        -- Matplotlib backend
        matplotlib_backend = nil,        -- e.g. 'qt', 'inline', 'macosx', 'tk', 'agg'

        -- Browser-based plot history
        plot_viewer = {
          mode = "browser",             -- "browser" or "off"
          auto_open = true,             -- open the viewer automatically
          history = 40,                 -- max snapshots to keep
        },

        -- Spyder-like runcell/runfile support
        runcell_save_before_run = true,  -- save buffer before runcell to use up-to-date file
        runfile_save_before_run = true,  -- save buffer before runfile to use up-to-date file
        debugfile_save_before_run = true, -- save buffer before debugfile to use up-to-date file
        debugcell_save_before_run = true, -- save buffer before debugcell to use up-to-date file
        debugfile_auto_imports = "import numpy as np;import matplotlib.pyplot as plt;", -- hidden imports before %debugfile

        -- Variable explorer / preview (ZMQ backend requires ipykernel + jupyter_client + pyzmq)
        viewer_max_rows = 30,
        viewer_max_cols = 20,
        -- Autoreload: 1, 2, or 'disable' (default 2)
        autoreload = 2,
      })
    end,
  }
  ```

### Configuration
- `profile_name` (string|nil): IPython profile passed as `--profile=<name>`. If `nil`, the flag is omitted.
- `startup_script` (string): If this file exists under current working directory, `ipython -i <startup_script>` is used.
- `sleep_ms_after_open` (number): Milliseconds to wait (non-blocking) before running initial setup such as `%matplotlib` or `%load_ext autoreload`.
- `set_default_keymaps` (boolean, default: `true`): Apply buffer-local keymaps for Python files only.

### Additional options

- `matplotlib_backend` (string|nil): `qt`, `inline`, `macosx`, `tk`, `agg`
- `plot_viewer` (table): configure Spyder-style history. Fields: `mode = "browser"|"off"`, `auto_open`, and `history` (snapshot cap). `auto_open = true` starts by forcing `%matplotlib inline`.
- `runcell_save_before_run` (boolean): Save the buffer before runcell execution (default `true`).
- `runfile_save_before_run` (boolean): Save the buffer before runfile execution (default `true`).
- `debugfile_save_before_run` (boolean): Save the buffer before `%debugfile` execution (default `true`).
- `debugcell_save_before_run` (boolean): Save the buffer before `%debugcell` execution (default `true`).
- `debugfile_auto_imports` (string): Statements (e.g. `"import numpy as np;import matplotlib.pyplot as plt;"`) that run silently inside the isolated `%debugfile` namespace before `ipdb` starts. 
- `zmq_debug` (boolean): Print ZMQ helper debug logs to stderr.
- `exec_cwd_mode` (string): Working directory behavior for `run_cell` / `run_file`.
  - `'file'`: change directory to the current file's directory before executing
  - `'pwd'`: change directory to Neovim's `getcwd()` (default)
  - `'none'`: do not change directory
- `viewer_max_rows` / `viewer_max_cols` (numbers): DataFrame/ndarray preview limits.
- `ipython_colors` (string|nil): Color scheme applied via IPython's `%colors` magic (e.g., `Linux`, `LightBG`, `NoColor`). Some jupyter-console versions ignore CLI flags; this runtime magic is used for portability.
- `hidden_var_names` (string[]): Variable names to hide in the Variable Explorer (exact match; supports `*` suffix for prefix match). Example: `{ 'pi', 'newaxis' }`.
- `hidden_type_names` (string[]): Type names to hide (exact or prefix with `*`). Examples: `{ 'ZMQInteractiveShell', 'Axes', 'Figure', 'AxesSubplot' }`.
- `autoreload` (1|2|'disable'): Configure IPython's autoreload on console startup. Default `2`.
  - `1`: Reload modules imported with `%aimport`.
  - `2`: Reload all modules automatically (except excluded); recommended default.
  - `'disable'`: Do not configure or enable autoreload.
- `multiline_send_mode` (string): How selections/cells are sent. `'exec'` executes a hex-encoded block via `exec()`; `'paste'`(default) sends a plain-text bracketed paste so the console echoes the code like typed.
- `terminal_keymaps` (function|nil): Extra terminal-mode mappings appended after the defaults when the IPython console buffer opens. Provide a callback `function(set)` where `set(lhs, rhs, opts)` mirrors `vim.keymap.set` (mode/buffer handled automatically). Defaults for the terminal (`<leader>iv`, `<Tab>`, `<C-c>` → interrupt) are created only when `set_default_keymaps` is `true`.


## API

### Setup & state
- `require('ipybridge').setup(opts)` — Configure the plugin.
- `require('ipybridge').apply_default_keymaps()` — Recreate the autocmds, buffer maps, and user commands that ship with ipybridge.
- `require('ipybridge').apply_buffer_keymaps(bufnr)` — Apply the Python buffer mappings to a specific buffer.
- `require('ipybridge').is_open()` — Return `true` when the IPython terminal split is alive.

### Terminal control
- `require('ipybridge').open(go_back)` — Open the terminal. If `go_back` is `true`, jump back to the previous window after initialization.
- `require('ipybridge').close()` — Close the terminal job if running.
- `require('ipybridge').toggle()` — Toggle the IPython terminal split.
- `require('ipybridge').goto_ipy()` — Focus the IPython split and enter insert mode.
- `require('ipybridge').goto_vi()` — Return focus from the IPython split to the previous window.

### Execution helpers
- `require('ipybridge').run_file()` — Run the current file via `%runfile` in IPython.
- `require('ipybridge').debug_file()` — Run the current file in `%debugfile`.
- `require('ipybridge').run_cell()` — Run the current cell and move the cursor to the beginning of the next one.
- `require('ipybridge').debug_cell()` — Debug the current cell via `%debugcell`.
- `require('ipybridge').run_line()` — Send the current line, then move the cursor down.
- `require('ipybridge').run_lines()` — Send the current visual selection (linewise) to IPython.
- `require('ipybridge').send_lines(start_line, end_line)` — Send lines `[start_line, end_line)` by 0-indexed range.
- `require('ipybridge').run_cmd(cmd)` — Send an arbitrary command string.
- `require('ipybridge').up_cell()` / `down_cell()` — Move to the previous/next cell.

### Debugger controls
- `require('ipybridge').debug_step_over()` — Issue `next` inside ipdb.
- `require('ipybridge').debug_step_into()` — Issue `step`.
- `require('ipybridge').debug_step_out()` — Issue `return`.
- `require('ipybridge').debug_continue()` — Resume execution and hide debugger UI.
- `require('ipybridge').quit_debug()` — Exit ipdb and restore the terminal to normal mode.
- `require('ipybridge').toggle_breakpoint()` — Toggle a breakpoint on the current line.
- `require('ipybridge').set_conditional_breakpoint()` — Prompt for a condition before adding a breakpoint.

### Variable explorer & data viewer
- `require('ipybridge').var_explorer_open()` — Open the variable explorer and request the latest snapshot.
- `require('ipybridge').var_explorer_refresh()` — Refresh the explorer (live locals/globals while debugging).
- `require('ipybridge').request_preview(name[, opts])` — Request a preview payload for `name` (used by `:IpybridgePreview`).

### Plot viewer & kernel helpers
- `require('ipybridge').plot_open()` — Open the browser-based plot history.
- `require('ipybridge').plot_next()` / `plot_prev()` — Cycle through captured plots.
- `require('ipybridge').plot_delete()` — Delete the current plot from history.
- `require('ipybridge').plot_clear()` — Clear the entire plot history buffer.
- `require('ipybridge').plot_status()` — Print the current plot index/count.
- `require('ipybridge').interrupt()` — Send an interrupt signal (Ctrl+C equivalent)


## Plot Viewer (Spyder-style)

- Enable with `plot_viewer.mode = "browser"` inside `require("ipybridge").setup({ ... })`. Reopen the page with `<leader>po` or `:IpybridgePlots`.
- The plot pane forces `%matplotlib inline`. Only this backend is captured; switching to `%matplotlib qt` (or any other backend) pauses history until you return to `%matplotlib inline`.
- Use the browser controls or editor shortcuts (`]p`, `[p`, `<leader>pd`, `<leader>pc`, `:IpybridgePlotNext`, `:IpybridgePlotDelete`, etc.) to cycle through history or drop entries.

## Runfile(Spyder-style)
- `run_file()` uses `runfile('<abs_path>', '<cwd>')` to avoid changing the global working directory.

## Runcell(Spyder-style)
- `%debugcell` shares the same helper stack so you can debug the current cell while keeping the console namespace and Spyder-style breakpoints in sync.

## Variable Explorer & Data Viewer

- Requirements: `ipykernel`, `jupyter_client`, `pyzmq` (in the Python environment of the kernel).
- Default keymaps:
  - `<leader>vx` → open variable explorer
  - `<leader>vr` → refresh variables
- Explorer buffer shortcuts:
  - `q` → close, `r` → refresh, `<CR>` → open preview when available (DataFrame/ndarray/dataclass/ctypes or truncated repr)
- Preview window shows DataFrame/ndarray/object summaries; press `r` to refresh, `q` to close. In the viewer, `<CR>` on a dataclass/ctypes field drills down (e.g., `yy.b`, `hh.h2`).

## Debugger

- `<leader>b` toggles a breakpoint.
- The helper pumps the Qt event loop while the debugger waits, so Matplotlib (Qt backends) stays interactive without manual `plt.pause()` calls.
- Default shortcuts:
  - `F6` → launch `%debugfile` for the active buffer
  - `Shift+F6` → exit debug
  - `F10` → `next`
  - `F11` → `step`
  - `Shift+F11` → `return`
  - `F12` → `continue`

## Default Keymaps

### Python buffers
- Normal:
  - `<leader>ti` → toggle IPython terminal
  - `<leader>ii` → focus IPython terminal
  - `<leader>iv` → back to the editor window
  - `<leader><CR>` → run current cell (`# %%` delimited)
  - `<leader>d<CR>` → debug current cell (`# %%` delimited)
  - `F5` → run current file (`%runfile`)
  - `F6` → debug current file (`%debugfile`)
  - `Shift+F6` → exit debugger
  - `<leader>r` → run current line
  - `<leader>b` → toggle debugger breakpoint
  - `<leader>B` → toggle conditional breakpoint
  - `F9` → run current line
  - `F10` → debugger step over
  - `F11` → debugger step into
  - `Shift+F11` → debugger step out
  - `F12` → debugger continue
  - `]c` / `[c` → next/prev cell
  - `<leader>vx` → open variable explorer
  - `<leader>vr` → refresh variables
- Visual:
  - `<leader>r` → run selection
  - `F9` → run selection
  - `]c` / `[c` → next/prev cell

### IPython terminal
- `<Tab>` → trigger debugger completion hints inside `ipdb`
- `<C-c>` → send an interrupt to the kernel
- `<leader>iv` → leave terminal-mode and jump back to the previous window
- `Shift+F6` → exit debugger (`!exit`)
- `F10` → debugger step over
- `F11` → debugger step into
- `Shift+F11` → debugger step out
- `F12` → debugger continue
- `<leader>vx` → open variable explorer

### Global
- `<leader>iv` → back to editor (works anywhere; exits terminal and jumps back)
- `<leader>vx` → open variable explorer from any buffer
- `<leader>vr` → refresh variables from any buffer
- `<leader>po` → open the plot viewer in a browser
- `]p` / `[p` → next/prev stored plot
- `<leader>pd` → delete the current plot snapshot
- `<leader>pc` → clear the plot history

### User Commands
- `:IpybridgeVars` → open variable explorer
- `:IpybridgeVarsRefresh` → refresh variables
- `:IpybridgePreview <name>` → open preview for a variable or path (supports dotted/indexed paths, e.g., `yy.b`, `yy.c`, `hh.h2`, `arr[0]`)
- `:IpybridgeDebugFile` → debug the current file via `%debugfile`
- `:IpybridgeInterrupt` → send an interrupt signal to the connected kernel (Ctrl+C equivalent)
- `:IpybridgePlots` → open the plot viewer (browser UI)
- `:IpybridgePlotNext` → show the next captured plot
- `:IpybridgePlotPrev` → show the previous captured plot
- `:IpybridgePlotDelete` → delete the currently focused plot snapshot
- `:IpybridgePlotClear` → clear all stored plot snapshots
- `:IpybridgePlotStatus` → print the current plot index/count

## Manual Mappings Example
```lua
local ipybridge = require('ipybridge')
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'python',
  callback = function()
    vim.keymap.set('n', '<leader>ti', ipybridge.toggle, { buffer = true })
    vim.keymap.set('n', '<leader>ii', ipybridge.goto_ipy, { buffer = true })
    vim.keymap.set('n', '<leader>iv', ipybridge.goto_vi,  { buffer = true })
    vim.keymap.set('n', '<leader><CR>', ipybridge.run_cell, { buffer = true })
    vim.keymap.set('n', '<F5>', ipybridge.run_file, { buffer = true })
    vim.keymap.set('n', '<F6>', ipybridge.debug_file, { buffer = true })
    vim.keymap.set('n', '<S-F6>', ipybridge.quit_debug, { buffer = true })
    vim.keymap.set('n', '<leader>r', ipybridge.run_line, { buffer = true })
    vim.keymap.set('v', '<leader>r', ipybridge.run_lines, { buffer = true })
    vim.keymap.set('n', '<leader>b', ipybridge.toggle_breakpoint, { buffer = true })
    vim.keymap.set('n', '<leader>B', ipybridge.set_conditional_breakpoint, { buffer = true })
    vim.keymap.set('n', '<F9>', ipybridge.run_line, { buffer = true })
    vim.keymap.set('v', '<F9>', ipybridge.run_lines, { buffer = true })
    vim.keymap.set('n', '<F10>', ipybridge.debug_step_over, { buffer = true })
    vim.keymap.set('n', '<F11>', ipybridge.debug_step_into, { buffer = true })
    vim.keymap.set('n', '<S-F11>', ipybridge.debug_step_out, { buffer = true })
    vim.keymap.set('n', '<F12>', ipybridge.debug_continue, { buffer = true })
    vim.keymap.set('n', ']c', ipybridge.down_cell, { buffer = true })
    vim.keymap.set('n', '[c', ipybridge.up_cell,   { buffer = true })
    vim.keymap.set('v', ']c', ipybridge.down_cell, { buffer = true })
    vim.keymap.set('v', '[c', ipybridge.up_cell,   { buffer = true })
    -- In the terminal buffer, set this (example):
    -- Additional terminal keymaps can be managed via the `terminal_keymaps` option.
  end,
})

-- Example: map key inside the IPython terminal to the interrupt helper.
require('ipybridge').setup({
  terminal_keymaps = function(set)
    local ipy = require('ipybridge')
    set('<C-c>', ipy.interrupt, { desc = 'IPy: Keyboard interrupt' })
    set('<leader>iv', ipy.goto_vi, { desc = 'IPy: Back to editor' })
  end,
})
```
