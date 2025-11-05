local debug_completion = require("ipybridge.debug.completion")

local M = {}

local SOURCE_NAME = "ipybridge_debug_hint"

---@class BridgeState
---@field patched boolean
---@field registered boolean
---@field last_context table|nil
local state = {
	patched = false,
	registered = false,
	last_context = nil,
}

local function cmp_module()
	local cmp = package.loaded["cmp"]
	if type(cmp) == "table" then
		return cmp
	end
	return nil
end

local function with_cmp(fn)
	if type(fn) ~= "function" then
		return nil
	end
	local cmp = cmp_module()
	if not cmp then
		return nil
	end
	local ok, result = pcall(fn, cmp)
	if not ok then
		return nil
	end
	return result
end

local function cmp_is_visible()
	local visible = with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" then
			return false
		end
		return cmp.visible()
	end)
	return visible and true or false
end

local function cmp_close_if_visible()
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or type(cmp.close) ~= "function" then
			return
		end
		if cmp.visible() then
			pcall(cmp.close)
		end
	end)
end

local function cmp_abort_if_visible()
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or type(cmp.abort) ~= "function" then
			return
		end
		if cmp.visible() then
			pcall(cmp.abort)
		end
	end)
end

local function cmp_select(direction)
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or not cmp.visible() then
			return
		end
		local behavior = cmp.SelectBehavior and cmp.SelectBehavior.Select
		local opts = behavior and { behavior = behavior } or nil
		local selector
		if direction == "next" then
			selector = cmp.select_next_item
		elseif direction == "prev" then
			selector = cmp.select_prev_item
		end
		if type(selector) ~= "function" then
			return
		end
		if opts then
			pcall(selector, opts)
		else
			pcall(selector)
		end
	end)
end

local key_listener_attached = false
local mapped_buffers = {}
local autocmd_buffers = {}

-- Lookup helpers -------------------------------------------------------------

local function current_bridge()
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" then
		return nil
	end
	return rawget(bridge, "term_instance")
end

local function is_ipybridge_terminal(bufnr)
	local term = current_bridge()
	return term and term.buf_id == bufnr or false
end

local function is_debug_session()
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" then
		return false
	end
	return bridge._debug_active == true
end

local function is_active_ipy_terminal()
	local ok_mode, info = pcall(vim.api.nvim_get_mode)
	local mode = ok_mode and tostring(info.mode or ""):sub(1, 1) or ""
	if mode ~= "t" then
		return false
	end
	local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
	if not ok_buf then
		return false
	end
	return is_ipybridge_terminal(buf)
end

-- nvim-cmp integration -------------------------------------------------------

local function patch_cmp_api()
	if state.patched then
		return true
	end
	local cmp = cmp_module()
	if not cmp then
		return false
	end
	local cmp_utils = (type(cmp) == "table" and cmp.utils) or nil
	local cmp_api = cmp_utils and cmp_utils.api or package.loaded["cmp.utils.api"]
	if type(cmp_api) ~= "table" then
		local ok, loaded = pcall(require, "cmp.utils.api")
		if not ok or type(loaded) ~= "table" then
			return false
		end
		cmp_api = loaded
	end
	if type(cmp_api) ~= "table" then
		return false
	end
	local original_get_mode = cmp_api.get_mode or function()
		return nil
	end
	local original_is_insert_mode = cmp_api.is_insert_mode or function()
		return false
	end
	local original_is_suitable_mode = cmp_api.is_suitable_mode or function()
		return false
	end
	cmp_api.get_mode = function()
		if is_active_ipy_terminal() then
			return "i"
		end
		return original_get_mode()
	end
	cmp_api.is_insert_mode = function()
		if is_active_ipy_terminal() then
			return true
		end
		return original_is_insert_mode()
	end
	cmp_api.is_suitable_mode = function()
		if is_active_ipy_terminal() then
			return true
		end
		return original_is_suitable_mode()
	end
	state.patched = true
	return true
end

local function feed_terminal(keys)
	local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(termcodes, "tn", false)
end

local function close_menu()
	vim.schedule(function()
		cmp_close_if_visible()
		state.last_context = nil
	end)
end

