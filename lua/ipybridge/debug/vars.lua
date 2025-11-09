-- Debug-aware variable helpers shared by the session and explorer UIs.
-- Responsible for digesting snapshots pushed from the kernel, selecting
-- the active scope, caching previews, and forwarding updates to the viewer.

local debug_scope = require("ipybridge.debug.scope")

local DebugVars = {}

local function sanitize_scope(scope)
	return debug_scope.sanitize_scope(scope)
end

local function resolve_scope(prefer_locals, locals_snapshot, globals_snapshot)
	return debug_scope.resolve_scope(prefer_locals, locals_snapshot, globals_snapshot)
end

local function lookup_preview(target, name)
	if type(target) ~= "table" then
		return nil
	end
	local entry = target[name]
	if type(entry) == "table" then
		local cache = entry._preview_cache
		if cache then
			return cache
		end
	end
	for _, item in pairs(target) do
		if type(item) == "table" then
			local children = item._preview_children
			if type(children) == "table" then
				local payload = children[name]
				if payload then
					return payload
				end
			end
		end
	end
	return nil
end

function DebugVars.preview_payload(state, name)
	if not name or name == "" then
		return nil
	end
	local scopes = {}
	local locals_snapshot = state._debug_locals_snapshot
	if type(locals_snapshot) == "table" and type(locals_snapshot.__locals__) == "table" then
		table.insert(scopes, locals_snapshot.__locals__)
	end
	local globals_snapshot = state._debug_globals_snapshot
	if type(globals_snapshot) == "table" then
		local gscope = globals_snapshot.__globals__
		if type(gscope) == "table" then
			table.insert(scopes, gscope)
		else
			table.insert(scopes, globals_snapshot)
		end
	end
	if type(state._latest_vars) == "table" then
		table.insert(scopes, state._latest_vars)
	end
	for _, scope in ipairs(scopes) do
		local payload = lookup_preview(scope, name)
		if payload then
			return payload
		end
	end
	return nil
end

function DebugVars.current_scope(state, prefer_locals)
	return resolve_scope(prefer_locals, state._debug_locals_snapshot, state._debug_globals_snapshot)
end

function DebugVars.digest_snapshot(state, snapshot)
	if type(snapshot) ~= "table" then
		state._latest_vars = {}
		return state._latest_vars
	end
	local has_debug_meta = snapshot.__scoped__ ~= nil or snapshot.__locals__ ~= nil or snapshot.__globals__ ~= nil
	if not has_debug_meta then
		state._debug_locals_snapshot = nil
		state._debug_globals_snapshot = nil
		state._latest_vars = sanitize_scope(snapshot)
		return state._latest_vars
	end
	local scoped_flag = snapshot.__scoped__
	local locals_scope = snapshot.__locals__
	local globals_scope = snapshot.__globals__
	if scoped_flag == true or (type(locals_scope) == "table" and next(locals_scope)) then
		state._debug_locals_snapshot = snapshot
	end
	if scoped_flag == false or type(globals_scope) == "table" or (not scoped_flag and snapshot.__locals__ == nil) then
		state._debug_globals_snapshot = snapshot
	end
	local prefer_locals = (state._debug_scope == "locals")
	state._latest_vars = DebugVars.current_scope(state, prefer_locals)
	return state._latest_vars
end

function DebugVars.push_to_explorer(state)
	local latest = state._latest_vars
	if not latest then
		return
	end
	local ok, vx = pcall(require, "ipybridge.var_explorer")
	if ok and vx and vx.on_vars then
		vx.on_vars(latest)
	end
end

return DebugVars
