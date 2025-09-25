-- Python module utilities for ipybridge.nvim
-- Provides helpers to locate bundled Python modules and encode them.

local M = {}

local cache = {}

local function current_root()
  local info = debug.getinfo(1, 'S')
  local src = info and info.source or ''
  if vim.startswith(src, '@') then
    src = src:sub(2)
  end
  local dir = vim.fs.dirname(src)
  if not dir then
    return vim.loop.cwd()
  end
  local upper = vim.fs.dirname(dir)
  if not upper then
    return dir
  end
  local root = vim.fs.dirname(upper)
  return root or upper
end

local function module_path(name)
  local root = current_root()
  return vim.fs.joinpath(root, 'python', name)
end

local function read_file(path)
  local fd = assert(vim.loop.fs_open(path, 'r', 438))
  local stat = assert(vim.loop.fs_fstat(fd))
  local data = assert(vim.loop.fs_read(fd, stat.size, 0))
  assert(vim.loop.fs_close(fd) == true)
  return data
end

local function base64_encode(str)
  return vim.base64.encode(str)
end

function M.source(name)
  if cache[name] and cache[name].source then
    return cache[name].source
  end
  local path = module_path(name)
  local data = read_file(path)
  cache[name] = cache[name] or {}
  cache[name].source = data
  return data
end

function M.base64(name)
  if cache[name] and cache[name].base64 then
    return cache[name].base64
  end
  local src = M.source(name)
  local encoded = base64_encode(src)
  cache[name] = cache[name] or {}
  cache[name].base64 = encoded
  return encoded
end

function M.path(name)
  return module_path(name)
end

return M
