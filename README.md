# my_ipy.nvim

Minimal helper to run IPython in a terminal split and send code from the current buffer, tuned for Neovim 0.11+.

Requirements
- Neovim 0.11 or newer
- Python with IPython available on `PATH` (`ipython` command)

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
      })
    end,
  }
  ```

Configuration
- `profile_name` (string|nil): IPython profile passed as `--profile=<name>`. If `nil`, the flag is omitted.
- `startup_script` (string): If this file exists under current working directory, `ipython -i <startup_script>` is used.
- `startup_cmd` (string): Fallback command string sent to `ipython -c` when `startup_script` is missing.
- `sleep_ms_after_open` (number): Milliseconds to wait (non-blocking) before running initial setup such as `plt.ion()`.
- `set_default_keymaps` (boolean, default: `true`): Apply buffer-local keymaps for Python files only.

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
- On open, the plugin launches `ipython -i` in a `botright vsplit` and sends `plt.ion()` after a short deferred delay.
- If `startup_script` exists in the current working directory, it is used; otherwise `startup_cmd` is used with `ipython -c`.
- Multi-line sending uses bracketed paste sequences (ESC[200~ ... ESC[201~) for reliable block input across terminals.
- Cell detection uses a `# %%`-style marker and is implemented with `vim.regex` and `vim.iter` (Neovim 0.11+ APIs) for clarity and performance.
- When `set_default_keymaps` is enabled, keymaps are also applied to already-open Python buffers at startup.

Default Keymaps (Python buffers only)
- Normal:
  - `<leader>ti` → toggle IPython terminal
  - `<leader>ii` → focus IPython terminal
  - `<leader><CR>` → run current cell (`# %%` delimited)
  - `F5` → run current file (`%run`)
  - `<leader>r` → run current line
  - `F9` → run current line
  - `]c` / `[c` → next/prev cell
- Visual:
  - `<leader>r` → run selection
  - `F9` → run selection
  - `]c` / `[c` → next/prev cell

Global
- Normal/Terminal:
  - `<leader>iv` → back to editor (works anywhere; exits terminal and jumps back)

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
- If the split opens but does not accept input, check your terminal integration or try a different shell.
- Windows console sequences are handled, but some terminals may require different escape behavior.
