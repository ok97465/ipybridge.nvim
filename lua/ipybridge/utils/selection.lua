-- Selection helpers for ipybridge.
-- Provides selection range utilities for visual mode.

local M = {}

---Return a 0-indexed (start_row, end_row_exclusive) range for visual selections.
---Uses getpos('v') so visual-mode mappings behave consistently.
---@return integer|nil, integer|nil
function M.selection_line_range()
	local api = vim.api
	local fn = vim.fn
	local mode = fn.mode()
	-- Visual modes: 'v' (charwise), 'V' (linewise), CTRL-V (blockwise).
	-- Use string.char(22) to match blockwise visual without escape ambiguity.
	if mode == "v" or mode == "V" or mode == string.char(22) then
		local vpos = fn.getpos("v")
		local cpos = fn.getpos(".")
		local srow = vpos[2]
		local erow = cpos[2]
		if srow > erow then
			srow, erow = erow, srow
		end
		return srow - 1, erow -- end is exclusive when passed to nvim_buf_get_lines
	end
	-- Fallback when not in visual: use the last visual marks ('<' and '>').
	local srow = (api.nvim_buf_get_mark(0, "<") or { 0, 0 })[1]
	local erow = (api.nvim_buf_get_mark(0, ">") or { 0, 0 })[1]
	if srow == 0 or erow == 0 then
		return nil
	end
	if srow > erow then
		srow, erow = erow, srow
	end
	return srow - 1, erow
end

return M
