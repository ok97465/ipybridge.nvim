-- Tracks the Python-side server URL, opens the default browser, and exposes
-- navigation helpers (next/prev/delete) via the existing ZMQ client.

local PlotViewer = {}

local INLINE_BACKEND = "module://matplotlib_inline.backend_inline"
local INLINE_BACKEND_LABEL = "inline"
local REQUIRED_BACKEND = INLINE_BACKEND

local function deepcopy(value, seen)
	local vim_copy = _G.vim and _G.vim.deepcopy
	if vim_copy then
		return vim_copy(value)
	end
	if type(value) ~= "table" then
		return value
	end
	if seen and seen[value] then
		return seen[value]
	end
	local acc = {}
	seen = seen or {}
	seen[value] = acc
	for k, v in pairs(value) do
		acc[deepcopy(k, seen)] = deepcopy(v, seen)
	end
	return acc
end

local DEFAULT_CONFIG = {
	mode = "off", -- "browser" | "off"
	auto_open = true,
	history = 40,
}

local config = deepcopy(DEFAULT_CONFIG)

function PlotViewer.defaults()
	return deepcopy(DEFAULT_CONFIG)
end

local state = {
	server = nil,
	browser_opened = false,
	required_backend = REQUIRED_BACKEND,
}

local function format_backend_name(name)
	local value = tostring(name or "")
	if value == "" or value == "unknown" then
		return "unknown"
	end
	if value:find("matplotlib_inline", 1, true) then
		return INLINE_BACKEND_LABEL
	end
	return value
end

local function notify(message, level)
	vim.schedule(function()
		vim.notify(message, level or vim.log.levels.INFO)
	end)
end

---Configure the viewer.
---@param opts table
function PlotViewer.configure(opts)
	opts = opts or {}
	if opts.mode then
		config.mode = opts.mode
	end
	if opts.auto_open ~= nil then
		config.auto_open = opts.auto_open and true or false
	end
	if opts.history ~= nil then
		local value = tonumber(opts.history) or config.history
		if value > 0 then
			config.history = value
		end
	end
	state.required_backend = REQUIRED_BACKEND
	state.browser_opened = false
end

---Reset viewer state between IPython sessions.
function PlotViewer.reset_session()
	state.server = nil
	state.browser_opened = false
	state.required_backend = REQUIRED_BACKEND
end

function PlotViewer.mode()
	return config.mode
end

local function apply_status(payload, opts)
	opts = opts or {}
	if type(payload) ~= "table" then
		return
	end
	state.server = payload
	state.required_backend = payload.backend_required or REQUIRED_BACKEND
	local ready = payload.status == "ready"
	if ready and config.mode == "browser" and config.auto_open and not state.browser_opened and opts.auto_open ~= false then
		PlotViewer.open_browser()
	elseif payload.status == "stopped" then
		state.browser_opened = false
		if not opts.silent then
			notify("ipybridge: plot viewer stopped", vim.log.levels.WARN)
		end
	end
end

---Handle OSC payloads emitted by the Python runtime.
---@param payload table
function PlotViewer.on_server_event(payload)
	if config.mode ~= "browser" then
		return
	end
	if not payload then
		return
	end
	apply_status(payload)
end

local function open_with_system(url)
	local sysname = (vim.loop and vim.loop.os_uname().sysname) or ""
	local cmd
	if sysname == "Windows_NT" then
		cmd = { "powershell", "-NoProfile", "-Command", string.format("Start-Process \"%s\"", url) }
	elseif sysname == "Darwin" then
		cmd = { "open", url }
	else
		cmd = { "xdg-open", url }
	end
	vim.fn.jobstart(cmd, { detach = true })
end

---Open the browser UI.
function PlotViewer.open_browser()
	if config.mode ~= "browser" then
		notify("ipybridge: plot viewer disabled", vim.log.levels.WARN)
		return
	end
	local url = state.server and state.server.url or nil
	if not url or url == "" then
		pcall(PlotViewer.ensure_ready)
		notify("ipybridge: plot viewer not ready", vim.log.levels.WARN)
		return
	end
	local ok = pcall(vim.ui.open, url)
	if not ok then
		open_with_system(url)
	end
	state.browser_opened = true
end

local function dispatch(action, payload, cb, opts)
	opts = opts or {}
	if config.mode ~= "browser" then
		if not opts.silent then
			notify("ipybridge: plot viewer disabled", vim.log.levels.WARN)
		end
		return false
	end
	local z = require("ipybridge.zmq_client")
	local ok = z.request("plot", {
		action = action,
		payload = payload,
	}, function(message)
		if cb then
			cb(message)
		end
		if not message.ok and message.error and not opts.silent then
			notify("ipybridge: plot action failed - " .. message.error, vim.log.levels.WARN)
		end
	end)
	if not ok then
		if not opts.silent then
			notify("ipybridge: plot request failed to send", vim.log.levels.WARN)
		end
		return false
	end
	return true
end

function PlotViewer.next()
	dispatch("next")
end

function PlotViewer.prev()
	dispatch("prev")
end

function PlotViewer.delete(id)
	dispatch("delete", id and { id = id } or nil)
end

function PlotViewer.clear()
	dispatch("clear")
end

function PlotViewer.status()
	dispatch("status", nil, function(message)
		if not message.ok or not message.data then
			return
		end
		local data = message.data
		apply_status(data, { auto_open = false, silent = true })
		local backend = data.backend or "unknown"
		local active = data.backend_active
		local count = data.count or 0
		local summary = string.format("Plots: %d | Backend: %s | Active: %s", count, format_backend_name(backend), active and "yes" or "no")
		notify(summary, vim.log.levels.INFO)
	end)
end

function PlotViewer.server_options()
	if config.mode ~= "browser" then
		return nil
	end
	return {
		max_entries = config.history,
	}
end

local function request_enable()
	local options = PlotViewer.server_options() or {}
	dispatch("enable", options, function(message)
		if message and message.ok and message.data then
			apply_status(message.data)
			return
		end
		if message and message.error then
			notify("ipybridge: plot viewer enable failed - " .. message.error, vim.log.levels.WARN)
		end
	end, { silent = true })
end

function PlotViewer.ensure_ready()
	dispatch("status", nil, function(message)
		if not message or not message.ok or not message.data then
			request_enable()
			return
		end
		if message.data.status ~= "ready" then
			request_enable()
			return
		end
		apply_status(message.data)
	end, { silent = true })
end

PlotViewer.INLINE_BACKEND = INLINE_BACKEND

return PlotViewer
