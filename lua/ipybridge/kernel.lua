-- Kernel management helpers.
-- Launches a standalone IPython kernel, tracks its connection file, polls for
-- readiness, and exposes stop/ensure helpers with a Windows-friendly shutdown.

local uv = vim.uv
local fn = vim.fn
local py_module = require("ipybridge.py_module")
local is_windows = uv.os_uname().sysname == "Windows_NT"

local K = {
	job = nil,
	conn_file = nil,
}

local M = {}

local function helpers_root()
	local ok, path = pcall(py_module.path, "bootstrap_helpers.py")
	if not ok or type(path) ~= "string" or path == "" then
		return nil
	end
	local dir = vim.fs.dirname(path)
	return dir
end

local function build_env()
	local root = helpers_root()
	if not root then
		return nil
	end
	local loop = vim.loop or vim.uv
	local sysname = loop and loop.os_uname().sysname or ""
	local sep = sysname == "Windows_NT" and ";" or ":"
	local current = vim.env.PYTHONPATH or (loop and loop.os_getenv("PYTHONPATH")) or ""
	if current and current ~= "" then
		if current:find(root, 1, true) then
			return { PYTHONPATH = current }
		end
		return { PYTHONPATH = root .. sep .. current }
	end
	return { PYTHONPATH = root }
end

local function stop_job(job_id)
	if not job_id then
		return
	end
	pcall(fn.jobstop, job_id)
	if type(fn.jobwait) ~= "function" then
		return
	end
	local ok, result = pcall(fn.jobwait, { job_id }, 800)
	if not ok or type(result) ~= "table" then
		return
	end
	if result[1] ~= -1 or not is_windows then
		return
	end
	if type(fn.jobpid) ~= "function" or type(fn.system) ~= "function" then
		return
	end
	local pid = fn.jobpid(job_id)
	if type(pid) == "table" then
		pid = pid[1]
	end
	if type(pid) ~= "number" or pid <= 0 then
		return
	end
	pcall(fn.system, { "taskkill", "/T", "/F", "/PID", tostring(pid) })
end

-- Ensure a standalone Jupyter kernel is running and return its connection file via callback.
-- cb(ok:boolean, conn_file:string|nil)
function M.ensure(python_cmd, cb)
	if K.job and K.conn_file and uv.fs_stat(K.conn_file) then
		if cb then
			cb(true, K.conn_file)
		end
		return
	end
	local cf = fn.tempname() .. ".json"
	local cmd = { python_cmd or "python3", "-m", "ipykernel_launcher", "-f", cf }
	local job = fn.jobstart(cmd, {
		on_exit = function()
			K.job = nil
		end,
		env = build_env(),
	})
	if job <= 0 then
		if cb then
			cb(false)
		end
		return
	end
	K.job = job
	K.conn_file = cf
	-- Poll for the connection file to appear and be non-empty.
	local timer = uv.new_timer()
	local start = uv.now()
	local function tick()
		if (uv.now() - start) > 5000 then
			pcall(timer.stop, timer)
			pcall(timer.close, timer)
			if cb then
				cb(false)
			end
			return
		end
		local st = uv.fs_stat(cf)
		if st and st.type == "file" and st.size and st.size > 0 then
			pcall(timer.stop, timer)
			pcall(timer.close, timer)
			if cb then
				cb(true, cf)
			end
		end
	end
	timer:start(50, 100, vim.schedule_wrap(tick))
end

-- Resolve the current connection file, starting the kernel if needed.
function M.ensure_conn_file(python_cmd, cb)
	M.ensure(python_cmd, cb)
end

-- Stop the kernel job and clear connection info.
function M.stop()
	if K.job then
		stop_job(K.job)
	end
	K.job = nil
	K.conn_file = nil
end

return M
