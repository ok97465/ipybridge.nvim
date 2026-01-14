-- Filesystem helpers for ipybridge.
-- Handles state directory resolution and filesystem checks.

local M = {}

local uv = vim.uv
local fn = vim.fn

-- Ensure the target directory exists.
local function ensure_dir(path)
	if path == "" then
		return
	end
	fn.mkdir(path, "p")
end

-- Resolve and create the plugin state directory.
local function state_dir()
	local base = fn.stdpath("data")
	local dir = base:gsub("\\", "/") .. "/ipybridge"
	ensure_dir(dir)
	return dir
end

---Check whether a filesystem path exists.
---@param path string
---@return boolean
function M.file_exists(path)
	return uv.fs_stat(path) ~= nil
end

---Return a path inside the plugin's persistent state directory, creating it if needed.
---@param filename string|nil
---@return string
function M.state_path(filename)
	local dir = state_dir()
	if not filename or filename == "" then
		return dir
	end
	return (dir .. "/" .. filename):gsub("\\", "/")
end

return M
