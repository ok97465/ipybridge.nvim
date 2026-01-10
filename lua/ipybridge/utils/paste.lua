-- Bracketed paste helpers for ipybridge terminal interactions.

local platform = require("ipybridge.utils.platform")

local M = {}

---Build a bracketed-paste payload for multiline selections.
---@param lines_tbl string[]
---@return string
function M.paste_block(lines_tbl)
	if not lines_tbl or #lines_tbl == 0 then
		return ""
	end
	local separator = platform.line_separator()
	local body = table.concat(lines_tbl, separator)
	return "\x1b[200~" .. body .. "\n\x1b[201~"
end

return M
