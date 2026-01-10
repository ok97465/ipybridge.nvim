-- Specs for completion_apply helper functions.
package.path = table.concat({
	"tests/?.lua",
	"tests/?/init.lua",
	"lua/?.lua",
	"lua/?/init.lua",
	package.path,
}, ";")

local results = {}

-- Record the outcome of each spec for a simple summary.
local function record(name, ok, err)
	table.insert(results, { name = name, ok = ok, err = err })
	if ok then
		io.write(string.format("[PASS] %s\n", name))
	else
		io.write(string.format("[FAIL] %s: %s\n", name, err))
	end
end

-- Register a test case and capture assertion failures.
local function it(name, fn)
	local ok, err = pcall(fn)
	record(name, ok, err)
end

-- Load completion_apply with a stubbed vim and env dependency.
local function fresh_apply(ctx)
	local prev_vim = _G.vim
	_G.vim = {
		schedule = function(cb)
			table.insert(ctx.scheduled, cb)
			if type(cb) == "function" then
				cb()
			end
		end,
	}
	package.loaded["ipybridge.cmp_bridge.env"] = {
		feed_terminal = function(keys)
			table.insert(ctx.feeds, keys)
		end,
	}
	package.loaded["ipybridge.cmp_bridge.completion_apply"] = nil
	local mod = require("ipybridge.cmp_bridge.completion_apply")
	return mod, prev_vim
end

it("prepare respects explicit textEdit ranges", function()
	-- Expect span and text to be derived from the textEdit range.
	local ctx = { scheduled = {}, feeds = {} }
	local mod, prev_vim = fresh_apply(ctx)
	local request = mod.prepare({
		item = {
			textEdit = {
				range = {
					start = { character = 2 },
					["end"] = { character = 5 },
				},
				newText = "alpha",
			},
		},
		context = { cursor_col = 5 },
	})
	assert(request.span == 3, "expected span to match range length")
	assert(request.text == "alpha", "expected newText to be used")
	_G.vim = prev_vim
end)

it("prepare falls back to cursor/token math when no textEdit exists", function()
	-- Expect span to be computed from cursor_col and token length.
	local ctx = { scheduled = {}, feeds = {} }
	local mod, prev_vim = fresh_apply(ctx)
	local request = mod.prepare({
		item = { label = "beta" },
		context = { cursor_col = 5, token = "abc" },
	})
	assert(request.span == 3, "expected span to equal token length")
	assert(request.text == "beta", "expected label to be used when insertText is absent")
	_G.vim = prev_vim
end)

it("commit feeds backspaces and text in order", function()
	-- Expect commit to invoke before/after hooks around feed operations.
	local ctx = { scheduled = {}, feeds = {} }
	local mod, prev_vim = fresh_apply(ctx)
	local events = {}
	mod.commit({ span = 2, text = "ok" }, {
		before_feed = function()
			table.insert(events, "before")
		end,
		after_feed = function()
			table.insert(events, "after")
		end,
	})
	assert(events[1] == "before" and events[2] == "after", "expected before/after hooks")
	assert(ctx.feeds[1] == "<BS><BS>", "expected backspaces to be fed first")
	assert(ctx.feeds[2] == "ok", "expected text to be fed second")
	_G.vim = prev_vim
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("completion_apply_spec failed")
end

return true
