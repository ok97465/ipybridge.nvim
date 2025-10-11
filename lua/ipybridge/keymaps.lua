-- Keymap helpers for ipybridge.nvim
-- Comments in English; concise and explicit descriptions.

local api = vim.api

local M = {}

-- Apply a set of sensible default keymaps and user commands.
function M.apply_defaults()
  local my = require('ipybridge')
  local group = api.nvim_create_augroup('IpybridgeKeymaps', { clear = true })

  -- Apply Python buffer keymaps
  api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'python',
    callback = function(args)
      M.apply_buffer(args.buf)
    end,
  })

  -- Global: back to editor
  pcall(vim.keymap.set, 'n', '<leader>iv', my.goto_vi, { silent = true, desc = 'IPy: Back to editor' })
  pcall(vim.keymap.set, 't', '<leader>iv', function() my.goto_vi() end, { silent = true, desc = 'IPy: Back to editor' })

  -- Variable explorer commands (global)
  pcall(vim.keymap.set, 'n', '<leader>vx', function() require('ipybridge').var_explorer_open() end, { silent = true, desc = 'IPy: Variable explorer' })
  pcall(vim.keymap.set, 'n', '<leader>vr', function() require('ipybridge').var_explorer_refresh() end, { silent = true, desc = 'IPy: Refresh variables' })

  -- User commands for discoverability
  pcall(api.nvim_create_user_command, 'IpybridgeVars', function() require('ipybridge').var_explorer_open() end, {})
  pcall(api.nvim_create_user_command, 'IpybridgeVarsRefresh', function() require('ipybridge').var_explorer_refresh() end, {})
  pcall(api.nvim_create_user_command, 'IpybridgeDebugFile', function() require('ipybridge').debug_file() end, {})
  pcall(api.nvim_create_user_command, 'IpybridgePreview', function(opts)
    local name = (opts and opts.args) or ''
    if name ~= '' then require('ipybridge').request_preview(name) end
  end, { nargs = 1, complete = 'buffer' })
end

-- Apply buffer-local keymaps for Python files.
function M.apply_buffer(bufnr)
  local my = require('ipybridge')
  local function set(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true, buffer = bufnr })
  end
  -- Toggle terminal
  set('n', '<leader>ti', my.toggle, 'IPy: Toggle terminal')
  -- Jump to IPython / back to editor
  set('n', '<leader>ii', my.goto_ipy, 'IPy: Focus terminal')
  set('n', '<leader>iv', my.goto_vi,  'IPy: Back to editor')
  -- Run current cell
  set('n', '<leader><CR>', my.run_cell, 'IPy: Run cell')
  -- Run current file
  set('n', '<F5>', my.run_file, 'IPy: Run file (%run)')
  set('n', '<F6>', my.debug_file, 'IPy: Debug file (%debugfile)')
  -- Run current line (normal) / selection (visual)
  set('n', '<leader>r', my.run_line, 'IPy: Run line')
  set('v', '<leader>r', my.run_lines, 'IPy: Run selection')
  -- Toggle debugger breakpoint at cursor
  set('n', '<leader>b', my.toggle_breakpoint, 'IPy: Toggle breakpoint')
  -- F9 as alternative for line/selection
  set('n', '<F9>', my.run_line, 'IPy: Run line (F9)')
  set('v', '<F9>', my.run_lines, 'IPy: Run selection (F9)')
  -- Debugger stepping helpers
  set('n', '<F10>', my.debug_step_over, 'IPy: Debug step over (F10)')
  set('n', '<F11>', my.debug_step_into, 'IPy: Debug step into (F11)')
  set('n', '<F12>', my.debug_continue, 'IPy: Debug continue (F12)')
  -- Cell navigation in normal and visual modes
  set('n', ']c', my.down_cell, 'IPy: Next cell')
  set('n', '[c', my.up_cell,  'IPy: Prev cell')
  set('v', ']c', my.down_cell, 'IPy: Next cell (visual)')
  set('v', '[c', my.up_cell,  'IPy: Prev cell (visual)')
  -- Variable explorer and refresh
  set('n', '<leader>vx', function() my.var_explorer_open() end, 'IPy: Variable explorer')
  set('n', '<leader>vr', function() my.var_explorer_refresh() end, 'IPy: Refresh variables')
end

return M
