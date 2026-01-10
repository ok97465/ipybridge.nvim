-- Debug-aware variable helpers shared by the session and explorer UIs.
-- Responsible for digesting snapshots pushed from the kernel, selecting
-- the active scope, and forwarding updates to the viewer.

local debug_scope = require("ipybridge.debug.scope")

local DebugVars = {}

local function sanitize_scope(scope)
	return debug_scope.sanitize_scope(scope)
end

local function resolve_scope(prefer_locals, locals_snapshot, globals_snapshot)
	return debug_scope.resolve_scope(prefer_locals, locals_snapshot, globals_snapshot)
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
