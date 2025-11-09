-- Shared glue used by custom cmp/blink sources to stream debugger completions.
-- Keeps track of inflight sessions, deduplicates empty responses, and plumbs
-- metadata onto completion items.
local completion_session = require("ipybridge.cmp_bridge.completion_session")

local M = {}

local function default_on_result()
end

local function default_on_empty()
end

---Stream completion items via completion_session with shared bookkeeping.
---@param opts table
---@field request_context table|nil
---@field dispatch_opts table|nil
---@field on_result fun(result: table, context: table, state: table)|nil
---@field on_empty fun()|nil
---@return table session_state
function M.stream(opts)
	opts = opts or {}
	local state = {
		total_emitted = 0,
		empty_notified = false,
	}
	local on_result = opts.on_result or default_on_result
	local on_empty = opts.on_empty or default_on_empty
	local session = completion_session.Session.new({
		request_context = opts.request_context or {},
		dispatch_opts = opts.dispatch_opts,
		on_result = function(result, context)
			local items = result.items or {}
			if #items > 0 then
				completion_session.attach_context_metadata(items, context)
				state.total_emitted = state.total_emitted + #items
			end
			local normalized = {
				items = items,
				isIncomplete = result.isIncomplete or false,
			}
			on_result(normalized, context, state)
			if not normalized.isIncomplete and state.total_emitted == 0 and not state.empty_notified then
				state.empty_notified = true
				on_empty()
			end
		end,
	})
	session:start()
	return state, session
end

return M
