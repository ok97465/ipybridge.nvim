-- Debug cursor tooltip helper for ipybridge.nvim.
-- Shows a lightweight floating preview when the cursor rests on simple names.

local api = vim.api

local CursorTooltipState = {}
CursorTooltipState.__index = CursorTooltipState

---Create a new cursor tooltip state.
function CursorTooltipState:new()
	return setmetatable({
		buf = nil,
		win = nil,
		augroup = nil,
		enabled = true,
		border = "single",
		max_width = 120,
		last = {
			bufnr = nil,
			lnum = nil,
			name = nil,
		},
	}, self)
end

---Normalize inline values for single-line display.
local function sanitize_inline(value)
	if value == nil then
		return ""
	end
	local text = tostring(value)
	return text:gsub("[\r\n]", " ")
end

---Check whether a character is a valid identifier char.
local function is_ident_char(ch)
	return ch ~= "" and ch:match("[%w_]") ~= nil
end

---Find the closest non-space character before the index.
local function previous_nonspace(line, idx)
	for i = idx, 1, -1 do
		local ch = line:sub(i, i)
		if ch ~= "" and not ch:match("%s") then
			return ch
		end
	end
	return nil
end

---Extract a simple identifier at the cursor column.
local function extract_identifier(line, col)
	if type(line) ~= "string" or line == "" then
		return nil
	end
	local len = #line
	local idx = math.min(math.max(col + 1, 1), len)
	local ch = line:sub(idx, idx)
	if not is_ident_char(ch) then
		if idx > 1 and is_ident_char(line:sub(idx - 1, idx - 1)) then
			idx = idx - 1
		else
			return nil
		end
	end
	local start_idx = idx
	while start_idx > 1 and is_ident_char(line:sub(start_idx - 1, start_idx - 1)) do
		start_idx = start_idx - 1
	end
	local end_idx = idx
	while end_idx < len and is_ident_char(line:sub(end_idx + 1, end_idx + 1)) do
		end_idx = end_idx + 1
	end
	local name = line:sub(start_idx, end_idx)
	if not name:match("^[%a_][%w_]*$") then
		return nil
	end
	local prev = previous_nonspace(line, start_idx - 1)
	if prev == "." then
		return nil
	end
	return name
end

---Format a single-line tooltip entry for a variable.
local function format_entry(name, entry)
	if type(entry) ~= "table" then
		return {}
	end
	local repr = sanitize_inline(entry.repr or "")
	local line = name
	if repr ~= "" then
		line = string.format("%s = %s", name, repr)
	elseif entry.type then
		line = string.format("%s (%s)", name, sanitize_inline(entry.type))
	end
	return { line }
end

---Measure display width with a safe fallback.
local function line_width(text)
	local ok, width = pcall(vim.fn.strdisplaywidth, text)
	if ok and type(width) == "number" then
		return width
	end
	return #text
end

---Truncate a line to the configured width.
local function truncate_line(text, limit)
	if limit <= 0 then
		return text
	end
	if #text <= limit then
		return text
	end
	if limit <= 3 then
		return text:sub(1, limit)
	end
	return text:sub(1, limit - 3) .. "..."
end