local function ensure_key_listener()
	if key_listener_attached then
		return
	end
	local ns = vim.api.nvim_create_namespace("ipybridge_cmp_keys")
	vim.on_key(function(char)
		if not char or char == "" then
			return
		end
		-- Ignore navigation keys we explicitly handle in mappings.
		if char == "\x0e" or char == "\x10" or char == "\r" or char == "\27" then
			return
		end
		if char:match("%c") then
			return
		end
		if not is_active_ipy_terminal() then
			return
		end
		vim.schedule(function()
			if not is_active_ipy_terminal() then
				return
			end
			if cmp_is_visible() then
				cmp_abort_if_visible()
				state.last_context = nil
			end
		end)
	end, ns)
	key_listener_attached = true
end

-- Completion candidates ------------------------------------------------------

local cmp_kinds_cache = nil

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

local function collect_debug_names()
	local names = {}
	local ok_bridge, bridge = pcall(require, "ipybridge")
	if not ok_bridge or type(bridge) ~= "table" then
		return names
	end
	local function collect(scope)
		if type(scope) ~= "table" then
			return
		end
		for key, _ in pairs(scope) do
			if type(key) == "string" and key ~= "" and not key:match("^__") then
				names[key] = true
			end
		end
	end
	collect(bridge._latest_vars)
	local locals_snapshot = bridge._debug_locals_snapshot
	if type(locals_snapshot) == "table" then
		collect(locals_snapshot.__locals__)
	end
	local globals_snapshot = bridge._debug_globals_snapshot
	if type(globals_snapshot) == "table" then
		collect(globals_snapshot.__globals__)
	end
	return names
end

local function build_context(request_context)
	-- Capture the relevant pieces of the terminal line around the cursor so
	-- every provider can construct edits without duplicating parsing logic.
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
	local names = collect_debug_names()
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
	-- Translate the kernel payload into nvim-cmp items while preserving the
	-- replacement span calculated by ipdb.
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

---@class CompletionProvider
---@field name string
---@field fetch fun(self, context: table, emit: CompletionEmitter)

---@class CompletionEmitter
---@field append fun(self, items: table)
---@field done fun(self)

-- Provider registry keeps the pipeline extensible so additional completion
-- backends can append results without rewriting the core logic.
local providers = {}

