-- Dependency checker helpers for ipybridge.

local M = {}

---Check for missing Python dependencies by running check_deps.py.
---@param python_cmd string
---@param modules string[]
---@return string[]|nil, string|nil
function M.check_python_deps(python_cmd, modules)
	local fn = vim.fn
	local py_module = require("ipybridge.py_module")
	local ok_path, script_path = pcall(py_module.path, "check_deps.py")
	if not ok_path or not script_path then
		return nil, "could not find check_deps.py"
	end

	local cmd = { python_cmd, script_path }
	vim.list_extend(cmd, modules)

	local output = fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		-- Fallback to assuming dependencies are present if the check script fails.
		return nil
	end

	if output == "" then
		return nil
	end

	local missing = {}
	for s in vim.gsplit(output, "\n") do
		if s ~= "" then
			table.insert(missing, s)
		end
	end

	if #missing > 0 then
		return missing
	end

	return nil
end

return M
