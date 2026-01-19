-- Specs validating plot viewer auto-open behavior across sessions.
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

local function fresh_env()
	local open_calls = {}
	local notifications = {}
	local vim_env = {
		notify = function(message, level)
			table.insert(notifications, { message = message, level = level })
		end,
		schedule = function(fn)
			fn()
		end,
		ui = {
			open = function(url)
				table.insert(open_calls, url)
			end,
		},
		fn = {
			jobstart = function() end,
		},
		loop = {
			os_uname = function()
				return { sysname = "Linux" }
			end,
		},
		log = {
			levels = {
				INFO = "INFO",
				WARN = "WARN",
			},
		},
	}
	_G.vim = vim_env
	return {
		vim = vim_env,
		open_calls = open_calls,
		notifications = notifications,
	}
end

it("reopens browser after session close resets viewer state", function()
	local env = fresh_env()
	package.loaded["ipybridge.viewer.plot"] = nil
	local plot_viewer = require("ipybridge.viewer.plot")
	plot_viewer.configure({ mode = "browser", auto_open = true })

	plot_viewer.on_server_event({
		status = "ready",
		url = "http://first",
		backend_required = plot_viewer.INLINE_BACKEND,
	})
	assert(#env.open_calls == 1, "initial auto-open missing")

	local prev_zmq = package.loaded["ipybridge.zmq_client"]
	package.loaded["ipybridge.zmq_client"] = {
		stop = function() end,
	}
	package.loaded["ipybridge.controllers.terminal"] = nil
	local TerminalController = require("ipybridge.controllers.terminal")
	local controller = TerminalController.new({
		state = {
			term_instance = { job_id = 10 },
		},
		fn = { jobstop = function() end },
		kernel = { stop = function() end },
		breakpoints = { on_session_close = function() end },
		clear_debug_state = function() end,
		session_manager = {},
		api = {},
		with_terminal = function() end,
		is_open = function()
			return true
		end,
		navigator = {},
	})
	controller:close()
	package.loaded["ipybridge.zmq_client"] = prev_zmq

	plot_viewer.on_server_event({
		status = "ready",
		url = "http://second",
		backend_required = plot_viewer.INLINE_BACKEND,
	})
	assert(#env.open_calls == 2, "browser should auto-open after session reset")
	assert(env.open_calls[2] == "http://second", "expected new URL to open")
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("plot_viewer_spec failed")
end

return true
