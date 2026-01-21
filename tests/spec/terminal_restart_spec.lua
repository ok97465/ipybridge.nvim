-- Specs covering restart orchestration in the terminal controller.
package.path = table.concat({
	"tests/?.lua",
	"tests/?/init.lua",
	"lua/?.lua",
	"lua/?/init.lua",
	package.path,
}, ";")

local results = {}

local function record(name, ok, err)
	table.insert(results, { name = name, ok = ok, err = err })
	if ok then
		io.write(string.format("[PASS] %s\n", name))
	else
		io.write(string.format("[FAIL] %s: %s\n", name, err))
	end
end

local function it(name, fn)
	local ok, err = pcall(fn)
	record(name, ok, err)
end

local function fresh_controller()
	local ctx = {}
	ctx.prev_plot = package.preload["ipybridge.viewer.plot"]
	ctx.prev_zmq = package.preload["ipybridge.zmq_client"]
	package.loaded["ipybridge.controllers.terminal"] = nil
	package.preload["ipybridge.viewer.plot"] = function()
		return {
			reset_session = function()
				ctx.plot_reset = true
			end,
		}
	end
	package.preload["ipybridge.zmq_client"] = function()
		return {
			stop = function()
				ctx.zmq_stop = true
			end,
		}
	end

	local TerminalController = require("ipybridge.controllers.terminal")
	local term = {
		job_id = 21,
		buf_id = 8,
		win_id = 3,
	}
	function term:isshow()
		return true
	end
	function term:prepare_restart()
		self.prepared = true
	end

	local state = {
		term_instance = term,
	}
	local controller = TerminalController.new({
		state = state,
		fn = {
			jobstop = function(job_id)
				ctx.jobstop = job_id
			end,
		},
		kernel = {
			stop = function()
				ctx.kernel_stop = true
			end,
		},
		breakpoints = {
			on_session_close = function()
				ctx.breakpoints_closed = true
			end,
		},
		clear_debug_state = function()
			ctx.debug_cleared = true
		end,
		session_manager = {
			open = function(_, state, go_back, cb, opts)
				ctx.open = { state = state, go_back = go_back, opts = opts }
				if cb then
					cb(true)
				end
			end,
		},
		api = {
			nvim_get_current_win = function()
				return 11
			end,
			nvim_win_get_buf = function()
				return 99
			end,
			nvim_win_is_valid = function()
				return true
			end,
			nvim_set_current_win = function(win)
				ctx.set_win = win
			end,
		},
		with_terminal = function() end,
		is_open = function()
			return true
		end,
		navigator = {
			goto_terminal = function()
				ctx.goto_terminal = true
			end,
		},
	})
	return controller, state, term, ctx
end

it("restart reuses window and restores editor focus", function()
	local controller, state, term, ctx = fresh_controller()
	local ok, err = pcall(function()
		controller:restart()
		assert(term.prepared == true, "expected restart preparation")
		assert(ctx.jobstop == 21, "expected terminal jobstop")
		assert(controller._restart_pending ~= nil, "restart context should be queued")
		controller:handle_term_exit()
		assert(ctx.open and ctx.open.opts, "expected open call")
		assert(ctx.open.go_back == false, "restart open should not go_back")
		assert(ctx.open.opts.win_id == 3, "expected window reuse")
		assert(ctx.open.opts.cleanup_buf == 8, "expected cleanup buffer")
		assert(ctx.set_win == 11, "expected focus to return to editor window")
		assert(ctx.goto_terminal == nil, "terminal focus should not be forced")
		assert(controller._restart_pending == nil, "restart context should be cleared")
	end)
	package.preload["ipybridge.viewer.plot"] = ctx.prev_plot
	package.preload["ipybridge.zmq_client"] = ctx.prev_zmq
	package.loaded["ipybridge.viewer.plot"] = nil
	package.loaded["ipybridge.zmq_client"] = nil
	package.loaded["ipybridge.controllers.terminal"] = nil
	if not ok then
		error(err)
	end
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("terminal_restart_spec failed")
end

return true