---Apply line truncation to all output lines.
local function normalize_lines(lines, max_width)
	if max_width == nil or max_width <= 0 then
		return lines
	end
	local out = {}
	for _, line in ipairs(lines) do
		out[#out + 1] = truncate_line(line, max_width)
	end
	return out
end

---Compute floating window size from prepared lines.
local function compute_size(lines, max_width)
	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, line_width(line))
	end
	if max_width and max_width > 0 then
		width = math.min(width, max_width)
	end
	return width, math.max(#lines, 1)
end

---Close and reset the tooltip window.
function CursorTooltipState:clear()
	if self.win and api.nvim_win_is_valid(self.win) then
		pcall(api.nvim_win_close, self.win, true)
	end
	if self.buf and api.nvim_buf_is_loaded(self.buf) then
		pcall(api.nvim_buf_delete, self.buf, { force = true })
	end
	self.buf = nil
	self.win = nil
	self.last = { bufnr = nil, lnum = nil, name = nil }
end

---Check whether the buffer is a Python file.
local function is_python_buffer(bufnr)
	local ok, bo = pcall(function()
		return vim.bo[bufnr]
	end)
	if ok and bo and bo.filetype ~= nil then
		return bo.filetype == "python"
	end
	return false
end

---Open or refresh the tooltip window with new lines.
function CursorTooltipState:open(lines)
	if not lines or #lines == 0 then
		self:clear()
		return
	end
	local max_width = self.max_width
	if vim.o.columns and vim.o.columns > 0 then
		max_width = math.min(max_width, math.max(vim.o.columns - 4, 20))
	end
	local normalized = normalize_lines(lines, max_width)
	local width, height = compute_size(normalized, max_width)
	local opts = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		border = self.border,
		style = "minimal",
	}
	if self.win and api.nvim_win_is_valid(self.win) then
		pcall(api.nvim_win_set_config, self.win, opts)
	else
		self.buf = api.nvim_create_buf(false, true)
		self.win = api.nvim_open_win(self.buf, false, opts)
		api.nvim_set_option_value("buftype", "nofile", { buf = self.buf })
		api.nvim_set_option_value("bufhidden", "wipe", { buf = self.buf })
		api.nvim_set_option_value("swapfile", false, { buf = self.buf })
	end
	api.nvim_buf_set_option(self.buf, "modifiable", true)
	api.nvim_buf_set_lines(self.buf, 0, -1, false, normalized)
	api.nvim_buf_set_option(self.buf, "modifiable", false)
end

---Compute tooltip contents for the cursor and display them.
function CursorTooltipState:show()
	if not self.enabled then
		self:clear()
		return
	end
	local bridge = package.loaded["ipybridge"]
	if type(bridge) ~= "table" or bridge._debug_active ~= true then
		self:clear()
		return
	end
	local bufnr = api.nvim_get_current_buf()
	if not is_python_buffer(bufnr) then
		self:clear()
		return
	end
	local cursor = api.nvim_win_get_cursor(0)
	local lnum = cursor[1]
	local col = cursor[2]
	local lines = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
	local line = lines[1] or ""
	local name = extract_identifier(line, col)
	if not name then
		self:clear()
		return
	end
	local vars = bridge._latest_vars
	local entry = type(vars) == "table" and vars[name] or nil
	if type(entry) ~= "table" then
		self:clear()
		return
	end
	if self.last.bufnr == bufnr and self.last.lnum == lnum and self.last.name == name then
		if self.win and api.nvim_win_is_valid(self.win) then
			return
		end
	end
	local preview_lines = format_entry(name, entry)
	if #preview_lines == 0 then
		self:clear()
		return
	end
	self:open(preview_lines)
	self.last = { bufnr = bufnr, lnum = lnum, name = name }
end

---Register autocmds that drive the tooltip lifecycle.
function CursorTooltipState:setup(config)
	if type(config) == "table" then
		if config.enabled ~= nil then
			self.enabled = config.enabled ~= false
		end
		if config.border ~= nil then
			self.border = config.border == false and nil or config.border
		end
		local max_width = tonumber(config.max_width)
		if max_width and max_width > 0 then
			self.max_width = max_width
		end
	else
		self.enabled = config ~= false
	end
	if self.augroup then
		return
	end
	self.augroup = api.nvim_create_augroup("IpybridgeDebugCursorTooltip", { clear = true })
	api.nvim_create_autocmd({ "CursorMoved" }, {
		group = self.augroup,
		callback = function()
			self:show()
		end,
	})
	api.nvim_create_autocmd({ "InsertEnter", "BufLeave", "WinLeave" }, {
		group = self.augroup,
		callback = function()
			self:clear()
		end,
	})
end

---Clear tooltip state when debug sessions end.
function CursorTooltipState:on_debug_status(info)
	if type(info) ~= "table" then
		return
	end
	if info.active == false then
		self:clear()
	end
end

local state = CursorTooltipState:new()

local M = {}

---Configure debug cursor tooltip autocmds.
function M.setup(config)
	state:setup(config)
end

---Handle debug status changes to clear stale tooltip windows.
function M.on_debug_status(info)
	state:on_debug_status(info)
end

---Clear any active tooltip window.
function M.clear()
	state:clear()
end

-- Internal helpers exposed for tests.
M._extract_identifier = extract_identifier
M._format_entry = format_entry

return M
