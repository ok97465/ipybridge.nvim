-- Session environment helpers for ipybridge.
-- Builds the Jupyter console command and env overrides.

local M = {}

---Return the PATH separator and current PYTHONPATH for the host OS.
---@return string, string
local function resolve_sep()
	local loop = vim.loop or vim.uv
	local os_name = loop and loop.os_uname().sysname or ""
	if os_name == "Windows_NT" then
		return ";", loop and loop.os_getenv("PYTHONPATH") or ""
	end
	return ":", loop and loop.os_getenv("PYTHONPATH") or ""
end

---Build the Jupyter console command and env overrides for this session.
---@param ctx table
---@param state table
---@param conn_file string
---@return string, table
function M.build_console_env(ctx, state, conn_file)
	local completion = (state.config or {}).completion
	local suppress_readline_tab = true
	if completion then
		local priority = completion.engine_priority
		if type(priority) == "table" and vim.tbl_isempty(priority) then
			suppress_readline_tab = false
		end
	end
	local extra = ""
	if state.config.simple_prompt then
		extra = extra .. " --simple-prompt"
	end
	local cmd_console = string.format("jupyter console --existing %s%s", conn_file, extra)
	local env = {}
	-- Mark the console so the Python bootstrap knows to patch IPython prompts.
	-- Always set the patch flag so sitecustomize can either suppress or re-enable TAB.
	env.IPYBRIDGE_CONSOLE_PATCH = "1"
	env.IPYBRIDGE_CONSOLE_PATCH_SILENT = "1"
	if not suppress_readline_tab then
		-- Allow ipdb to keep its native TAB completion when completion engines are disabled.
		env.IPYBRIDGE_SUPPRESS_READLINE_TAB = "0"
	end
	local history_path = nil
	if ctx.utils and type(ctx.utils.state_path) == "function" then
		history_path = ctx.utils.state_path("ipdb_history")
	end
	if type(history_path) == "string" and #history_path > 0 then
		local parent = ctx.fn.fnamemodify(history_path, ":h")
		if parent and parent ~= "" then
			pcall(ctx.fn.mkdir, parent, "p")
		end
		env.IPYBRIDGE_IPDB_HISTORY_FILE = history_path
	end
	local bp_file = ctx.breakpoints.get_file_path()
	if bp_file and #bp_file > 0 then
		env.IPYBRIDGE_BREAKPOINT_FILE = bp_file
	end
	local ok_py_path, py_module_path = pcall(ctx.py_module.path, "bootstrap_helpers.py")
	if ok_py_path and type(py_module_path) == "string" and #py_module_path > 0 then
		local py_root = vim.fs.dirname(py_module_path)
		if py_root and #py_root > 0 then
			-- Ensure the Python bootstrap helpers are discoverable when IPython starts.
			local sep, current = resolve_sep()
			if current:find(py_root, 1, true) then
				env.PYTHONPATH = current
			elseif current ~= "" then
				env.PYTHONPATH = py_root .. sep .. current
			else
				env.PYTHONPATH = py_root
			end
		end
	end
	return cmd_console, env
end

return M
