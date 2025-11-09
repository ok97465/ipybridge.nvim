-- Utilities for turning LSP-style completion items into terminal edits.
-- Computes spans relative to the prompt and injects keystrokes into the REPL.
local env = require("ipybridge.cmp_bridge.env")

local M = {}

local function normalize_columns(context)
	local cursor_col = tonumber(context.cursor_col) or 0
	local cursor_col_start = context.cursor_col_start
	if cursor_col_start == nil then
		local token = context.token
		if type(token) == "string" and #token > 0 then
			cursor_col_start = cursor_col - #token
		else
			cursor_col_start = cursor_col
		end
	end
	if cursor_col_start < 0 then
		cursor_col_start = 0
	end
	return cursor_col, cursor_col_start
end

---Compute the span and replacement text for a completion item.
---@param opts table
---@return table
function M.prepare(opts)
	opts = opts or {}
	local item = opts.item or {}
	local context = opts.context or {}
	local cursor_col, cursor_col_start = normalize_columns(context)
	local text_edit = item.textEdit
	local span = 0
	if text_edit and text_edit.range then
		local range = text_edit.range
		local start_info = range.start or {}
		local end_info = range["end"] or {}
		local start_char = tonumber(start_info.character) or cursor_col_start
		local end_char = tonumber(end_info.character) or cursor_col
		if end_char < start_char then
			end_char = start_char
		end
		span = end_char - start_char
	else
		span = cursor_col - cursor_col_start
		if span < 0 then
			span = 0
		end
	end
	local text = (text_edit and text_edit.newText) or item.insertText or item.label or ""
	return {
		span = span,
		text = text,
	}
end

---Apply the prepared completion to the active terminal buffer.
---@param request table
---@param opts table|nil
function M.commit(request, opts)
	opts = opts or {}
	request = request or {}
	local span = tonumber(request.span) or 0
	local text = request.text or ""
	local before_feed = opts.before_feed
	local after_feed = opts.after_feed or opts.callback
	vim.schedule(function()
		if type(before_feed) == "function" then
			before_feed()
		end
		if span > 0 then
			env.feed_terminal(string.rep("<BS>", span))
		end
		if type(text) == "string" and text ~= "" then
			env.feed_terminal(text)
		end
		if type(after_feed) == "function" then
			after_feed()
		end
	end)
end

return M
