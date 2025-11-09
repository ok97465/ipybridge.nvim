local blink = require("ipybridge.cmp_bridge.blink")
local env = require("ipybridge.cmp_bridge.env")
local completion_apply = require("ipybridge.cmp_bridge.completion_apply")
local source_common = require("ipybridge.cmp_bridge.sources.common")

local BlinkSource = {}
BlinkSource.__index = BlinkSource

local function blink_empty_response()
	return {
		items = {},
		is_incomplete_backward = false,
		is_incomplete_forward = false,
	}
end

local function blink_request_context(ctx)
	local cursor = (ctx and ctx.cursor) or { 1, 0 }
	local row = tonumber(cursor[1]) or 1
	local col = tonumber(cursor[2]) or 0
	local line = ctx and ctx.line or ""
	if col < 0 then
		col = 0
	end
	local line_len = #line
	if col > line_len then
		col = line_len
	end
	local before = line:sub(1, col)
	local after = line:sub(col + 1)
	return {
		cursor_before_line = before,
		cursor_after_line = after,
		cursor = {
			line = row - 1,
			col = col,
		},
	}
end

local function close_menu_when_empty(items, incomplete)
	if incomplete or (#items > 0) then
		return
	end
	local blink_mod = blink.module()
	if blink_mod and type(blink_mod.hide) == "function" then
		blink_mod.hide()
	end
end

function BlinkSource.new()
	return setmetatable({}, BlinkSource)
end

function BlinkSource:enabled()
	local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
	if not ok_buf then
		return false
	end
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "terminal" then
		return false
	end
	if not env.is_ipybridge_terminal(buf) then
		return false
	end
	return env.is_debug_session()
end

function BlinkSource:get_completions(ctx, callback)
	if not env.is_debug_session() then
		callback(blink_empty_response())
		close_menu_when_empty({}, false)
		return
	end
	local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	if not env.is_ipybridge_terminal(bufnr) then
		callback(blink_empty_response())
		return
	end
	local request_ctx = blink_request_context(ctx or {})
	source_common.stream({
		request_context = request_ctx,
		dispatch_opts = { mode = "delta" },
		on_result = function(result)
			callback({
				items = result.items,
				is_incomplete_backward = false,
				is_incomplete_forward = result.isIncomplete,
			})
		end,
		on_empty = function()
			close_menu_when_empty({}, false)
		end,
	})
end

function BlinkSource:execute(ctx, item, callback) -- luacheck: no unused args
	if not env.is_active_ipy_terminal() then
		if type(callback) == "function" then
			callback()
		end
		return
	end
	local metadata = item and item.data and item.data.__ipybridge or {}
	local cursor_col = metadata.cursor_col
	if cursor_col == nil and ctx and ctx.cursor then
		cursor_col = tonumber(ctx.cursor[2]) or 0
	end
	cursor_col = cursor_col or 0
	local cursor_col_start = metadata.cursor_col_start or cursor_col
	local request = completion_apply.prepare({
		item = item or {},
		context = {
			cursor_col = cursor_col,
			cursor_col_start = cursor_col_start,
		},
	})
	completion_apply.commit(request, {
		after_feed = function()
			if type(callback) == "function" then
				callback()
			end
		end,
	})
end

return BlinkSource
