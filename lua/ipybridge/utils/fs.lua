-- Filesystem helpers for ipybridge.
-- Handles state directory resolution and filesystem checks.

local M = {}

local function resolve_uv()
	return (vim and (vim.uv or vim.loop)) or nil
end

local function resolve_fn()
	return vim.fn
end

-- Ensure the target directory exists using the available filesystem APIs.
local function ensure_dir(path)
	if not path or path == "" then
		return
	end
	local uv = resolve_uv()
	local fn = resolve_fn()
	-- Try mkdir -p semantics with whichever API is available.
	if uv and uv.fs_stat and uv.fs_mkdir then
		if not uv.fs_stat(path) then
			pcall(uv.fs_mkdir, path, 448)
		end
	end
	if fn and fn.mkdir then
		pcall(fn.mkdir, path, "p")
	end
end

-- Resolve and create the plugin state directory.
local function state_dir()
	local fn = resolve_fn()
	local base = nil
	if fn and fn.stdpath then
		local ok, data_dir = pcall(fn.stdpath, "data")
		if ok and type(data_dir) == "string" and data_dir ~= "" then
			base = data_dir
		end
	end
	if base == nil or base == "" then
		local ok_home, home = pcall(fn.expand, "~")
		if ok_home and type(home) == "string" and home ~= "" then
			base = home .. "/.local/share"
		else
			base = "."
		end
	end
	local dir = tostring(base):gsub("\\", "/") .. "/ipybridge"
	ensure_dir(dir)
	return dir
end

---Check whether a filesystem path exists.
---@param path string
---@return boolean
function M.file_exists(path)
	local uv = resolve_uv()
	if not (uv and uv.fs_stat) then
		return false
	end
	return uv.fs_stat(path) and true or false
end

---Return a path inside the plugin's persistent state directory, creating it if needed.
---@param filename string|nil
---@return string|nil
function M.state_path(filename)
	local dir = state_dir()
	if not dir or dir == "" then
		return nil
	end
	if not filename or filename == "" then
		return dir
	end
	return (dir .. "/" .. tostring(filename)):gsub("\\", "/")
end

return M
