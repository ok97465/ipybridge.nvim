-- For my private ipython command.
local vim = vim
local api = vim.api
local fn = vim.fn
local Path = require("plenary.path")
local term_helper = require("my_ipy.term_ipy")

local M = {term_instance=nil}
local CELL_PATTERN = "^# %%+"
local char_for_adding_line = "\x0F\x1b\x4f\x42"
if vim.loop.os_uname().version:match('Windows') then
    char_for_adding_line = "\x0F\x1B[B"
end

M.config = {
	profile_name="vim",
	startup_script = "import_in_console.py",
	startup_cmd = "\"import numpy as np\n"..
    "from scipy.special import sindg, cosdg, tandg\n"..
    "from numpy import (\n"..
    "pi, deg2rad, rad2deg, unwrap, angle, zeros, array, ones, linspace, cumsum,\n"..
    "diff, arange, interp, conj, exp, sqrt, vstack, hstack, dot, cross, newaxis)\n"..
    "from numpy import cos, sin, tan, arcsin, arccos, arctan\n"..
    "from numpy import amin, amax, argmin, argmax, mean\n"..
    "from numpy.linalg import svd, norm\n"..
    "from numpy.fft import fftshift, ifftshift, fft, ifft, fft2, ifft2\n"..
    "from numpy.random import randn, standard_normal, randint, choice, uniform\n\"",
	sleep_ms_after_open = 1000
}

local function isfile(name)
   local f=io.open(name,"r")
   if f~=nil then io.close(f) return true else return false end
end

local function sleep_ms(ms)
    local start_sleep = os.clock()
    local sec = ms / 1000
    while os.clock() - start_sleep <= sec do
    end
end

local function visual_selection_range()
  local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
  local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))
  if csrow < cerow or (csrow == cerow and cscol <= cecol) then
    return csrow - 1, cscol - 1, cerow - 1, cecol
  else
    return cerow - 1, cecol - 1, csrow - 1, cscol
  end
end

local function get_start_line_cell(idx_seed)
	local lines = api.nvim_buf_get_lines(0, 0, idx_seed, false)
	local pos_cell_start, pos_cell_stop

	for idx = #lines, 1, -1 do
		pos_cell_start, pos_cell_stop = lines[idx]:find(CELL_PATTERN)
		if pos_cell_stop then
			return idx
		end
	end
	return 1
end

---현재 Cell의 마지막 Line을 반환하고 다음 cell이 있을 경우 true를 반환한다.
---@param idx_offset number
---@return number, boolean
local function get_stop_line_cell(idx_offset)
	local n_lines = api.nvim_buf_line_count(0)
	local lines = api.nvim_buf_get_lines(0, idx_offset - 1, n_lines, false)
	local pos_cell_start, pos_cell_stop

	for idx = 1, #lines do
		pos_cell_start, pos_cell_stop = lines[idx]:find(CELL_PATTERN)
		if pos_cell_stop then
			return idx + idx_offset - 1, true
		end
	end
	return n_lines, false
end

---Combine arguments into strings separated by new lines
---@vararg string
---@return string
local function with_cr(...)
  local result = {}
  for _, str in ipairs({ ... }) do
	table.insert(result, str .. char_for_adding_line)
  end
  return table.concat(result, "")
end

M.setup = function(config)
	M.config = vim.tbl_deep_extend("force", M.config, config or {})
end

M.is_open = function ()
	return M.term_instance and M.term_instance.job_id
end

M.open = function(go_back)
	local cwd = fn.getcwd()
    local path_startup_script = cwd .. Path.path.sep .. M.config.startup_script
	local cmd_ipy= "ipython -i "
	local profile = " --profile=" .. M.config.profile_name

	if M.config.profile_name == nil then
		profile = ""
	end

	if isfile(path_startup_script) then
		cmd_ipy = cmd_ipy .. path_startup_script
	else
		cmd_ipy = cmd_ipy .. "-c " .. M.config.startup_cmd
	end

	cmd_ipy = cmd_ipy .. profile

	M.term_instance = term_helper.TermIpy:new(cmd_ipy, cwd)
	sleep_ms(M.config.sleep_ms_after_open)
	M.term_instance:scroll_to_bottom()
	if go_back == true then
		vim.cmd("wincmd p")
	end
end

M.close = function()
	if M.is_open() then
		fn.jobstop(M.term_instance.job_id)
	end
end

M.toggle = function()
	if M.is_open() then
		M.close()
	else
		M.open(false)
		M.term_instance:startinsert()
	end
end

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

M.goto_vi = function()
	if api.nvim_win_get_buf(0) == M.term_instance.buf_id then
		M.term_instance:stopinsert()
		-- api.nvim_feedkeys("G", "n", true)
		-- local key1 = api.nvim_replace_termcodes("<C-\\>", true, false, true)
		-- local key2 = api.nvim_replace_termcodes("<C-n>", true, false, true)
		-- api.nvim_feedkeys(key1, "n", true)
		-- api.nvim_feedkeys(key2, "n", true)
		-- api.nvim_feedkeys("G", "n", true)
		vim.cmd("wincmd p")
	end
end

M.run_file = function()
	local rel_path = fn.expand("%:r")
	if not M.is_open() then
		M.open(true)
	end
	M.term_instance:send("%run " .. rel_path .. "\n")
end

M.send_lines = function(line_start, line_stop)
	local tb_lines = api.nvim_buf_get_lines(0, line_start, line_stop, false)
	local lines = with_cr(unpack(tb_lines))

	if not M.is_open() then
		M.open(true)
	end

	M.term_instance:send(lines:sub(1, -4) .. "\n\n")
end

M.run_lines = function()
	local line_start, _, line_end, _ = visual_selection_range()

	if not line_start then
		return
	end

	M.send_lines(line_start, line_end + 1)
end

M.run_line = function()
	local n_lines = api.nvim_buf_line_count(0)
	local line = api.nvim_get_current_line()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]

	if not M.is_open() then
		M.open(true)
	end

	M.term_instance:send(line .. "\n")
	if idx_line_cursor < n_lines then
		api.nvim_win_set_cursor(0, {idx_line_cursor + 1, 0})
	end
end

M.run_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor)
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	M.send_lines(line_start - 1, line_stop - 1)

	if has_next_cell then
		local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
		api.nvim_win_set_cursor(0, {idx_line, 0})
	end
end

M.up_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_start = get_start_line_cell(idx_line_cursor - 2)

	local idx_line = math.min(line_start + 1, api.nvim_buf_line_count(0))
	api.nvim_win_set_cursor(0, {idx_line, 0})
end

M.down_cell = function()
	local idx_line_cursor = api.nvim_win_get_cursor(0)[1]
	local line_stop, has_next_cell = get_stop_line_cell(idx_line_cursor + 1)

	if has_next_cell then
		local idx_line = math.min(line_stop + 1, api.nvim_buf_line_count(0))
		api.nvim_win_set_cursor(0, {idx_line, 0})
	end
end

return M