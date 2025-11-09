local M = {
	source_name = "ipybridge_debug_hint",
	blink_source_module = "ipybridge.cmp_bridge.sources.blink",
	nvim_cmp_source_module = "ipybridge.cmp_bridge.sources.nvim_cmp",
	default_engine_priority = { "nvim-cmp", "blink.cmp" },
}

return M