---Register a completion provider in declaration order.
---@param provider CompletionProvider
---@return boolean
local function register_provider(provider)
	if type(provider) ~= "table" then
		return false
	end
	providers[#providers + 1] = provider
	return true
end

local function new_accumulator(on_update, total)
	local acc = {
		items = {},
		seen = {},
		pending = total,
		on_update = on_update,
		closed = total == 0,
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
		local has_items = #self.items > 0
		if not has_items and self.pending > 0 then
			return
		end
		local items = has_items and vim.deepcopy(self.items) or {}
		self.on_update({
			items = items,
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

local function dispatch_providers(context, on_update)
	local total = #providers
	if total == 0 then
		on_update({ items = {}, isIncomplete = false })
		return
	end
	local acc = new_accumulator(on_update, total)
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

register_provider({
	name = "internal",
	fetch = function(_, context, emit)
		-- Surface built-in debugger commands and cached variables immediately.
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

register_provider({
	name = "ipdb",
	fetch = function(_, context, emit)
		-- Ask the Python helper for ipdb-native suggestions and merge them back.
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

local function apply_completion()
	local cmp = cmp_module()
	if not cmp or not cmp.visible() then
		return false
	end
	local ctx = state.last_context or {}
	local entry = cmp.get_selected_entry()
	if not entry then
		local entries = cmp.get_entries()
		entry = entries and entries[1] or nil
	end
	if not entry then
		state.last_context = nil
		vim.schedule(function()
			cmp_close_if_visible()
		end)
		return false
	end
	local item = entry.completion_item or {}
	local text_edit = item.textEdit
	local span = 0
	if text_edit and text_edit.range then
		local range = text_edit.range
		local start_info = range.start or {}
		local end_info = range["end"] or {}
		local start_char = tonumber(start_info.character) or (ctx.cursor_col or 0)
		local end_char = tonumber(end_info.character) or (ctx.cursor_col or start_char)
		if end_char < start_char then
			end_char = start_char
		end
		span = end_char - start_char
	else
		local token = ctx.token or ""
		if #token > 0 then
			span = #token
		end
	end
	local text = (text_edit and text_edit.newText) or item.insertText or item.label or ""
	state.last_context = nil
	vim.schedule(function()
		cmp_close_if_visible()
		if span > 0 then
			feed_terminal(string.rep("<BS>", span))
		end
		if text ~= "" then
			feed_terminal(text)
		end
	end)
	return true
end

-- cmp source ----------------------------------------------------------------

local HintSource = {}
HintSource.__index = HintSource

function HintSource.new()
	return setmetatable({}, HintSource)
end

function HintSource:get_debug_name()
	return "ipybridge::debug_tab_hint"
end

function HintSource:is_available()
	local ok_buf, buf = pcall(vim.api.nvim_get_current_buf)
	if not ok_buf then
		return false
	end
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "terminal" then
		return false
	end
	if not is_ipybridge_terminal(buf) then
		return false
	end
	return is_debug_session()
end

function HintSource:complete(request, callback)
	if not is_debug_session() then
		callback({ items = {}, isIncomplete = false })
		close_menu()
		return
	end
	local context = build_context(request.context or {})
	state.last_context = context
	dispatch_providers(context, function(result)
		vim.schedule(function()
			callback(result)
			if not result.isIncomplete and (#result.items == 0) then
				close_menu()
			end
		end)
	end)
end

local function ensure_source(cmp)
	if state.registered then
		return true
	end
	cmp.register_source(SOURCE_NAME, HintSource.new())
	state.registered = true
	return true
end

-- Buffer integration ---------------------------------------------------------

local function setup_terminal_keymaps()
	local buf = vim.api.nvim_get_current_buf()
	if mapped_buffers[buf] then
		return
	end
	vim.keymap.set("t", "<C-n>", function()
		if cmp_is_visible() then
			vim.schedule(function()
				cmp_select("next")
			end)
			return ""
		end
		return vim.api.nvim_replace_termcodes("<C-n>", true, false, true)
	end, { buffer = buf, noremap = true, silent = true, expr = true })
	vim.keymap.set("t", "<C-p>", function()
		if cmp_is_visible() then
			vim.schedule(function()
				cmp_select("prev")
			end)
			return ""
		end
		return vim.api.nvim_replace_termcodes("<C-p>", true, false, true)
	end, { buffer = buf, noremap = true, silent = true, expr = true })
	vim.keymap.set("t", "<CR>", function()
		if cmp_is_visible() then
			apply_completion()
			return ""
		end
		return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	end, { buffer = buf, noremap = true, silent = true, expr = true })
	vim.keymap.set("t", "<Esc>", function()
		if cmp_is_visible() then
			vim.schedule(function()
				cmp_abort_if_visible()
				state.last_context = nil
			end)
			return ""
		end
		return vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	end, { buffer = buf, noremap = true, silent = true, expr = true })
	mapped_buffers[buf] = true
end

local function setup_buffer_autocmds()
	local buf = vim.api.nvim_get_current_buf()
	if autocmd_buffers[buf] then
		return
	end
	local group = vim.api.nvim_create_augroup("ipybridge_cmp_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "BufLeave", "TermClose", "TermLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			cmp_abort_if_visible()
			state.last_context = nil
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			mapped_buffers[buf] = nil
			autocmd_buffers[buf] = nil
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})
	autocmd_buffers[buf] = group
end

-- Public API -----------------------------------------------------------------

---Register an additional completion provider.
---@param provider CompletionProvider
function M.register_completion_provider(provider)
	return register_provider(provider)
end

function M.ensure()
	local cmp = cmp_module()
	if not cmp then
		return false
	end
	if not patch_cmp_api() then
		return false
	end
	ensure_source(cmp)
	setup_terminal_keymaps()
	setup_buffer_autocmds()
	ensure_key_listener()
	return true
end

function M.trigger()
	if not cmp_module() then
		return false
	end
	if not M.ensure() then
		return false
	end
	vim.schedule(function()
		with_cmp(function(active)
			local sources = { { name = SOURCE_NAME } }
			local sources_builder = active.config and active.config.sources
			if type(sources_builder) == "function" then
				local ok_sources, resolved = pcall(sources_builder, sources)
				if ok_sources and resolved ~= nil then
					sources = resolved
				end
			end
			local reason = active.ContextReason and active.ContextReason.Manual or nil
			active.complete({
				config = {
					sources = sources,
				},
				reason = reason,
			})
		end)
	end)
	return true
end

return M
