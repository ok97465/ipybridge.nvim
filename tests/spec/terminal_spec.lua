-- Specs covering core terminal helpers (input clearing and send order).
package.path = table.concat({
	"tests/?.lua",
	"tests/?/init.lua",
	"lua/?.lua",
	"lua/?/init.lua",
	package.path,
}, ";")

local mock_vim = require("tests.helpers.mock_vim")

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

local function fresh_terminal()
	package.loaded["ipybridge.core.terminal"] = nil
	local env = mock_vim.new()
	_G.vim = env.vim
	vim.defer_fn = function(cb, _)
		cb()
	end
	local sent = {}
	local state = {
		term_instance = {
			send = function(_, payload)
				table.insert(sent, payload)
			end,
			job_id = 1,
		},
	}
	local terminal = require("ipybridge.core.terminal").new({
		state = state,
		is_open = function()
			return true
		end,
	})
	return terminal, sent
end

it("clears the input line before sending payload", function()
	local terminal, sent = fresh_terminal()
	terminal.term_send("print(1)")
	assert(#sent == 3, "expected clear, payload, and newline")
	assert(sent[1] == string.char(21), "expected Ctrl+U clear sequence")
	assert(sent[2] == "print(1)", "payload should follow the clear sequence")
	assert(sent[3] == "\n", "newline should be sent last")
end)

it("skips sending when payload is empty", function()
	local terminal, sent = fresh_terminal()
	terminal.term_send("")
	assert(#sent == 0, "no output should be sent for empty payloads")
end)

local all_ok = true
for _, result in ipairs(results) do
	if not result.ok then
		all_ok = false
		break
	end
end

if not all_ok then
	error("terminal_spec failed")
end

return true
