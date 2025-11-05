-- Terminal helpers responsible for sending data into the IPython REPL and
-- ensuring the split exists before executing actions.

local Terminal = {}

local function copy_table(tbl)
	local result = {}
	for k, v in pairs(tbl) do
		result[k] = v
	end
	return result
end

local function normalize_newlines(text, is_windows)
	if type(text) ~= "string" then
		return text
	end
	if not is_windows then
		return text
	end
	return text:gsub("\r\n", "\n")
end

local function has_escape_byte(text)
	if type(text) ~= "string" then
		return false
	end
	return text:find("\27", 1, true) ~= nil
end

local function should_use_windows_multiline(text, opts, is_windows)
	if not is_windows then
		return false
	end
	if type(text) ~= "string" or text == "" then
		return false
	end
	opts = type(opts) == "table" and opts or {}
	if opts.raw or opts.mode == "ipdb" then
		return false
	end
	if opts.force_multiline then
		return true
	end
	if has_escape_byte(text) then
		return false
	end
	local _, newline_count = text:gsub("\n", "")
	if newline_count == 0 then
		return false
	end
	if newline_count > 1 then
		return true
	end
	return text:sub(-1) ~= "\n"
end

local function apply_windows_multiline(text)
	if type(text) ~= "string" or text == "" then
		return text
	end
	local has_final_lf = text:sub(-1) == "\n"
	local body = has_final_lf and text:sub(1, -2) or text
	if body ~= "" then
		body = body:gsub("\n", "\r")
	end
	if has_final_lf then
		return body .. "\n"
	end
	return body
end

function Terminal.new(ctx)
	local state = assert(ctx.state, "terminal: state table is required")
	local warn_user = ctx.warn_user or function() end
	local newline = ctx.newline or "\n"
	local is_windows = ctx.is_windows and true or false
	local is_open = ctx.is_open or function()
		return state.term_instance ~= nil and type(state.term_instance.job_id) == "number" and state.term_instance.job_id > 0
	end
	local open_fn = ctx.open

	local function with_terminal(go_back, cb)
		if type(cb) ~= "function" then
			return
		end
		if is_open() then
			cb(true)
			return
		end
		if type(open_fn) ~= "function" then
			warn_user("ipybridge: terminal open handler unavailable")
			return
		end
		open_fn(go_back, function(ok)
			if ok then
				cb(true)
			end
		end)
	end

	local function term_send(payload, opts)
		if not state.term_instance then
			return
		end
		if type(payload) ~= "string" then
			return
		end
		local options = {}
		if type(opts) == "table" then
			options = copy_table(opts)
		end
		if is_windows and not options.mode and not options.raw and state._debug_active then
			options.mode = "ipdb"
		end
		if payload == "" and not options.append_newline then
			return
		end
		local text = payload
		if options.append_newline then
			text = text .. newline
		end
		text = normalize_newlines(text, is_windows)
		if is_windows then
			if options.mode == "ipdb" then
				local sanitized = text:gsub("[\r\n]+$", "")
				if sanitized == "" then
					return
				end
				state.term_instance:send(sanitized .. "\r")
				return
			end
			if should_use_windows_multiline(text, options, is_windows) then
				text = apply_windows_multiline(text)
			end
		end
		state.term_instance:send(text)
	end

	local function term_send_line(payload)
		term_send(payload or "", { append_newline = true })
	end

	local function term_send_debug(payload)
		if is_windows then
			term_send(payload, { mode = "ipdb" })
		else
			term_send(payload, { append_newline = true })
		end
	end

	return {
		with_terminal = with_terminal,
		term_send = term_send,
		term_send_line = term_send_line,
		term_send_debug = term_send_debug,
	}
end

return Terminal
