-- Specs for the SyncController logic (var filters and debugfile imports).
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

-- Build a minimal vim stub that satisfies SyncController dependencies.
local function stub_vim(ctx)
	local prev_vim = _G.vim

	local function json_quote(text)
		local escaped = tostring(text or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
		return '"' .. escaped .. '"'
	end

	local function encode_json(value)
		if type(value) == "string" then
			return json_quote(value)
		end
		if type(value) == "number" then
			return tostring(value)
		end
		if type(value) == "boolean" then
			return value and "true" or "false"
		end
		if type(value) == "table" then
			local parts = {}
			for _, v in ipairs(value) do
				if type(v) == "string" then
					table.insert(parts, json_quote(v))
				else
					table.insert(parts, tostring(v))
				end
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		return "null"
	end

	_G.vim = {
		json = { encode = encode_json },
		trim = function(text)
			return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
		end,
		defer_fn = function(cb, delay)
			table.insert(ctx.defer_calls, { delay = delay, cb = cb })
		end,
	}
	return prev_vim
end

-- Create a controller instance with stubbed dependencies.
local function fresh_controller(config, templates)
	local ctx = {
		warnings = {},
		defer_calls = {},
		exec_calls = {},
		ensure_helpers_called = 0,
		is_open = true,
		templates = templates or {},
	}
	local prev_vim = stub_vim(ctx)
	package.loaded["ipybridge.controllers.sync"] = nil
	local SyncController = require("ipybridge.controllers.sync")
	local state = {
		config = config or {},
		_last_filters_signature = nil,
		_debugfile_imports_signature = nil,
	}
	local controller = SyncController.new({
		state = state,
		py_module = {
			source = function(name)
				return ctx.templates[name]
			end,
		},
		exec_with_pipeline = function(script, opts)
			table.insert(ctx.exec_calls, { script = script, opts = opts })
		end,
		ensure_helpers = function()
			ctx.ensure_helpers_called = ctx.ensure_helpers_called + 1
		end,
		is_open = function()
			return ctx.is_open
		end,
		warn_user = function(msg)
			table.insert(ctx.warnings, msg)
		end,
	})
	return controller, state, ctx, prev_vim
end

it("sync_var_filters renders the template and caches signatures", function()
	-- Expect template substitution and signature caching to prevent re-sends.
	local controller, state, ctx, prev_vim = fresh_controller({
		hidden_var_names = { "alpha" },
		hidden_type_names = { "int" },
		var_repr_limit = 77,
		zmq_debug = true,
	}, {
		["sync_filters.py"] = "names=__NAMES_JSON__ types=__TYPES_JSON__ max=__MAX_REPR__ logs=__ENABLE_LOGS__",
	})

	controller:sync_var_filters()

	assert(ctx.ensure_helpers_called == 1, "ensure_helpers should be called once")
	assert(#ctx.exec_calls == 1, "expected one exec call")
	assert(
		ctx.exec_calls[1].script == 'names=["alpha"] types=["int"] max=77 logs=True',
		"template substitutions did not apply"
	)
	assert(ctx.exec_calls[1].opts.require_helpers == true, "helpers should be required for sync")
	assert(state._last_filters_signature ~= nil, "signature should be cached")

	controller:sync_var_filters()
	assert(#ctx.exec_calls == 1, "expected cached signature to skip dispatch")

	_G.vim = prev_vim
end)

it("sync_var_filters schedules retry on transient errors", function()
	-- Expect transient errors to trigger a deferred retry without warnings.
	local controller, state, ctx, prev_vim = fresh_controller({
		hidden_var_names = { "alpha" },
		hidden_type_names = { "int" },
	}, {
		["sync_filters.py"] = "names=__NAMES_JSON__ types=__TYPES_JSON__ max=__MAX_REPR__ logs=__ENABLE_LOGS__",
	})

	local on_error
	controller.exec_with_pipeline = function(_script, opts)
		on_error = opts and opts.on_error or nil
	end

	controller:sync_var_filters()
	assert(state._last_filters_signature ~= nil, "signature should be set before error callback")
	on_error("zmq_unavailable")

	assert(#ctx.defer_calls == 1, "expected a deferred retry")
	assert(ctx.defer_calls[1].delay == 150, "unexpected retry delay")
	assert(#ctx.warnings == 0, "warnings should be suppressed on retry")
	assert(state._last_filters_signature == nil, "signature should reset after error")

	_G.vim = prev_vim
end)

it("sync_debugfile_imports caches signature and honors callbacks", function()
	-- Expect debugfile imports to be sent once and cached.
	local controller, state, ctx, prev_vim = fresh_controller({
		debugfile_auto_imports = "import math",
	}, {
		["set_debugfile_imports.py"] = "block=__IMPORTS_JSON__",
	})

	controller.exec_with_pipeline = function(script, opts)
		table.insert(ctx.exec_calls, { script = script, opts = opts })
		if opts and opts.on_success then
			opts.on_success()
		end
	end

	local cb_calls = {}
	controller:sync_debugfile_imports(function(ok)
		table.insert(cb_calls, ok)
	end)

	assert(ctx.ensure_helpers_called == 1, "ensure_helpers should be called for sync_debugfile_imports")
	assert(#ctx.exec_calls == 1, "expected one exec call for imports")
	assert(ctx.exec_calls[1].script == 'block="import math"', "imports template mismatch")
	assert(state._debugfile_imports_signature ~= nil, "signature should be cached")
	assert(cb_calls[1] == true, "callback should receive success")

	controller:sync_debugfile_imports(function(ok)
		table.insert(cb_calls, ok)
	end)

	assert(#ctx.exec_calls == 1, "cached signature should skip execution")
	assert(cb_calls[2] == true, "callback should return success when cached")

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
	error("sync_controller_spec failed")
end

return true
