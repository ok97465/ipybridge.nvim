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

local M = { term_instance = nil }
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
}

-- Fast file existence check using libuv.
local function file_exists(path)
  return uv.fs_stat(path) and true or false
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

M.setup = function(config)
    if config ~= nil then
        vim.validate({
            profile_name = { config.profile_name, 's', true },
            startup_script = { config.startup_script, 's', true },
            startup_cmd = { config.startup_cmd, 's', true },
            sleep_ms_after_open = { config.sleep_ms_after_open, 'n', true },
            set_default_keymaps = { config.set_default_keymaps, 'b', true },
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
end

---Return whether the IPython terminal is currently open.
---@return boolean
M.is_open = function()
    return M.term_instance ~= nil and M.term_instance.job_id ~= nil
end

---Open the IPython terminal split.
---@param go_back boolean|nil # if true, jump back to previous window after init
M.open = function(go_back)
    local cwd = fn.getcwd()
    local path_startup_script = fs.joinpath(cwd, M.config.startup_script)
	local cmd_ipy = "ipython -i "
	local profile = " --profile=" .. M.config.profile_name

	if M.config.profile_name == nil then
		profile = ""
	end

	if file_exists(path_startup_script) then
		cmd_ipy = cmd_ipy .. path_startup_script
	else
		cmd_ipy = cmd_ipy .. "-c " .. M.config.startup_cmd
	end

	cmd_ipy = cmd_ipy .. profile

	M.term_instance = term_helper.TermIpy:new(cmd_ipy, cwd)

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
		M.term_instance:send("plt.ion()\n")
		M.term_instance:scroll_to_bottom()
		if go_back == true then
			vim.cmd("wincmd p")
		end
	end, M.config.sleep_ms_after_open)
end

---Close the IPython terminal if running.
M.close = function()
	if M.is_open() then
		fn.jobstop(M.term_instance.job_id)
	end
end

---Toggle the IPython terminal split.
M.toggle = function()
	if M.is_open() then
		M.close()
	else
		M.open(false)
		M.term_instance:startinsert()
	end
end

---Jump to the IPython terminal split and enter insert mode.
M.goto_ipy = function()
	if api.nvim_win_get_buf(0) == M.term_instance.buf_id then
		return
	end
	if not M.is_open() then
		M.open(false)
	end
	M.term_instance:show()
	api.nvim_set_current_win(M.term_instance.win_id)
	M.term_instance:scroll_to_bottom()
	M.term_instance:startinsert()
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
	local rel_path = fn.expand("%:r")
	if not M.is_open() then
		M.open(true)
	end
	M.term_instance:send("%run " .. rel_path .. "\n")
end

---Send lines [line_start, line_stop) to IPython.
---@param line_start integer
---@param line_stop integer
M.send_lines = function(line_start, line_stop)
	local tb_lines = api.nvim_buf_get_lines(0, line_start, line_stop, false)
	if not tb_lines or #tb_lines == 0 then return end

	if not M.is_open() then
		M.open(true)
	end

	M.term_instance:send(paste_block(tb_lines))
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

	if not M.is_open() then
		M.open(true)
	end

	M.term_instance:send(line .. "\n")
	if idx_line_cursor < n_lines then
		api.nvim_win_set_cursor(0, { idx_line_cursor + 1, 0 })
	end
end

---Send an arbitrary command string to IPython.
---@param cmd string
M.run_cmd = function(cmd)
	if not M.is_open() then
		M.open(true)
	end

	M.term_instance:send(cmd .. "\n")
end

---Run the current cell delimited by lines starting with "# %%".
M.run_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	-- Compute exclusive end correctly: include last line when no next cell exists.
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
