-- Specs covering debug cursor tooltip formatting and identifier extraction.
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

local function with_cursor_tooltip(run)
	local prev_vim = _G.vim
	_G.vim = { api = {}, fn = {} }
	package.loaded["ipybridge.debug.cursor_tooltip"] = nil
	local tooltip = require("ipybridge.debug.cursor_tooltip")
	local ok, err = pcall(run, tooltip)
	_G.vim = prev_vim
	if not ok then
		error(err)
	end
end

it("extracts a simple identifier under the cursor", function()
	with_cursor_tooltip(function(tooltip)
		local name = tooltip._extract_identifier("alpha = 1", 1)
		assert(name == "alpha", "expected alpha to be extracted")
	end)
end)

it("skips attribute names in dotted expressions", function()
	with_cursor_tooltip(function(tooltip)
		local name = tooltip._extract_identifier("foo.bar", 4)
		assert(name == nil, "attribute name should be ignored")
	end)
end)

it("accepts base variable in dotted expressions", function()
	with_cursor_tooltip(function(tooltip)
		local name = tooltip._extract_identifier("foo.bar", 1)
		assert(name == "foo", "base name should be extracted")
	end)
end)

it("rejects invalid identifiers", function()
	with_cursor_tooltip(function(tooltip)
		local name = tooltip._extract_identifier("1abc", 0)
		assert(name == nil, "identifier starting with digit should be rejected")
	end)
end)

it("formats preview lines from repr data", function()
	with_cursor_tooltip(function(tooltip)
		local lines = tooltip._format_entry("x", { repr = "42" })
		assert(lines[1] == "x = 42", "expected repr line")
	end)
end)

it("sanitizes newlines in repr strings", function()
	with_cursor_tooltip(function(tooltip)
		local lines = tooltip._format_entry("x", { repr = "a\nb" })
		assert(lines[1] == "x = a b", "expected newline to be replaced with space")
	end)
end)

it("formats entries without repr using type", function()
	with_cursor_tooltip(function(tooltip)
		local lines = tooltip._format_entry("x", { type = "int" })
		assert(lines[1] == "x (int)", "expected type fallback line")
	end)
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("debug_cursor_tooltip_spec failed")
end

return true
