-- Preview renderers for ipybridge.nvim data viewer.
-- Each renderer transforms kernel payloads into buffer lines and drill-down maps.

local Renderers = {}

local function sanitize_inline(value)
	if value == nil then
		return ""
	end
	local text = tostring(value)
	return text:gsub("[\r\n]", " ")
end

local function payload_kind(payload)
	if type(payload) ~= "table" then
		return nil
	end
	local kind = payload.kind
	if kind == "object" then
		local seq = payload.sequence_kind
		if type(seq) == "string" and seq ~= "" then
			return seq
		end
	end
	return kind
end

local function truncate(text, limit)
	if #text > limit then
		return text:sub(1, limit - 3) .. "..."
	end
	return text
end

local function to_str(v)
	local t = type(v)
	if v == nil then
		return ""
	end
	if t == "string" then
		return v
	end
	if t == "number" or t == "boolean" then
		return tostring(v)
	end
	return tostring(v)
end

local function display_width(text)
	local s = text
	if type(s) ~= "string" then
		s = tostring(s or "")
	end
	if vim.fn and vim.fn.strdisplaywidth then
		local ok, width = pcall(vim.fn.strdisplaywidth, s)
		if ok and type(width) == "number" then
			return width
		end
	end
	return #s
end

local function separator_line(reference)
	local width = 80
	if reference and reference ~= "" then
		local w = display_width(reference)
		if w > width then
			width = w
		end
	end
	return string.rep("-", width)
end

