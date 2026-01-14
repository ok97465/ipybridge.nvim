-- Session environment helpers for ipybridge.
-- Builds the Jupyter console command and env overrides.

local M = {}

---Return the PATH separator and current PYTHONPATH for the host OS.
---@return string, string
local function resolve_sep()
	local uv = vim.uv
	local os_name = uv.os_uname().sysname
	local pythonpath = uv.os_getenv("PYTHONPATH") or ""
	if os_name == "Windows_NT" then
		return ";", pythonpath
	end
	return ":", pythonpath
end

---Build the Jupyter console command and env overrides for this session.
---@param ctx table
---@param state table
---@param conn_file string
---@return string, table
function M.build_console_env(ctx, state, conn_file)
	local completion = state.config.completion
	local suppress_readline_tab = not vim.tbl_isempty(completion.engine_priority)
	local cmd_console = string.format("jupyter console --existing %s", conn_file)
	local env = {
		IPYBRIDGE_CONSOLE_PATCH = "1",
		IPYBRIDGE_CONSOLE_PATCH_SILENT = "1",
	}
	-- Mark the console so the Python bootstrap knows to patch IPython prompts.
	-- Always set the patch flag so sitecustomize can either suppress or re-enable TAB.
	if not suppress_readline_tab then
		-- Allow ipdb to keep its native TAB completion when completion engines are disabled.
		env.IPYBRIDGE_SUPPRESS_READLINE_TAB = "0"
	end
	local history_path = ctx.utils.state_path("ipdb_history")
	local parent = ctx.fn.fnamemodify(history_path, ":h")
	ctx.fn.mkdir(parent, "p")
	env.IPYBRIDGE_IPDB_HISTORY_FILE = history_path
	local bp_file = ctx.breakpoints.get_file_path()
	env.IPYBRIDGE_BREAKPOINT_FILE = bp_file
	local py_module_path = ctx.py_module.path("bootstrap_helpers.py")
	local py_root = vim.fs.dirname(py_module_path)
	-- Ensure the Python bootstrap helpers are discoverable when IPython starts.
	local sep, current = resolve_sep()
	if current:find(py_root, 1, true) then
		env.PYTHONPATH = current
	elseif current ~= "" then
		env.PYTHONPATH = py_root .. sep .. current
	else
		env.PYTHONPATH = py_root
	end
	return cmd_console, env
end

return M
