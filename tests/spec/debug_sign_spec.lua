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

local function expect(cond, message)
	if not cond then
		error(message or "expectation failed")
	end
end

local function with_stubbed_vim(run)
	local original_vim = _G.vim
	local api_calls = {
		set_option_value = {},
		get_option_value = {},
	}
	local fn_calls = {
		sign_define = {},
		sign_place = {},
		sign_unplace = {},
	}
	local windows = {}

	local function register_window(win, opts)
		windows[win] = {
			valid = opts.valid ~= false,
			signcolumn = opts.signcolumn or "auto",
		}
	end

	local vim_stub = {
		api = {
			nvim_set_option_value = function(name, value, opts)
				table.insert(api_calls.set_option_value, { name = name, value = value, opts = opts })
				if name == "signcolumn" and opts and opts.win and windows[opts.win] then
					windows[opts.win].signcolumn = value
				end
			end,
			nvim_get_option_value = function(name, opts)
				table.insert(api_calls.get_option_value, { name = name, opts = opts })
				if name == "signcolumn" and opts and opts.win and windows[opts.win] then
					return windows[opts.win].signcolumn
				end
				return "auto"
			end,
			nvim_win_is_valid = function(win)
				return windows[win] and windows[win].valid or false
			end,
		},
		fn = {
			sign_define = function(name, opts)
				table.insert(fn_calls.sign_define, { name = name, opts = opts })
			end,
			sign_place = function(id, group, name, bufnr, opts)
				table.insert(fn_calls.sign_place, { id = id, group = group, name = name, bufnr = bufnr, opts = opts })
				return id
			end,
			sign_unplace = function(group)
				table.insert(fn_calls.sign_unplace, { group = group })
			end,
		},
	}

	_G.vim = vim_stub

	register_window(10, { signcolumn = "auto:1" })
	register_window(11, { valid = false })

	package.loaded["ipybridge.debug_sign"] = nil
	local debug_sign = require("ipybridge.debug_sign")

	local status, err = pcall(run, {
		debug_sign = debug_sign,
		api_calls = api_calls,
		fn_calls = fn_calls,
		register_window = register_window,
	})

	_G.vim = original_vim

	if not status then
		error(err)
	end
end

it("places sign and widens signcolumn", function()
	with_stubbed_vim(function(ctx)
		local debug_sign = ctx.debug_sign
		debug_sign.place(3, 42, 10)
		expect(#ctx.fn_calls.sign_define == 1, "sign should define once on first use")
		expect(#ctx.fn_calls.sign_unplace == 1, "sign_unplace should fire before placement")
		expect(#ctx.fn_calls.sign_place == 1, "sign_place not invoked")
		local placed = ctx.fn_calls.sign_place[1]
		expect(placed.group == "IpybridgeDebugLine", "group mismatch")
		expect(placed.opts.lnum == 42, "line mismatch")
		expect(placed.opts.priority == 100, "priority unexpected")
		expect(#ctx.api_calls.set_option_value >= 1, "signcolumn not adjusted")
		expect(ctx.api_calls.set_option_value[#ctx.api_calls.set_option_value].value == "yes:3", "signcolumn should widen to yes:3")
	end)
end)

it("clears sign and restores previous signcolumn", function()
	with_stubbed_vim(function(ctx)
		local debug_sign = ctx.debug_sign
		debug_sign.place(2, 5, 10)
		ctx.api_calls.set_option_value = {}
		debug_sign.clear()
		expect(#ctx.fn_calls.sign_unplace >= 2, "sign should unplace during clear")
		expect(#ctx.api_calls.set_option_value >= 1, "clear should touch signcolumn")
		local restore = ctx.api_calls.set_option_value[#ctx.api_calls.set_option_value]
		expect(restore.value == "auto:1", "should restore original signcolumn width")
	end)
end)

it("can keep signcolumn pinned between breakpoints", function()
	with_stubbed_vim(function(ctx)
		local debug_sign = ctx.debug_sign
		debug_sign.place(4, 8, 10)
		ctx.api_calls.set_option_value = {}
		debug_sign.clear({ restore_signcolumn = false })
		expect(#ctx.api_calls.set_option_value == 0, "should not restore signcolumn when told to keep width")
		local placed_before = #ctx.fn_calls.sign_place
		debug_sign.place(4, 9, 10)
		expect(#ctx.fn_calls.sign_place == placed_before + 1, "should place new sign after breakpoint resumes")
		expect(#ctx.api_calls.set_option_value == 0, "signcolumn already pinned; no additional width change expected")
		ctx.api_calls.set_option_value = {}
		debug_sign.clear()
		expect(#ctx.api_calls.set_option_value >= 1, "final clear should restore signcolumn")
		local restore = ctx.api_calls.set_option_value[#ctx.api_calls.set_option_value]
		expect(restore.value == "auto:1", "final clear must return signcolumn to original width")
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
	error("debug_sign_spec failed")
end

return true
