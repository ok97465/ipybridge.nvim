-- Execution pipeline manager for ipybridge.nvim.
-- Coordinates helper bootstrap uploads, runcell injection, queued ZMQ exec
-- requests, and retries so editor actions reach the running kernel reliably.

local py_module = require("ipybridge.py_module")

local Executor = {}
Executor.__index = Executor

local function warn_once(message)
	vim.schedule(function()
		vim.notify(message, vim.log.levels.WARN)
	end)
end

local function notify_zmq_failure(reason)
	local message = "ipybridge: ZMQ execution failed"
	if reason and reason ~= "" then
		message = string.format("%s (%s)", message, tostring(reason))
	end
	warn_once(message)
end

local function is_transient_zmq_issue(reason)
	local r = tostring(reason or "")
	return r == "conn_file_unavailable" or r == "zmq_unavailable"
end

local function helpers_py_code()
	local template = py_module.source("bootstrap_helpers.py")
	local module_b64 = py_module.base64("ipybridge_ns.py")
	return template:gsub("__MODULE_B64__", module_b64)
end

local function runcell_py_code()
	return require("ipybridge.exec_magics").build()
end

local HELPER_RETRY_DELAY_MS = 120
local ZMQ_BOOTSTRAP_ATTEMPTS = 3
local ZMQ_BOOTSTRAP_RETRY_DELAY_MS = 200
local ZMQ_PING_ATTEMPTS = 20
local ZMQ_PING_DELAY_MS = 100
local ZMQ_WARMUP_CODE = "import zmq, jupyter_client"

local function resolve_zmq_backend_path(fn)
	local this = debug.getinfo(1, "S").source:sub(2)
	local plugin_dir = fn.fnamemodify(this, ":h")
	local repo_root = fn.fnamemodify(plugin_dir, ":h:h")
	return repo_root .. "/python/myipy_kernel_client.py"
end

local function warmup_zmq(fn, state, python_cmd, cb)
	if type(cb) ~= "function" then
		return
	end
	if state._zmq_warmup_done and state._zmq_warmup_cmd == python_cmd then
		cb()
		return
	end
	state._zmq_warmup_cmd = python_cmd
	local warmup_cmd = { python_cmd, "-c", ZMQ_WARMUP_CODE }
	local completed = false
	local function finish()
		if completed then
			return
		end
		completed = true
		state._zmq_warmup_done = true
		cb()
	end
	local job = fn.jobstart(warmup_cmd, {
		on_exit = function()
			vim.schedule(finish)
		end,
	})
	if job <= 0 then
		finish()
	end
end

function Executor.new(state, opts)
	local self = setmetatable({}, Executor)
	self.state = state
	self.fn = opts.fn
	self.term_send = opts.term_send
	self.ensure_conn_file = opts.ensure_conn_file
	self.is_open = opts.is_open
	return self
end

function Executor:_dispatch_exec_request(code, opts)
	opts = opts or {}
	local function handle_error(reason)
		if opts.on_error then
			opts.on_error(reason)
		else
			notify_zmq_failure(reason)
		end
	end
	local ok, z = pcall(require, "ipybridge.zmq_client")
	if not ok or not z then
		handle_error("zmq_client_unavailable")
		return
	end
	local dispatched = z.request("exec", { code = code }, function(msg)
		if msg and msg.ok then
			if opts.on_success then
				opts.on_success()
			end
		else
			local err = (msg and msg.error) or "exec_failed"
			handle_error(err)
		end
	end)
	if not dispatched then
		handle_error("dispatch_failed")
	end
end

function Executor:_run_helper_waiters(success)
	local waiters = self.state._helpers_waiters
	if #waiters == 0 then
		return
	end
	self.state._helpers_waiters = {}
	for _, cb in ipairs(waiters) do
		local ok, err = pcall(cb, success)
		if not ok then
			warn_once("ipybridge: helper callback failed: " .. tostring(err))
		end
	end
end

function Executor:_run_runcell_waiters(success)
	local waiters = self.state._runcell_waiters
	if #waiters == 0 then
		return
	end
	self.state._runcell_waiters = {}
	for _, cb in ipairs(waiters) do
		local ok, err = pcall(cb, success)
		if not ok then
			warn_once("ipybridge: runcell helper callback failed: " .. tostring(err))
		end
	end
