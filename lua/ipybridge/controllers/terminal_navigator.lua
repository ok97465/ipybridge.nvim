-- TerminalNavigator moves focus between the embedded IPython terminal window
-- and the user's previous editor window while tracking insertion state.

local TerminalNavigator = {}
TerminalNavigator.__index = TerminalNavigator

function TerminalNavigator.new(opts)
	local self = setmetatable({}, TerminalNavigator)
	self.state = assert(opts.state, "terminal navigator: state is required")
	self.api = assert(opts.api, "terminal navigator: api is required")
	self.with_terminal = assert(opts.with_terminal, "terminal navigator: with_terminal is required")
	return self
end

function TerminalNavigator:_remember_editor_win(current_win, current_buf, term_buf)
	if current_win and self.api.nvim_win_is_valid(current_win) then
		local bt = (vim.bo[current_buf] and vim.bo[current_buf].buftype) or ""
		if bt ~= "terminal" or current_buf ~= term_buf then
			self.state._prev_editor_win = current_win
		end
	end
end

function TerminalNavigator:goto_terminal()
	self.with_terminal(false, function()
		local term = self.state.term_instance
		if not term then
			return
		end

		local term_buf = term.buf_id
		local current_win = self.api.nvim_get_current_win()
		local current_buf = self.api.nvim_win_get_buf(current_win)
		local already_in_terminal = term_buf and current_buf == term_buf

		if not already_in_terminal then
			self:_remember_editor_win(current_win, current_buf, term_buf)
			term:show()
			if term.win_id and self.api.nvim_win_is_valid(term.win_id) then
				self.api.nvim_set_current_win(term.win_id)
			end
		end

		term:scroll_to_bottom()
		term:startinsert()
	end)
end

function TerminalNavigator:goto_editor()
	local curbuf = self.api.nvim_win_get_buf(0)
	local bt = (vim.bo[curbuf] and vim.bo[curbuf].buftype) or ""
	local stored_win = self.state._prev_editor_win

	if stored_win and not self.api.nvim_win_is_valid(stored_win) then
		stored_win = nil
		self.state._prev_editor_win = nil
	end

	local function jump_back()
		if not stored_win then
			return false
		end
		self.api.nvim_set_current_win(stored_win)
		self.state._prev_editor_win = nil
		return true
	end

	if bt == "terminal" then
		vim.cmd("stopinsert!")
		if jump_back() then
			return
		end
		vim.cmd("wincmd p")
		return
	end

	if self.state.term_instance and curbuf == self.state.term_instance.buf_id then
		self.state.term_instance:stopinsert()
		if jump_back() then
			return
		end
		vim.cmd("wincmd p")
	end
end

return TerminalNavigator