local function format_tabular(header, rows)
	local all_rows = {}
	local str_rows = {}
	local widths = {}

	if header and #header > 0 then
		table.insert(all_rows, header)
	end

	for _, row in ipairs(rows or {}) do
		table.insert(all_rows, row)
	end

	for r_idx, row in ipairs(all_rows) do
		local str_row = {}
		for c_idx, cell in ipairs(row or {}) do
			local s = to_str(cell)
			local w = display_width(s)
			if not widths[c_idx] or w > widths[c_idx] then
				widths[c_idx] = w
			end
			str_row[c_idx] = s
		end
		str_rows[r_idx] = str_row
	end

	local formatted = {}
	for r_idx, row in ipairs(str_rows) do
		local padded = {}
		for c_idx, cell in ipairs(row) do
			local w = display_width(cell)
			local target = widths[c_idx] or w
			if w < target then
				padded[c_idx] = cell .. string.rep(" ", target - w)
			else
				padded[c_idx] = cell
			end
		end
		formatted[r_idx] = table.concat(padded, " | ")
	end

	if header and #header > 0 then
		local head = formatted[1]
		local data_rows = {}
		for i = 2, #formatted do
			data_rows[#data_rows + 1] = formatted[i]
		end
		return head, data_rows
	end

	return nil, formatted
end

local function build_labeled_table(col_labels, rows, row_offset, col_offset)
	local prepared = {}
	local cols = {}
	local col_count = 0

	if type(rows) == "table" then
		for _, r in ipairs(rows) do
			if type(r) == "table" and #r > col_count then
				col_count = #r
			end
		end
	end

	if type(col_labels) == "table" then
		for idx, label in ipairs(col_labels) do
			cols[idx] = to_str(label)
			if idx > col_count then
				col_count = idx
			end
		end
	end

	local header = { "[ ]" }
	for i = 1, col_count do
		local label = cols[i]
		if not label or label == "" then
			label = string.format("[%d]", (col_offset or 0) + i - 1)
		end
		header[#header + 1] = label
	end

	for idx, raw in ipairs(rows or {}) do
		local display = { string.format("[%d]", (row_offset or 0) + idx - 1) }
		if type(raw) == "table" then
			for i = 1, col_count do
				display[#display + 1] = raw[i]
			end
		end
		table.insert(prepared, display)
	end

	return format_tabular(header, prepared)
end

local function append_tabular(lines, header, rows)
	local has_rows = type(rows) == "table" and #rows > 0
	if not header and not has_rows then
		return
	end
	local ref = header
	if (not ref or ref == "") and has_rows then
		ref = rows[1]
	end
	local sep = separator_line(ref)
	table.insert(lines, sep)
	if header and header ~= "" then
		table.insert(lines, header)
		table.insert(lines, sep)
	end
	if has_rows then
		for _, row in ipairs(rows) do
			table.insert(lines, row)
		end
	end
end

local function render_dataframe(data)
	local lines = {}
	local shape = data.total_shape or data.shape or {}
	table.insert(
		lines,
		string.format(
			"DataFrame %s  shape=%sx%s",
			data.name or "",
			tostring(shape[1] or "?"),
			tostring(shape[2] or "?")
		)
	)
	local row_offset = tonumber(data.row_offset) or 0
	local col_offset = tonumber(data.col_offset) or 0
	local window_rows = #(data.rows or {})
	local window_cols = #(data.columns or {})
	local row_end = row_offset + window_rows - 1
	if row_end < row_offset then
		row_end = row_offset
	end
	local col_end = col_offset + window_cols - 1
	if col_end < col_offset then
		col_end = col_offset
	end
	table.insert(lines, string.format("window rows %d-%d cols %d-%d", row_offset, row_end, col_offset, col_end))
	local header, rows = build_labeled_table(data.columns or {}, data.rows or {}, row_offset, col_offset)
	append_tabular(lines, header, rows)
	return lines, {}
end

local function render_ndarray(data)
	local lines = {}
	table.insert(
		lines,
		string.format(
			"ndarray %s  dtype=%s  shape=%s",
			data.name or "",
			tostring(data.dtype or ""),
			table.concat(vim.tbl_map(tostring, data.shape or {}), "x")
		)
	)
	local row_offset = tonumber(data.row_offset) or 0
	local col_offset = tonumber(data.col_offset) or 0

	if type(data.rows) == "table" then
		local window_rows = #data.rows
		local window_cols = #(data.rows[1] or {})
		local row_end = row_offset + window_rows - 1
		if row_end < row_offset then
			row_end = row_offset
		end
		local col_end = col_offset + window_cols - 1
		if col_end < col_offset then
			col_end = col_offset
		end
		table.insert(lines, string.format("window rows %d-%d cols %d-%d", row_offset, row_end, col_offset, col_end))
		local header, rows = build_labeled_table(nil, data.rows, row_offset, col_offset)
		append_tabular(lines, header, rows)
	elseif type(data.values1d) == "table" then
		local window_rows = #data.values1d
		local row_end = row_offset + window_rows - 1
		if row_end < row_offset then
			row_end = row_offset
		end
		table.insert(lines, string.format("window rows %d-%d", row_offset, row_end))
		local header, rows = build_labeled_table(
			{ "value" },
			vim.tbl_map(function(v)
				return { v }
			end, data.values1d),
			row_offset,
			0
		)
		append_tabular(lines, header, rows)
	else
		table.insert(lines, tostring(data.repr or ""))
	end

	return lines, {}
end

local function render_sequence(data, viewer_name)
	local lines = {}
	local map = {}
	local effective_kind = payload_kind(data) or "list"
	local kind = sanitize_inline(effective_kind)
	local length = tonumber(data.length)
	if not length and type(data.total_shape) == "table" then
		local first = data.total_shape[1]
		if type(first) == "number" then
			length = first
		elseif type(first) == "string" then
			length = tonumber(first)
		end
	end
	local row_offset = tonumber(data.row_offset) or 0
	local items = {}
	if type(data.items) == "table" then
		items = data.items
	end
	local allow_index = data.index_paths ~= false
	local visible = 0
	for _, item in ipairs(items) do
		if not item.placeholder then
			visible = visible + 1
		end
	end
	local window_end = row_offset + math.max(visible - 1, 0)
	local details = { kind, sanitize_inline(data.name or "") }
	if length then
		table.insert(details, string.format("len=%d", length))
	end
	if length and length > 0 then
		table.insert(details, string.format("window=%d-%d", row_offset, window_end))
	elseif length == 0 then
		table.insert(details, "empty")
	end
	local heading = table.concat(details, " ")
	table.insert(lines, heading)
	table.insert(lines, separator_line(heading))
	if #items == 0 then
		table.insert(lines, "(no items)")
		return lines, map
	end
	for _, item in ipairs(items) do
		if item.placeholder then
			local more = tonumber(item.more) or 0
			if more > 0 then
				table.insert(lines, string.format("... (+%d more items)", more))
			else
				table.insert(lines, "...")
			end
		else
			local idx = item.index
			local idx_str
			if type(idx) == "number" then
				idx_str = string.format("%d", idx)
			else
				idx_str = tostring(idx or "?")
			end
			local ty = sanitize_inline(item.type or "")
			local item_kind = sanitize_inline(item.kind or "")
			local repr = truncate(sanitize_inline(item.repr or ""), 120)
			local parts = { string.format("[%s] <%s>", idx_str, ty) }
			if item_kind ~= "" then
				table.insert(parts, "kind=" .. item_kind)
			end
			if repr ~= "" then
				table.insert(parts, "-> " .. repr)
			end
			local line = table.concat(parts, " ")
			table.insert(lines, line)
			if allow_index and item.previewable and item.path_index ~= nil and viewer_name and viewer_name ~= "" then
				map[#lines] = string.format("%s[%s]", viewer_name, idx_str)
			end
		end
	end
	return lines, map
end

local function render_mapping(data, viewer_name)
	local lines = {}
	local map = {}
	local length = tonumber(data.length)
	if not length and type(data.total_shape) == "table" then
		local first = data.total_shape[1]
		if type(first) == "number" then
			length = first
		elseif type(first) == "string" then
			length = tonumber(first)
		end
	end
	local row_offset = tonumber(data.row_offset) or 0
	local items = {}
	if type(data.items) == "table" then
		items = data.items
	end
	local allow_paths = data.allow_paths ~= false
	local visible = 0
	for _, item in ipairs(items) do
		if not item.placeholder then
			visible = visible + 1
		end
	end
	local window_end = row_offset + math.max(visible - 1, 0)
	local details = { "dict", sanitize_inline(data.name or "") }
	if length then
		table.insert(details, string.format("len=%d", length))
	end
	if length and length > 0 then
		table.insert(details, string.format("window=%d-%d", row_offset, window_end))
	elseif length == 0 then
		table.insert(details, "empty")
	end
	local heading = table.concat(details, " ")
	table.insert(lines, heading)
	table.insert(lines, separator_line(heading))
	if #items == 0 then
		table.insert(lines, "(no items)")
		return lines, map
	end
	local header = { "Key", "Type", "Kind", "Preview" }
	local rows = {}
	local row_paths = {}
	local placeholders = {}
	for _, item in ipairs(items) do
		if item.placeholder then
			local more = tonumber(item.more) or 0
			if more > 0 then
				table.insert(placeholders, string.format("... (+%d more items)", more))
			else
				table.insert(placeholders, "...")
			end
		else
			local key_display = truncate(sanitize_inline(item.key or ""), 60)
			local ty = sanitize_inline(item.type or "")
			local item_kind = sanitize_inline(item.kind or "")
			local repr = truncate(sanitize_inline(item.repr or ""), 120)
			rows[#rows + 1] = { key_display, ty, item_kind, repr }
			if
				allow_paths
				and type(item.path_accessor) == "string"
				and item.path_accessor ~= ""
				and item.previewable
				and viewer_name
				and viewer_name ~= ""
			then
				row_paths[#rows] = viewer_name .. item.path_accessor
			end
		end
	end
	local head, row_lines = format_tabular(header, rows)
	local reference = head
	if (not reference or reference == "") and row_lines[1] then
		reference = row_lines[1]
	end
	if reference and reference ~= "" then
		table.insert(lines, separator_line(reference))
	end
	if head and head ~= "" then
		table.insert(lines, head)
		table.insert(lines, separator_line(head))
	end
	for idx, row_line in ipairs(row_lines) do
		table.insert(lines, row_line)
		local path = row_paths[idx]
		if path then
			map[#lines] = path
		end
	end
	for _, placeholder in ipairs(placeholders) do
		table.insert(lines, placeholder)
	end
	return lines, map
end

local function render_generic(data)
	local lines = {}
	table.insert(lines, string.format("Object %s", data.name or ""))
	table.insert(lines, string.rep("-", 80))
	table.insert(lines, tostring(data.repr or ""))
	return lines, {}
end

local function render_dataclass(data, viewer_name)
	local lines = {}
	local map = {}
	local cname = tostring(data.class_name or "")
	table.insert(lines, string.format("dataclass %s", cname))
	table.insert(lines, string.rep("-", 80))
	local fields = type(data.fields) == "table" and data.fields or {}
	if #fields == 0 then
		table.insert(lines, "(no fields)")
		return lines, map
	end
	for _, it in ipairs(fields) do
		local fname = tostring(it.name or "")
		local ty = tostring(it.type or "")
		local kind = tostring(it.kind or "")
		local path = (viewer_name or data.name or "") .. "." .. fname
		if kind == "ndarray" then
			local shp = it.shape or {}
			local dtype = tostring(it.dtype or "")
			table.insert(
				lines,
				string.format(
					"%s <%s> ndarray shape=%s dtype=%s",
					fname,
					ty,
					table.concat(vim.tbl_map(tostring, shp), "x"),
					dtype
				)
			)
			map[#lines] = path
		elseif kind == "dataframe" then
			local shp = it.shape or {}
			local shape_str = (#shp >= 2) and (tostring(shp[1]) .. "x" .. tostring(shp[2]))
				or table.concat(vim.tbl_map(tostring, shp), "x")
			table.insert(lines, string.format("%s <%s> DataFrame shape=%s", fname, ty, shape_str))
			map[#lines] = path
		else
			table.insert(lines, string.format("%s <%s> = %s", fname, ty, to_str(it.repr)))
			local r = tostring(it.repr or "")
			if #r >= 3 and r:sub(-3) == "..." then
				map[#lines] = path
			end
		end
	end
	return lines, map
end

local function render_ctypes(data, viewer_name)
	local lines = {}
	local map = {}
	local sname = tostring(data.struct_name or "")
	table.insert(lines, string.format("ctypes.Structure %s", sname))
	table.insert(lines, string.rep("-", 80))
	local fields = type(data.fields) == "table" and data.fields or {}
	if #fields == 0 then
		table.insert(lines, "(no fields)")
		return lines, map
	end
	for _, it in ipairs(fields) do
		local fname = tostring(it.name or "")
		local ctype = tostring(it.ctype or "")
		local kind = tostring(it.kind or "")
		local path = (viewer_name or data.name or "") .. "." .. fname
		if kind == "array" then
			local vals = {}
			for _, v in ipairs(it.values or {}) do
				table.insert(vals, to_str(v))
			end
			local suffix = ""
			if type(it.length) == "number" then
				suffix = string.format(" len=%d", it.length)
			end
			table.insert(lines, string.format("%s [%s]%s: [ %s ]", fname, ctype, suffix, table.concat(vals, ", ")))
			map[#lines] = path
		elseif kind == "struct" then
			local v = it.value
			local ok, encoded = pcall(vim.fn.json_encode, v)
			table.insert(lines, string.format("%s [%s]: %s", fname, ctype, ok and encoded or to_str(v)))
			map[#lines] = path
		else
			table.insert(lines, string.format("%s [%s]: %s", fname, ctype, to_str(it.value)))
		end
	end
	return lines, map
end

local function render_ctypes_array(data)
	local lines = {}
	table.insert(
		lines,
		string.format("ctypes.Array %s len=%s", tostring(data.ctype or ""), tostring(data.length or ""))
	)
	table.insert(lines, string.rep("-", 80))
	local vals = {}
	for _, v in ipairs(data.values or {}) do
		table.insert(vals, to_str(v))
	end
	table.insert(lines, "[ " .. table.concat(vals, ", ") .. " ]")
	return lines, {}
end

function Renderers.render(payload, context)
	local name = context and context.viewer_name or payload.name
	local kind = payload_kind(payload)
	local root_kind = payload.kind
	if root_kind == "dataframe" then
		return render_dataframe(payload)
	elseif root_kind == "ndarray" then
		return render_ndarray(payload)
	elseif kind == "list" or kind == "tuple" or kind == "set" then
		return render_sequence(payload, name)
	elseif kind == "dict" then
		return render_mapping(payload, name)
	elseif root_kind == "dataclass" then
		return render_dataclass(payload, name)
	elseif root_kind == "ctypes" then
		return render_ctypes(payload, name)
	elseif root_kind == "ctypes_array" then
		return render_ctypes_array(payload)
	end
	return render_generic(payload)
end

return Renderers
