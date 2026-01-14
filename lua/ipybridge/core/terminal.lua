-- Terminal helpers responsible for sending data into the IPython REPL and
-- ensuring the split exists before executing actions.
-- Keeps a small surface for terminal lifecycle and send helpers.

local Terminal = {}
local CTRL_U = string.char(21)

---Build terminal helpers for opening and sending input to IPython.
---@param ctx table
---@return table
function Terminal.new(ctx)
	local state = assert(ctx.state, "terminal: state table is required")
	local warn_user = ctx.warn_user or function() end
	local is_open = ctx.is_open or function()
		return state.term_instance ~= nil and type(state.term_instance.job_id) == "number" and state.term_instance.job_id > 0
	end
	local open_fn = ctx.open

	---Ensure the terminal is open before running the callback.
	---@param go_back boolean|nil
	---@param cb function
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

	---Send a payload to the terminal after clearing the input line, then append a newline.
	---@param payload string
	local function term_send(payload)
		if not state.term_instance then
			return
		end
		if type(payload) ~= "string" then
			return
		end
		if payload == "" then
			return
		end
		state.term_instance:send(CTRL_U)
		state.term_instance:send(payload)
		-- Defer the newline slightly so terminals that need a delay behave consistently.
		vim.defer_fn(function()
			if state.term_instance then
				state.term_instance:send("\n")
			end
		end, 30)
	end

	return {
		with_terminal = with_terminal,
		term_send = term_send,
	}
end

return Terminal
