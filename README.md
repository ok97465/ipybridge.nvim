# ipybridge.nvim

Minimal helper to run IPython/Jupyter in a terminal split and send code from the current buffer, tuned for Neovim 0.11+.

## Demo

`demo` captures the day-to-day workflow: Neovim buffers on the left, the IPython console on the right. Cells run with `runfile()`/`runcell()` helpers, and the console echoes section markers so you can see each phase finish. While the script executes, a preview overlay lists numpy arrays, dataclasses, and ctypes structures so you can drill into live data without leaving the editor.

![demo gif](https://github.com/ok97465/ipybridge.nvim/raw/main/doc/demo.gif)

`demo_debug` dives into the debugger integration:

- Debug sessions run through IPython's `debugfile`, so this plugin natively supports step-by-step debugging.
- Breakpoints you toggle in Neovim are respected; the gutter indicator in the GIF shows the active stop line.
- Matplotlib stays interactive even while the debugger pauses execution, letting you pan and zoom figures mid-inspection.
- The variable explorer stays in sync with the paused frame, making it easy to examine arrays and custom structures.
- Completions inside `ipdb` come from your completion engine (`nvim-cmp` or `blink.cmp`), giving you the same rich suggestions you rely on during normal editing.

![demo debugger gif](https://github.com/ok97465/ipybridge.nvim/raw/main/doc/demo_debug.gif)

## Requirements

- Neovim 0.11 or newer
- Completion engine: [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) or [`blink.cmp`](https://github.com/Saghen/blink.cmp). ipybridge auto-detects whichever is available (defaults to nvim-cmp when both are installed, but you can reorder via `completion.engine_priority`).
- Python with Jupyter/IPython
  - `jupyter` (for `jupyter console`)
  - `ipykernel`, `jupyter_client`, `pyzmq` (for variable explorer / preview)
  - `ipython` (for the console experience)

## Debugger Completion Engines

ipybridge streams ipdb suggestions into whichever completion engine you use in the terminal window.

- **nvim-cmp** – ipybridge ships the `ipybridge_debug_hint` source. Include it in the sources you enable for terminal buffers (ipybridge also registers it automatically when the debugger starts). Example:

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
    engine_priority = { "blink.cmp", "nvim-cmp" }, -- prefer blink when both are present
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
- `startup_script` (string): If this file exists under current working directory, `ipython -i <startup_script>` is used; otherwise the plugin sends a minimal set of numeric imports automatically.
- `sleep_ms_after_open` (number): Milliseconds to wait (non-blocking) before running initial setup such as `%matplotlib` or `%load_ext autoreload`.
- `set_default_keymaps` (boolean, default: `true`): Apply buffer-local keymaps for Python files only.

### Additional options

- `matplotlib_backend` (string|nil): `qt`, `inline`, `macosx`, `tk`, `agg`
- `plot_viewer` (table): configure Spyder-style history. Fields: `mode = "browser"|"off"`, `auto_open`, and `history` (snapshot cap). `auto_open = true` starts by forcing `%matplotlib inline`.
- `runcell_save_before_run` (boolean): Save the buffer before runcell execution (default `true`).
- `runfile_save_before_run` (boolean): Save the buffer before runfile execution (default `true`).
- `debugfile_save_before_run` (boolean): Save the buffer before `%debugfile` execution (default `true`).
- `debugcell_save_before_run` (boolean): Save the buffer before `%debugcell` execution (default `true`).
- `exec_cwd_mode` (string): Working directory behavior for `run_cell` / `run_file`.
  - `'file'`: change directory to the current file's directory before executing
  - `'pwd'`: change directory to Neovim's `getcwd()` (default)
  - `'none'`: do not change directory
- `viewer_max_rows` / `viewer_max_cols` (numbers): DataFrame/ndarray preview limits.
- `simple_prompt` (boolean): Use simplified prompt in Jupyter console. Defaults to `false` for richer colors/UI.
- `ipython_colors` (string|nil): Color scheme applied via IPython's `%colors` magic (e.g., `Linux`, `LightBG`, `NoColor`). Some jupyter-console versions ignore CLI flags; this runtime magic is used for portability.
- `hidden_var_names` (string[]): Variable names to hide in the Variable Explorer (exact match; supports `*` suffix for prefix match). Example: `{ 'pi', 'newaxis' }`.
- `hidden_type_names` (string[]): Type names to hide (exact or prefix with `*`). Examples: `{ 'ZMQInteractiveShell', 'Axes', 'Figure', 'AxesSubplot' }`.
- `autoreload` (1|2|'disable'): Configure IPython's autoreload on console startup. Default `2`.
  - `1`: Reload modules imported with `%aimport`.
  - `2`: Reload all modules automatically (except excluded); recommended default.
  - `'disable'`: Do not configure or enable autoreload.
- `multiline_send_mode` (string): How selections/cells are sent. `'exec'` executes a hex-encoded block via `exec()`; `'paste'`(default) sends a plain-text bracketed paste so the console echoes the code like typed.
- `terminal_keymaps` (function|nil): Extra terminal-mode mappings appended after the defaults when the IPython console buffer opens. Provide a callback `function(set)` where `set(lhs, rhs, opts)` mirrors `vim.keymap.set` (mode/buffer handled automatically). Defaults for the terminal (`<leader>iv`, `<Tab>`, `<C-c>` → interrupt) are created only when `set_default_keymaps` is `true`.

## Cell Syntax

- Lines beginning with `# %%` (one or more `%`) mark cell boundaries.
- A “cell” runs from the most recent `# %%` (or file start) up to the line before the next `# %%` (or file end).

### Debugging

- `<leader>b` toggles a persistent breakpoint sign at the cursor and sends the updated list to the IPython debugger.
- `%debugfile <path> [cwd]` mirrors Spyder's helper and runs the current file under an IPython `Pdb` instance.
- The helper pumps the Qt event loop while the debugger waits, so Matplotlib (Qt backends) stays interactive without manual `plt.pause()` calls.
- Default shortcuts:
  - `F6` → launch `%debugfile` for the active buffer (uses `exec_cwd_mode` to set the working directory)
  - `F10` → `next`
  - `F11` → `step`
  - `Shift+F11` → `return`
  - `F12` → `continue`
- `%debugfile` becomes available automatically once the console starts; no manual `%load_ext` needed.

## API

- `require('ipybridge').setup(opts)` — Configure the plugin.
- `require('ipybridge').toggle()` — Toggle the IPython terminal split.
- `require('ipybridge').open(go_back)` — Open the terminal. If `go_back` is `true`, jump back to the previous window after initialization.
- `require('ipybridge').close()` — Close the terminal job if running.
- `require('ipybridge').goto_ipy()` — Focus the IPython split and enter insert mode.
- `require('ipybridge').goto_vi()` — Return focus from the IPython split to the previous window.
- `require('ipybridge').run_file()` — Run the current file via `%run <filebase>` in IPython.
- `require('ipybridge').run_line()` — Send the current line, then move the cursor down.
- `require('ipybridge').run_lines()` — Send the current visual selection (linewise) to IPython.
- `require('ipybridge').send_lines(start_line, end_line)` — Send lines `[start_line, end_line)` by 0-indexed range.
- `require('ipybridge').run_cmd(cmd)` — Send an arbitrary command string.
- `require('ipybridge').run_cell()` — Run the current cell and move the cursor to the beginning of the next one.
- `require('ipybridge').up_cell()` / `down_cell()` — Move to the previous/next cell.

## Notes

- On open, the plugin starts a Jupyter kernel and attaches a `jupyter console --existing` in a `botright vsplit`.
- Matplotlib: if configured, the backend is set via `%matplotlib`, and the debugger keeps Qt windows responsive by processing events in the background.
- If `startup_script` exists in the current working directory, it is executed in the console; otherwise minimal numeric imports are sent.
- Multi-line sending mode is configurable:
  - Default is `'exec'` which hex-encodes the selection and executes it via `exec()` (robust; minimal echo).
  - Set `multiline_send_mode = 'paste'` to send plain text using bracketed paste (ESC[200~ ... ESC[201~) so IPython shows the exact code as if it was typed (similar to Spyder).
- Cell detection uses a `# %%`-style marker and is implemented with `vim.regex` and `vim.iter` (Neovim 0.11+ APIs) for clarity and performance.
- When `set_default_keymaps` is enabled, keymaps are also applied to already-open Python buffers at startup.

## Matplotlib Backend / GUI Windows

- Set `matplotlib_backend` to a value accepted by `%matplotlib` (e.g. `'qt'`, `'inline'`, `'macosx'`, `'tk'`, `'agg'`).
- Qt requires `PyQt5` or `PySide6`. Tk requires Tk support. macOS may require framework build Python.
- The browser plot viewer (when enabled) forces `%matplotlib inline` internally so snapshots are deterministic; switch back to `%matplotlib inline` whenever you want the history pane to resume recording.

## Plot Viewer (Spyder-style History)

- Enable with `plot_viewer.mode = "browser"` inside `require("ipybridge").setup({ ... })`. The kernel bootstrap spins up a localhost HTTP + SSE server, Neovim grabs the URL via OSC, and (when `auto_open = true`) your default browser opens automatically. Reopen the page with `<leader>po` or `:IpybridgePlots`.
- The plot pane forces `%matplotlib inline`. Only this backend is captured; switching to `%matplotlib qt` (or any other backend) pauses history until you return to `%matplotlib inline`.
- Every `plt.show()` / `plt.savefig()` call snapshots the active figures via `FigureCanvasAgg`, stores up to `history` PNGs, and streams `plot-added`, `plot-removed`, and `plot-selected` events to the browser UI so thumbnails stay in sync without polling.
- Use the browser controls or editor shortcuts (`]p`, `[p`, `<leader>pd`, `<leader>pc`, `:IpybridgePlotNext`, `:IpybridgePlotDelete`, etc.) to cycle through history or drop entries. Neovim keymaps talk to the same runtime over ZMQ, so they keep working even when the tab is in the background.
- Neovim automatically refreshes the viewer status via ZMQ right after startup, so `<leader>po`/`:IpybridgePlots` can open the browser even before any console output occurs.
- The browser UI keeps previews on the right-hand pane while a narrow thumbnail rail (no timestamps or figure numbers) stays on the left, making it easy to focus on the active figure.
- Switching away from `%matplotlib inline` (for example `%matplotlib qt`) automatically pauses snapshots; the viewer badge turns red and shows “paused”. Run `%matplotlib inline` to resume recording.

## Spyder-like Runcell

- The helper defines `runcell(index, path, cwd=None)` and a `%runcell` line magic. Cells are delimited by lines matching `^# %%+`.
- The plugin computes the current cell index (0-based) and calls `runcell(index, <current file path>, <cwd according to exec_cwd_mode>)`.
- If `runcell_save_before_run = true` (default), the buffer is saved first to ensure the helper runs the latest contents.
- If the buffer is unsaved or the file path is missing, the plugin falls back to sending the cell text directly.
- `%debugcell` shares the same helper stack so you can debug the current cell while keeping the console namespace and Spyder-style breakpoints in sync. The buffer must also be saved (controlled via `debugcell_save_before_run`).

## Runfile Magic
- The helper also defines `runfile(path, cwd=None)` and registers `%runfile`.
- `run_file()` uses `runfile('<abs_path>', '<cwd>')` to avoid changing the global working directory.

## Variable Explorer & Data Viewer (ZMQ)
- Open the variable explorer and request current variables from the kernel over a lightweight ZMQ backend.
- Requirements: `ipykernel`, `jupyter_client`, `pyzmq` (in the Python environment of the kernel).
- Default keymaps:
  - `<leader>vx` → open variable explorer
  - `<leader>vr` → refresh variables
- Explorer buffer shortcuts:
  - `q` → close, `r` → refresh, `<CR>` → open preview when available (DataFrame/ndarray/dataclass/ctypes or truncated repr)
- Preview window shows DataFrame/ndarray/object summaries; press `r` to refresh, `q` to close. In the viewer, `<CR>` on a dataclass/ctypes field drills down (e.g., `yy.b`, `hh.h2`).

## Default Keymaps (Python buffers only)
- Normal:
  - `<leader>ti` → toggle IPython terminal
  - `<leader>ii` → focus IPython terminal
  - `<leader><CR>` → run current cell (`# %%` delimited)
  - `<leader>d<CR>` → debug current cell (`# %%` delimited)
  - `F5` → run current file (`%run`)
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
  - `<leader>vx` → variable explorer (global command also available)
  - `<leader>vr` → refresh variables
- Visual:
  - `<leader>r` → run selection
  - `F9` → run selection
  - `]c` / `[c` → next/prev cell

### Global
- Normal/Terminal:
  - `<leader>iv` → back to editor (works anywhere; exits terminal and jumps back)

### User Commands
- `:IpybridgeVars` → open variable explorer
- `:IpybridgeVarsRefresh` → refresh variables
- `:IpybridgeDebugFile` → debug the current file via `%debugfile`
- `:IpybridgeInterrupt` → send an interrupt signal to the connected kernel (Ctrl+C equivalent)
- `:IpybridgePreview <name>` → open preview for a variable or path (supports dotted/indexed paths, e.g., `yy.b`, `yy.c`, `hh.h2`, `arr[0]`)

### Terminal Buffers
- Terminal mode:
  - `<leader>iv` → back to editor (works in any terminal buffer)

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

## Troubleshooting
- Ensure `ipython` is installed and discoverable in your environment.
- For variable explorer and preview, ensure `ipykernel`, `jupyter_client`, and `pyzmq` are installed in the kernel’s environment.
- If the split opens but does not accept input, check your terminal integration or try a different shell.
- Windows console sequences are handled, but some terminals may require different escape behavior.

## Developer Notes
- Modules and responsibilities:
  - `lua/ipybridge/init.lua`: public API and orchestration of features.
  - `lua/ipybridge/term_ipy.lua`: terminal split wrapper (open/send/scroll/cleanup).
  - `lua/ipybridge/utils.lua`: small utilities (quoting, selection range, exec helpers).
  - `lua/ipybridge/keymaps.lua`: default keymaps and user commands.
  - `lua/ipybridge/kernel.lua`: standalone ipykernel lifecycle and connection file.
  - `lua/ipybridge/zmq_client.lua`: NDJSON ZMQ bridge to the kernel (vars/preview).
  - `lua/ipybridge/dispatch.lua`: routes decoded messages to UI modules.
  - `lua/ipybridge/var_explorer.lua`: variable explorer floating window.
  - `lua/ipybridge/data_viewer.lua`: preview window for arrays/dataframes/objects.
  - `lua/ipybridge/exec_magics.lua`: IPython runcell/runfile execution magics.
- Public API remains the same; internals are split for readability and maintenance.