end

function Executor:_run_zmq_waiters(success)
	local waiters = self.state._zmq_waiters
	if #waiters == 0 then
		return
	end
	self.state._zmq_waiters = {}
	for _, cb in ipairs(waiters) do
		local ok, err = pcall(cb, success)
		if not ok then
			warn_once("ipybridge: ensure_zmq callback failed: " .. tostring(err))
		end
	end
end

function Executor:after_helpers(cb)
	if type(cb) ~= "function" then
		return
	end
	local st = self.state
	if st._helpers_sent then
		local ok, err = pcall(cb, true)
		if not ok then
			warn_once("ipybridge: helper callback failed: " .. tostring(err))
		end
		return
	end
	table.insert(st._helpers_waiters, cb)
	self:ensure_helpers()
end

function Executor:ensure_helpers()
	local st = self.state
	if st._helpers_sent or st._helpers_pending or not self.is_open() then
		return
	end
	local code = helpers_py_code()
	st._helpers_pending = true
	local handled = false

	local function finalize_ok()
		handled = true
		st._helpers_pending = false
		st._helpers_sent = true
		self:_run_helper_waiters(true)
	end

	local function handle_failure(reason)
		if handled then
			return
		end
		handled = true
		st._helpers_pending = false
		if is_transient_zmq_issue(reason) and self.is_open() and not st._helpers_sent then
			vim.defer_fn(function()
				if self.is_open() and not st._helpers_sent then
					self:ensure_helpers()
				end
			end, HELPER_RETRY_DELAY_MS)
			return
		end
		self:_run_helper_waiters(false)
		local r = tostring(reason or "")
		notify_zmq_failure(r ~= "" and r or "helper_load_failed")
	end

	self:queue_exec(code, {
		on_success = finalize_ok,
		on_error = handle_failure,
	})
end

function Executor:ensure_runcell_helpers(cb)
	local st = self.state
	if st._runcell_sent then
		if type(cb) == "function" then
			local ok, err = pcall(cb, true)
			if not ok then
				warn_once("ipybridge: runcell helper callback failed: " .. tostring(err))
			end
		end
		return
	end
	if type(cb) == "function" then
		table.insert(st._runcell_waiters, cb)
	end
	if st._runcell_pending or not self.is_open() then
		return
	end
	local code = runcell_py_code()
	st._runcell_pending = true
	local resolved = false
	local function resolve(success)
		if resolved then
			return
		end
		resolved = true
		st._runcell_pending = false
		if success then
			st._runcell_sent = true
		end
		self:_run_runcell_waiters(success)
	end
	self:exec_with_pipeline(code, {
		require_helpers = true,
		on_success = function()
			resolve(true)
		end,
		on_error = function(reason)
			local r = tostring(reason or "")
			if (r == "helpers_failed" or r == "conn_file_unavailable" or r == "zmq_unavailable") and self.is_open() then
				st._runcell_pending = false
				vim.defer_fn(function()
					if self.is_open() and not st._runcell_sent then
						self:ensure_runcell_helpers()
					end
				end, HELPER_RETRY_DELAY_MS)
				return
			end
			resolve(false)
			notify_zmq_failure(r ~= "" and r or "runcell_helper_failed")
		end,
	})
end

function Executor:_flush_pending_exec()
	local st = self.state
	if not st._zmq_ready then
		return
	end
	local queue = st._pending_exec
	if #queue == 0 then
		return
	end
	st._pending_exec = {}
	for _, entry in ipairs(queue) do
		self:_dispatch_exec_request(entry.code, entry.opts or {})
	end
end

function Executor:flush_pending_exec()
	self:_flush_pending_exec()
end

function Executor:_fail_pending_exec(reason)
	local st = self.state
	local queue = st._pending_exec
	if #queue == 0 then
		return
	end
	st._pending_exec = {}
	for _, entry in ipairs(queue) do
		local opts = entry.opts or {}
		if opts.on_error then
			opts.on_error(reason)
		else
			notify_zmq_failure(reason)
		end
	end
end

