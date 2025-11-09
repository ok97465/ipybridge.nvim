local debug_completion = require("ipybridge.debug.completion")
local env = require("ipybridge.cmp_bridge.env")

---@class CompletionProvider
---@field name string
---@field fetch fun(self, context: table, emit: CompletionEmitter)

---@class CompletionEmitter
---@field append fun(self, items: table)
---@field done fun(self)

local M = {}

local providers = {}
local cmp_kinds_cache = nil

local ipdb_commands = {
	"help",
	"h",
	"list",
	"l",
	"longlist",
	"ll",
	"where",
	"w",
	"continue",
	"cont",
	"c",
	"next",
	"n",
	"step",
	"s",
	"return",
	"ret",
	"until",
	"unt",
	"jump",
	"j",
	"up",
	"u",
	"down",
	"d",
	"break",
	"b",
	"tbreak",
	"clear",
	"disable",
	"enable",
	"ignore",
	"commands",
	"alias",
	"unalias",
	"args",
	"a",
	"bt",
	"stack",
	"display",
	"undisplay",
	"whatis",
	"source",
	"p",
	"pp",
	"run",
	"restart",
	"quit",
	"q",
	"debug",
}

local function completion_kind(source)
	if not cmp_kinds_cache then
		local ok_types, types = pcall(require, "cmp.types")
		if ok_types and types and types.lsp and types.lsp.CompletionItemKind then
			cmp_kinds_cache = types.lsp.CompletionItemKind
		else
			cmp_kinds_cache = {}
		end
	end
	local kinds = cmp_kinds_cache or {}
	local default = kinds.Text or 1
	if source == "pdb" then
		return kinds.Keyword or default
	end
	if source == "python" then
		return kinds.Variable or default
	end
	return default
end

