-- Engine registry that abstracts over different completion frontends.
-- Keeps track of registered adapters (nvim-cmp/blink), picks the best one,
-- and proxies lifecycle actions (ensure/show/close/accept/etc.).
local M = {}

local registry = {}
local registered_ids = {}
local order = {}
local active_id = nil
local preferred_ids = nil


local function rebuild_order()
	order = {}
	local inserted = {}
	if preferred_ids then
		for _, id in ipairs(preferred_ids) do
			local engine = registry[id]
			if engine then
				order[#order + 1] = engine
				inserted[id] = true
			end
		end
	else
		for _, id in ipairs(registered_ids) do
			local engine = registry[id]
			if engine then
				order[#order + 1] = engine
				inserted[id] = true
			end
		end
	end
	if active_id then
		local active = registry[active_id]
		local still_listed = false
		for _, engine in ipairs(order) do
			if engine == active then
				still_listed = true
				break
			end
		end
		if not still_listed then
			active_id = nil
		end
	end
end

local function notify_failure(engine_id, method, err)
	vim.schedule(function()
		vim.notify(
			string.format("ipybridge: engine %s.%s failed: %s", engine_id or "?", method, err),
			vim.log.levels.WARN
		)
	end)
end

local function engine_available(engine)
	if type(engine) ~= "table" or type(engine.is_available) ~= "function" then
		return false
	end
	local ok, result = pcall(engine.is_available, engine)
	return ok and result or false
end

local function safe_call(engine, method, ...)
	if not engine or type(engine[method]) ~= "function" then
		return false
	end
	local ok, result = pcall(engine[method], engine, ...)
	if not ok then
		notify_failure(engine.id, method, result)
		return false
	end
	return result
end

local function pick_best_available()
	for _, engine in ipairs(order) do
		if engine_available(engine) then
			return engine
		end
	end
	return nil
end

local function select_engine()
	if active_id then
		local engine = registry[active_id]
		if engine and engine_available(engine) then
			local best = pick_best_available()
			if best and best ~= engine then
				active_id = best.id
				return best
			end
			return engine
		end
		active_id = nil
	end
	local best = pick_best_available()
	if best then
		active_id = best.id
	end
	return best
end

local function ensure_engine()
	local attempted = {}
	while true do
		local engine = select_engine()
		if not engine then
			return nil
		end
		if attempted[engine.id] then
			return nil
		end
		attempted[engine.id] = true
		if safe_call(engine, "ensure") then
			active_id = engine.id
			return engine
		end
		if active_id == engine.id then
			active_id = nil
		end
	end
end

function M.register(engine)
	assert(type(engine) == "table", "engine must be a table")
	assert(type(engine.id) == "string" and engine.id ~= "", "engine.id must be a non-empty string")
	if registry[engine.id] then
		return
	end
	registry[engine.id] = engine
	registered_ids[#registered_ids + 1] = engine.id
	rebuild_order()
end

local function normalize_preference(list)
	if type(list) ~= "table" then
		return nil
	end
	local normalized = {}
	for _, id in ipairs(list) do
		if type(id) == "string" and id ~= "" then
			normalized[#normalized + 1] = id
		end
	end
	if #normalized == 0 then
		return nil
	end
	return normalized
end

function M.set_preference(list)
	preferred_ids = normalize_preference(list)
	rebuild_order()
end

function M.ensure()
	return ensure_engine()
end

function M.is_visible()
	local engine = select_engine()
	if not engine then
		return false
	end
	return safe_call(engine, "is_visible") and true or false
end

function M.close()
	local engine = select_engine()
	if not engine then
		return
	end
	safe_call(engine, "close")
end

function M.abort()
	local engine = select_engine()
	if not engine then
		return
	end
	safe_call(engine, "abort")
end

function M.select(direction)
	if not direction then
		return
	end
	local engine = select_engine()
	if not engine then
		return
	end
	safe_call(engine, "select", direction)
end

function M.accept()
	local engine = select_engine()
	if not engine then
		return false
	end
	return safe_call(engine, "accept") and true or false
end

function M.trigger()
	local engine = ensure_engine()
	if not engine then
		return false
	end
	return safe_call(engine, "trigger") and true or false
end

return M