function Executor:fail_pending_exec(reason)
	self:_fail_pending_exec(reason)
end

function Executor:queue_exec(code, opts)
	opts = opts or {}
	local st = self.state
	if st._zmq_ready then
		self:_dispatch_exec_request(code, opts)
		return
	end
	table.insert(st._pending_exec, { code = code, opts = opts })
	self:ensure_zmq(function(ok)
		if ok then
			self:_flush_pending_exec()
		else
			self:_fail_pending_exec("zmq_unavailable")
		end
	end)
end

function Executor:exec_with_pipeline(code, opts)
	opts = opts or {}
	local require_helpers = opts.require_helpers == true
	local queue_opts = {
		on_success = opts.on_success,
		on_error = opts.on_error,
	}
	local function dispatch()
		self:queue_exec(code, queue_opts)
	end
	if require_helpers then
		self:after_helpers(function(ok_helpers)
			if not ok_helpers then
				if opts.on_error then
					opts.on_error("helpers_failed")
				else
					notify_zmq_failure("helpers_failed")
				end
				return
			end
			dispatch()
		end)
		return
	end
	dispatch()
end

function Executor:ensure_zmq(cb)
	local st = self.state
	if st._zmq_ready then
		self:_flush_pending_exec()
		if cb then
			cb(true)
		end
		return
	end
	if type(cb) == "function" then
		table.insert(st._zmq_waiters, cb)
	end
	if st._zmq_bootstrap_pending then
		return
	end
	st._zmq_bootstrap_pending = true

	local backend = resolve_zmq_backend_path(self.fn)
	local attempt_count = 0
	local attempt_id = 0
	local finished = false

	local function bump_attempt_id()
		attempt_id = attempt_id + 1
		return attempt_id
	end

	local function invalidate_attempt()
		attempt_id = attempt_id + 1
	end

	local function is_stale(token)
		return finished or token ~= attempt_id
	end

	local function finalize(success, reason)
		if finished then
			return
		end
		finished = true
		st._zmq_bootstrap_pending = false
		if success then
			st._zmq_ready = true
			self:_flush_pending_exec()
		else
			self:_fail_pending_exec(reason or "zmq_unavailable")
		end
		self:_run_zmq_waiters(success)
	end

	local start_attempt
	local schedule_retry

	local function ping_backend(zmq_client, token)
		local tries = 0
		local function tick()
			if is_stale(token) then
				return
			end
			tries = tries + 1
			if tries > ZMQ_PING_ATTEMPTS then
				zmq_client.stop()
				schedule_retry("zmq_ping_timeout")
				return
			end
			local sent = zmq_client.request("ping", {}, function(msg)
				if is_stale(token) then
					return
				end
				if msg and msg.ok and msg.tag == "pong" then
					finalize(true)
				else
					vim.defer_fn(tick, ZMQ_PING_DELAY_MS)
				end
			end)
			if not sent then
				vim.defer_fn(tick, ZMQ_PING_DELAY_MS)
			end
		end
		tick()
	end

	local function start_backend(conn_file, token)
		local z = require("ipybridge.zmq_client")
		local ok_start = z.start(st.config.python_cmd, conn_file, backend, st.config.zmq_debug)
		if not ok_start then
			schedule_retry("zmq_start_failed")
			return
		end
		ping_backend(z, token)
	end

	schedule_retry = function(reason)
		if attempt_count >= ZMQ_BOOTSTRAP_ATTEMPTS then
			finalize(false, reason)
			return
		end
		invalidate_attempt()
		vim.defer_fn(function()
			if not finished then
				start_attempt()
			end
		end, ZMQ_BOOTSTRAP_RETRY_DELAY_MS)
	end

	start_attempt = function()
		attempt_count = attempt_count + 1
		local token = bump_attempt_id()
		self.ensure_conn_file(function(ok, conn_file)
			if is_stale(token) then
				return
			end
			if not ok then
				finalize(false, "conn_file_unavailable")
				return
			end
			start_backend(conn_file, token)
		end)
	end

	local python_cmd = st.config.python_cmd or "python3"
	warmup_zmq(self.fn, st, python_cmd, start_attempt)
end

return Executor
