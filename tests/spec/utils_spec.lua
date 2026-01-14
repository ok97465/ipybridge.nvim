-- Specs for the shared Lua utility helpers (selection ranges, quoting, etc.).
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

local function fresh_utils(opts)
	opts = opts or {}
	_G.vim = {
		uv = {
			fs_stat = function(path)
				return opts.fs_stat and opts.fs_stat(path) or nil
			end,
			fs_mkdir = opts.fs_mkdir,
			os_uname = opts.os_uname,
		},
		api = {
			nvim_buf_get_lines = function(_, s, e)
				local lines = opts.lines or {}
				local out = {}
				for i = s + 1, e do
					out[#out + 1] = lines[i] or ""
				end
				return out
			end,
			nvim_buf_get_mark = function(_, mark)
				local marks = opts.marks or {}
				return marks[mark] or { 0, 0 }
			end,
		},
		fn = {
			mode = function()
				return opts.mode or "n"
			end,
			getpos = function(sym)
				local positions = opts.positions or {}
				return positions[sym] or { 0, 1, 0, 0 }
			end,
			stdpath = function(kind)
				return opts.stdpath and opts.stdpath(kind) or nil
			end,
			expand = function(expr)
				return opts.expand and opts.expand(expr) or ""
			end,
			mkdir = function(path, mode)
				if opts.mkdir then
					return opts.mkdir(path, mode)
				end
				return nil
			end,
			system = function(cmd)
				return opts.system and opts.system(cmd) or ""
			end,
		},
		list_extend = function(dst, src)
			for _, v in ipairs(src or {}) do
				dst[#dst + 1] = v
			end
			return dst
		end,
		v = { shell_error = 0 },
	}
	package.loaded["ipybridge.utils"] = nil
	package.loaded["ipybridge.utils.fs"] = nil
	package.loaded["ipybridge.utils.platform"] = nil
	package.loaded["ipybridge.utils.paste"] = nil
	package.loaded["ipybridge.utils.selection"] = nil
	package.loaded["ipybridge.utils.py"] = nil
	package.loaded["ipybridge.utils.deps"] = nil
	return require("ipybridge.utils")
end

it("py_quote helpers normalise slashes and escape quotes", function()
	local utils = fresh_utils()
	local sample = "C:\\temp\\mix'\""
	assert(utils.py_quote_single(sample) == "C:/temp/mix\\'\"", "single quote helper did not escape correctly")
	assert(utils.py_quote_double(sample) == "C:/temp/mix'\\\"", "double quote helper did not escape correctly")
end)

it("selection_line_range honours visual selection order", function()
	local utils = fresh_utils({
		mode = "v",
		positions = {
			["v"] = { 0, 5, 0, 0 },
			["."] = { 0, 2, 0, 0 },
		},
	})
	local s, e = utils.selection_line_range()
	assert(s == 1, "expected start row adjusted to 0-index")
	assert(e == 5, "expected end row preserved")
end)

it("selection_line_range falls back to marks when not visual", function()
	local utils = fresh_utils({
		mode = "n",
		marks = {
			["<"] = { 3, 0 },
			[">"] = { 7, 0 },
		},
	})
	local s, e = utils.selection_line_range()
	assert(s == 2 and e == 7, "expected marks translated into range")
end)

it("state_path uses stdpath and ensures the state directory exists", function()
	-- Expect stdpath to be used and the state directory to be created.
	local mkdir_calls = {}
	local utils = fresh_utils({
		stdpath = function(kind)
			assert(kind == "data", "unexpected stdpath kind")
			return "/tmp/data"
		end,
		fs_stat = function()
			return nil
		end,
		fs_mkdir = function(path, mode)
			table.insert(mkdir_calls, { path = path, mode = mode })
		end,
		mkdir = function(path, mode)
			table.insert(mkdir_calls, { path = path, mode = mode })
		end,
	})
	local path = utils.state_path("foo.txt")
	assert(path == "/tmp/data/ipybridge/foo.txt", "expected state path under stdpath data directory")
	local saw_dir = false
	for _, entry in ipairs(mkdir_calls) do
		if entry.path == "/tmp/data/ipybridge" then
			saw_dir = true
			break
		end
	end
	assert(saw_dir, "expected state directory to be created")
end)

it("check_python_deps returns missing modules from helper output", function()
	-- Expect helper output to be parsed into a list of missing modules.
	local utils = fresh_utils()
	local captured = {}
	vim.gsplit = function(str, sep)
		local idx = 1
		return function()
			if idx > #str then
				return nil
			end
			local next_idx = str:find(sep, idx, true)
			local line
			if next_idx then
				line = str:sub(idx, next_idx - 1)
				idx = next_idx + #sep
			else
				line = str:sub(idx)
				idx = #str + 1
			end
			return line
		end
	end
	vim.v.shell_error = 0
	vim.fn.system = function(cmd)
		captured.cmd = cmd
		return "numpy\npandas\n"
	end
	package.loaded["ipybridge.py_module"] = {
		path = function(name)
			assert(name == "check_deps.py", "unexpected helper path request")
			return "/tmp/check_deps.py"
		end,
	}
	local missing = utils.check_python_deps("python3", { "numpy", "pandas" })
	assert(#missing == 2, "expected two missing modules")
	assert(missing[1] == "numpy" and missing[2] == "pandas", "missing list mismatch")
	assert(captured.cmd[1] == "python3", "expected python command prefix")
	assert(captured.cmd[2] == "/tmp/check_deps.py", "expected helper script path")
	assert(captured.cmd[3] == "numpy" and captured.cmd[4] == "pandas", "expected module args")
	package.loaded["ipybridge.py_module"] = nil
end)

it("check_python_deps returns an error when helper path is unavailable", function()
	-- Expect a user-facing error when the helper path cannot be resolved.
	local utils = fresh_utils()
	package.loaded["ipybridge.py_module"] = {
		path = function()
			error("boom")
		end,
	}
	local missing, err = utils.check_python_deps("python3", { "numpy" })
	assert(missing == nil, "missing list should be nil on helper failure")
	assert(err == "could not find check_deps.py", "unexpected error message")
	package.loaded["ipybridge.py_module"] = nil
end)

it("check_python_deps ignores failures from the helper process", function()
	-- Expect failures from the helper process to be ignored.
	local utils = fresh_utils()
	vim.v.shell_error = 1
	vim.fn.system = function()
		return "numpy\n"
	end
	package.loaded["ipybridge.py_module"] = {
		path = function()
			return "/tmp/check_deps.py"
		end,
	}
	local missing = utils.check_python_deps("python3", { "numpy" })
	assert(missing == nil, "missing list should be nil when helper fails")
	package.loaded["ipybridge.py_module"] = nil
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("utils_spec failed")
end

return true