local function strip_prompt(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local templates = { "^ipdb>[%s]*", "^%([Pp]db%)%s*" }
	for _, pattern in ipairs(templates) do
		local stripped = text:gsub(pattern, "", 1)
		if stripped ~= text then
			return stripped
		end
	end
	return text
end

function M.build_context(request_context)
	local before = request_context.cursor_before_line or ""
	local after = request_context.cursor_after_line or ""
	local stripped_before = strip_prompt(before)
	local token = stripped_before:match("([%w_%.]+)$") or ""
	local cursor = request_context.cursor or {}
	local row = tonumber(cursor.line) or 0
	local col = tonumber(cursor.col) or #before
	if col < 0 then
		col = #before
	end
	local start_col = col - #token
	if start_col < 0 then
		start_col = col
	end
	local prompt_offset = #before - #stripped_before
	if prompt_offset < 0 then
		prompt_offset = 0
	end
	local stripped_line = strip_prompt(before .. after)
	return {
		before = before,
		stripped_before = stripped_before,
		token = token,
		cursor_row = row,
		cursor_col = col,
		cursor_col_start = start_col,
		prompt_offset = prompt_offset,
		code = stripped_line,
		code_cursor = #stripped_before,
	}
end

local function build_item(label, source_kind, detail, context)
	local col = context.cursor_col or #context.before
	local row = context.cursor_row or 0
	local token = context.token or ""
	local start_col = context.cursor_col_start or (col - #token)
	return {
		label = label,
		insertText = label,
		filterText = label,
		kind = completion_kind(source_kind),
		detail = detail,
		dup = 0,
		textEdit = {
			range = {
				start = { line = row, character = start_col },
				["end"] = { line = row, character = col },
			},
			newText = label,
		},
	}
end

local function command_items(context)
	local stripped = context.stripped_before or ""
	local token = context.token
	if stripped:sub(1, 1) == "!" then
		return {}
	end
	if token:find("%.", 1, true) and not token:match("^!") then
		return {}
	end
	local target = token
	if target:sub(1, 1) == "!" then
		target = target:sub(2)
	end
	local items = {}
	for _, cmd in ipairs(ipdb_commands) do
		if target == "" or cmd:sub(1, #target) == target then
			items[#items + 1] = build_item(cmd, "pdb", "[cmd]", context)
		end
	end
	return items
end

local function variable_items(context)
	local token = context.token
	local names = env.debug_variable_names()
	if vim.tbl_isempty(names) then
		return {}
	end
	local items = {}
	for name, _ in pairs(names) do
		if token == "" or name:sub(1, #token) == token then
			items[#items + 1] = build_item(name, "python", "[var]", context)
		end
	end
	table.sort(items, function(a, b)
		return (a and a.label or "") < (b and b.label or "")
	end)
	return items
end

local function build_ipdb_items(context, payload)
	if type(payload) ~= "table" then
		return {}
	end
	local matches = payload.matches
	if type(matches) ~= "table" or #matches == 0 then
		return {}
	end
	local row = context.cursor_row or 0
	local prompt_offset = context.prompt_offset or 0
	local cursor_start = tonumber(payload.cursor_start) or context.code_cursor or 0
	local cursor_end = tonumber(payload.cursor_end) or context.code_cursor or cursor_start
	if cursor_start < 0 then
		cursor_start = 0
	end
	if cursor_end < cursor_start then
		cursor_end = cursor_start
	end
	local detail_by_text = {}
	local items_payload = payload.items
	if type(items_payload) == "table" then
		for _, item in ipairs(items_payload) do
			if type(item) == "table" then
				local text = item.text
				local source = item.source
				if type(text) == "string" and text ~= "" and type(source) == "string" and source ~= "" then
					detail_by_text[text] = source
				end
			end
		end
	end
	local start_col = cursor_start + prompt_offset
	local end_col = cursor_end + prompt_offset
	if start_col < 0 then
		start_col = 0
	end
	if end_col < start_col then
		end_col = start_col
	end
	local results = {}
	for _, match in ipairs(matches) do
		if type(match) == "string" and match ~= "" then
			local source = detail_by_text[match]
			local detail = "[ipdb]"
			if source and source ~= "" then
				detail = string.format("[%s]", source)
			end
			results[#results + 1] = {
				label = match,
				insertText = match,
				filterText = match,
				kind = completion_kind("python"),
				detail = detail,
				dup = 0,
				textEdit = {
					range = {
						start = { line = row, character = start_col },
						["end"] = { line = row, character = end_col },
					},
					newText = match,
				},
			}
		end
	end
	return results
end

local function new_accumulator(on_update, total, opts)
	opts = opts or {}
	local mode = opts.mode == "delta" and "delta" or "aggregate"
	local acc = {
		items = {},
		seen = {},
		pending = total,
		on_update = on_update,
		closed = total == 0,
		mode = mode,
		last_published = 0,
	}

	function acc:add_items(items)
		local appended = false
		if type(items) ~= "table" then
			return appended
		end
		for _, item in ipairs(items) do
			local label = item and item.label
			if type(label) == "string" and label ~= "" and not self.seen[label] then
				self.seen[label] = true
				self.items[#self.items + 1] = item
				appended = true
			end
		end
		return appended
	end

	function acc:publish()
		if self.closed then
			return
		end
		local slice
		if self.mode == "delta" then
			local start_index = self.last_published + 1
			slice = {}
			if start_index <= #self.items then
				for idx = start_index, #self.items do
					slice[#slice + 1] = self.items[idx]
				end
			end
			if #slice == 0 and self.pending > 0 then
				return
			end
			self.last_published = #self.items
		else
			if #self.items == 0 and self.pending > 0 then
				return
			end
			slice = self.items
		end
		local payload = (#slice > 0) and vim.deepcopy(slice) or {}
		self.on_update({
			items = payload,
			isIncomplete = self.pending > 0,
		})
		if self.pending == 0 then
			self.closed = true
		end
	end

	function acc:on_items(items)
		if self:add_items(items) then
			self:publish()
		end
	end

	function acc:on_done()
		if self.pending <= 0 then
			return
		end
		self.pending = self.pending - 1
		self:publish()
	end

	return acc
end

local function new_emitter(acc)
	local active = true
	local emitter = {}

	function emitter:append(items)
		if not active then
			return
		end
		acc:on_items(items)
	end

	function emitter:done()
		if not active then
			return
		end
		active = false
		acc:on_done()
	end

	return emitter
end

function M.register(provider)
	if type(provider) ~= "table" then
		return false
	end
	providers[#providers + 1] = provider
	return true
end

function M.dispatch(context, on_update, opts)
	local total = #providers
	if total == 0 then
		on_update({ items = {}, isIncomplete = false })
		return
	end
	local acc = new_accumulator(on_update, total, opts)
	for _, provider in ipairs(providers) do
		local emitter = new_emitter(acc)
		local ok, err = pcall(provider.fetch, provider, context, emitter)
		if not ok then
			vim.schedule(function()
				vim.notify(
					string.format("ipybridge: completion provider %s failed: %s", provider.name or "?", err),
					vim.log.levels.WARN
				)
			end)
			emitter:done()
		end
	end
end

-- Built-in providers ---------------------------------------------------------

M.register({
	name = "internal",
	fetch = function(_, context, emit)
		local aggregated = {}
		local commands = command_items(context)
		if commands and #commands > 0 then
			vim.list_extend(aggregated, commands)
		end
		local variables = variable_items(context)
		if variables and #variables > 0 then
			vim.list_extend(aggregated, variables)
		end
		if #aggregated > 0 then
			emit:append(aggregated)
		end
		emit:done()
	end,
})

M.register({
	name = "ipdb",
	fetch = function(_, context, emit)
		debug_completion.fetch({
			code = context.code or "",
			cursor_pos = context.code_cursor or 0,
		}, function(payload, err)
			if not err and payload then
				local items = build_ipdb_items(context, payload)
				if items and #items > 0 then
					emit:append(items)
				end
			end
			emit:done()
		end)
	end,
})

return M
