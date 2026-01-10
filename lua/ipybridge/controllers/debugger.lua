-- DebuggerController sends ipdb commands through the terminal transport while
-- enforcing state guards and optional teardown for debug sessions.

local DebuggerController = {}
DebuggerController.__index = DebuggerController

---Create a new DebuggerController instance.
---@param opts table
---@return table
function DebuggerController.new(opts)
	local self = setmetatable({}, DebuggerController)
	self.state = assert(opts.state, "debugger controller: state is required")
	self.term_send = assert(opts.term_send, "debugger controller: term_send is required")
	self.clear_debug_state = assert(opts.clear_debug_state, "debugger controller: clear_debug_state is required")
	self.is_open = assert(opts.is_open, "debugger controller: is_open checker is required")
	return self
end

---Send an ipdb command through the terminal transport.
---@param cmd string
---@param opts table|nil
function DebuggerController:send(cmd, opts)
	if not self.state._debug_active then
		vim.notify("ipybridge: Debugger is not active", vim.log.levels.WARN)
		return
	end
	if not self.is_open() then
		vim.notify("ipybridge: IPython terminal is not open", vim.log.levels.WARN)
		return
	end
	self.term_send(cmd)
	if opts and opts.deactivate then
		self.clear_debug_state({ restore_signcolumn = opts.restore_signcolumn })
	end
end

---Step over the current line in ipdb.
function DebuggerController:step_over()
	self:send("!next")
end

---Step into the current call in ipdb.
function DebuggerController:step_into()
	self:send("!step")
end

---Step out of the current frame in ipdb.
function DebuggerController:step_out()
	self:send("!return")
end

---Continue execution and clear debug state.
function DebuggerController:continue_exec()
	self:send("!continue", { deactivate = true, restore_signcolumn = false })
end

---Quit the debugger and clear debug state.
function DebuggerController:quit()
	self:send("!exit", { deactivate = true, restore_signcolumn = true })
end

return DebuggerController
