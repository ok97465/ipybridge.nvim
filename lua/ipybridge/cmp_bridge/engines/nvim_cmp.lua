local constants = require("ipybridge.cmp_bridge.constants")
local env = require("ipybridge.cmp_bridge.env")
local completion_apply = require("ipybridge.cmp_bridge.completion_apply")
local nvim_cmp_source = require(constants.nvim_cmp_source_module)

local SOURCE_NAME = constants.source_name

local state = {
	patched = false,
	registered = false,
}

local cmp_required = false

local function cmp_module()
	local cmp = package.loaded["cmp"]
	if type(cmp) == "table" then
		return cmp
	end
	if not cmp_required then
		cmp_required = true
		local ok, loaded = pcall(require, "cmp")
		if ok and type(loaded) == "table" then
			return loaded
		end
	end
	return nil
end

local function with_cmp(fn)
	if type(fn) ~= "function" then
		return nil
	end
	local cmp = cmp_module()
	if not cmp then
		return nil
	end
	local ok, result = pcall(fn, cmp)
	if not ok then
		return nil
	end
	return result
end

local function source_configured(cmp)
	cmp = cmp or cmp_module()
	if not cmp or type(cmp.get_config) ~= "function" then
		return false
	end
	local ok, cfg = pcall(cmp.get_config)
	if not ok or type(cfg) ~= "table" then
		return false
	end
	local sources = cfg.sources
	if type(sources) ~= "table" then
		return false
	end
	for _, source in ipairs(sources) do
		if type(source) == "table" and source.name == SOURCE_NAME then
			return true
		end
	end
	return false
end

local function patch_cmp_api()
	if state.patched then
		return true
	end
	local cmp = cmp_module()
	if not cmp then
		return false
	end
	local cmp_utils = (type(cmp) == "table" and cmp.utils) or nil
	local cmp_api = cmp_utils and cmp_utils.api or package.loaded["cmp.utils.api"]
	if type(cmp_api) ~= "table" then
		local ok, loaded = pcall(require, "cmp.utils.api")
		if not ok or type(loaded) ~= "table" then
			return false
		end
		cmp_api = loaded
	end
	if type(cmp_api) ~= "table" then
		return false
	end
	local original_get_mode = cmp_api.get_mode or function()
		return nil
	end
	local original_is_insert_mode = cmp_api.is_insert_mode or function()
		return false
	end
	local original_is_suitable_mode = cmp_api.is_suitable_mode or function()
		return false
	end
	cmp_api.get_mode = function()
		if env.is_active_ipy_terminal() then
			return "i"
		end
		return original_get_mode()
	end
	cmp_api.is_insert_mode = function()
		if env.is_active_ipy_terminal() then
			return true
		end
		return original_is_insert_mode()
	end
	cmp_api.is_suitable_mode = function()
		if env.is_active_ipy_terminal() then
			return true
		end
		return original_is_suitable_mode()
	end
	state.patched = true
	return true
end

local function cmp_is_visible()
	local visible = with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" then
			return false
		end
		return cmp.visible()
	end)
	return visible and true or false
end

local function cmp_close_if_visible()
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or type(cmp.close) ~= "function" then
			return
		end
		if cmp.visible() then
			pcall(cmp.close)
		end
	end)
end

local function cmp_abort_if_visible()
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or type(cmp.abort) ~= "function" then
			return
		end
		if cmp.visible() then
			pcall(cmp.abort)
		end
	end)
end

local function cmp_select(direction)
	with_cmp(function(cmp)
		if type(cmp.visible) ~= "function" or not cmp.visible() then
			return
		end
		local behavior = cmp.SelectBehavior and cmp.SelectBehavior.Select
		local opts = behavior and { behavior = behavior } or nil
		local selector
		if direction == "next" then
			selector = cmp.select_next_item
		elseif direction == "prev" then
			selector = cmp.select_prev_item
		end
		if type(selector) ~= "function" then
			return
		end
		if opts then
			pcall(selector, opts)
		else
			pcall(selector)
		end
	end)
end

local function close_menu()
	vim.schedule(function()
		cmp_close_if_visible()
	end)
end

local function apply_completion()
	local cmp = cmp_module()
	if not cmp or not cmp.visible() then
		return false
	end
	local entry = cmp.get_selected_entry()
	if not entry then
		local entries = cmp.get_entries()
		entry = entries and entries[1] or nil
	end
	if not entry then
		vim.schedule(function()
			cmp_close_if_visible()
		end)
		return false
	end
	local item = entry.completion_item or {}
	local metadata
	local data = item.data
	if type(data) == "table" then
		local tag = data.__ipybridge
		if type(tag) == "table" then
			metadata = tag
		end
	end
	local request = completion_apply.prepare({
		item = item,
		context = {
			cursor_col = metadata and metadata.cursor_col or nil,
			cursor_col_start = metadata and metadata.cursor_col_start or nil,
		},
	})
	completion_apply.commit(request, {
		before_feed = cmp_close_if_visible,
	})
	return true
end

local function ensure_source(cmp)
	if state.registered then
		return true
	end
	cmp.register_source(SOURCE_NAME, nvim_cmp_source.new({
		on_empty = close_menu,
	}))
	state.registered = true
	return true
end

local cmp_engine = {
	id = "nvim-cmp",
}

function cmp_engine:is_available()
	local cmp = cmp_module()
	if not cmp then
		return false
	end
	return source_configured(cmp)
end

function cmp_engine:ensure()
	local cmp = cmp_module()
	if not cmp then
		return false
	end
	if not source_configured(cmp) then
		return false
	end
	if not patch_cmp_api() then
		return false
	end
	if not ensure_source(cmp) then
		return false
	end
	return true
end

function cmp_engine:is_visible()
	return cmp_is_visible()
end

function cmp_engine:close()
	cmp_close_if_visible()
end

function cmp_engine:abort()
	cmp_abort_if_visible()
end

function cmp_engine:select(direction)
	cmp_select(direction)
end

function cmp_engine:accept()
	return apply_completion()
end

function cmp_engine:trigger()
	if not source_configured() then
		return false
	end
	return with_cmp(function(active)
		if type(active.complete) ~= "function" then
			return false
		end
		local reason = active.ContextReason and active.ContextReason.Manual or nil
		vim.schedule(function()
			active.complete({
				reason = reason,
			})
		end)
		return true
	end) and true or false
end

return cmp_engine
