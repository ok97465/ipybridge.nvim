-- TerminalController manages the IPython split lifecycle: open/close handling,
-- cleanup, and delegation of focus duties to the TerminalNavigator.

local TerminalNavigator = require("ipybridge.controllers.terminal_navigator")

local TerminalController = {}
TerminalController.__index = TerminalController

---Create a new TerminalController instance.
---@param opts table
---@return table
function TerminalController.new(opts)
	local self = setmetatable({}, TerminalController)
	self.state = assert(opts.state, "terminal controller: state is required")
	self.fn = assert(opts.fn, "terminal controller: fn is required")
	self.kernel = assert(opts.kernel, "terminal controller: kernel is required")
	self.breakpoints = assert(opts.breakpoints, "terminal controller: breakpoints are required")
	self.clear_debug_state = assert(opts.clear_debug_state, "terminal controller: clear_debug_state is required")
	self.session_manager = assert(opts.session_manager, "terminal controller: session_manager is required")
	self.api = assert(opts.api, "terminal controller: api is required")
	self.with_terminal = assert(opts.with_terminal, "terminal controller: with_terminal is required")
	self.is_open = assert(opts.is_open, "terminal controller: is_open checker is required")
	self.navigator = opts.navigator
		or TerminalNavigator.new({
			state = self.state,
			api = self.api,
			with_terminal = self.with_terminal,
		})
	return self
end

---Handle terminal exit events and trigger cleanup when needed.
function TerminalController:handle_term_exit()
	if self.state._term_exit_expected then
		self.state._term_exit_expected = false
		self.state.term_instance = nil
		return
	end
	self.state.term_instance = nil
	self:close()
end

---Open the IPython terminal session.
---@param go_back boolean|nil
---@param cb function|nil
function TerminalController:open(go_back, cb)
	self.session_manager:open(self.state, go_back, cb)
end

---Close the terminal session and tear down helper state.
function TerminalController:close()
	if self.is_open() then
		self.state._term_exit_expected = true
		self.fn.jobstop(self.state.term_instance.job_id)
	else
		self.state._term_exit_expected = false
	end
	self.clear_debug_state()
	self.state._zmq_ready = false
	self.state._zmq_bootstrap_pending = false
	self.state._zmq_waiters = {}
	pcall(function()
		require("ipybridge.zmq_client").stop()
	end)
	pcall(self.kernel.stop)
	if self.state._helpers_path then
		pcall(os.remove, self.state._helpers_path)
		self.state._helpers_path = nil
	end
	self.state._helpers_pending = false
	self.state._helpers_sent = false
	if self.state._runcell_path then
		pcall(os.remove, self.state._runcell_path)
		self.state._runcell_path = nil
	end
	self.breakpoints.on_session_close()
	self.state._latest_vars = nil
	self.state._pending_exec = {}
	self.state._helpers_waiters = {}
	self.state._prev_editor_win = nil
end

---Toggle the terminal session visibility.
function TerminalController:toggle()
	if self.is_open() then
		self:close()
		return
	end
	self.with_terminal(false, function()
		if self.state.term_instance then
			self.state.term_instance:startinsert()
		end
	end)
end

---Focus the IPython terminal window.
function TerminalController:goto_ipy()
	self.navigator:goto_terminal()
end

---Return focus to the previous editor window.
function TerminalController:goto_vi()
	self.navigator:goto_editor()
end

return TerminalController
