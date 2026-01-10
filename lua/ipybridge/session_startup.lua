-- Startup helper routines for ipybridge sessions.
-- Collects deferred startup instructions for the IPython console.

local M = {}

---Collect startup magics/scripts to run after the console opens.
---@param ctx table
---@param state table
---@param cwd string
---@return table
function M.collect_startup_instructions(ctx, state, cwd)
	-- Build the list of IPython setup commands we want to replay once the console is ready.
	local config = state.config
	local startup_magics = {}
	local warmup_code = nil

	if config.matplotlib_backend and #tostring(config.matplotlib_backend) > 0 then
		local raw_backend = tostring(config.matplotlib_backend)
		local lowered = raw_backend:lower()
		local backend_aliases = {
			qtagg = "qt",
			qt5agg = "qt",
			qt6agg = "qt",
			tkagg = "tk",
			macosx = "macosx",
			osx = "macosx",
		}
		local magic_backend = backend_aliases[lowered] or lowered
		table.insert(startup_magics, string.format("%%matplotlib %s", magic_backend))
		if ctx.is_windows then
			local is_qt = magic_backend == "qt" or magic_backend == "qt5" or magic_backend == "qt6"
			if is_qt then
				-- Prime the Qt event loop on Windows so the first plot does not hang the session.
				warmup_code = table.concat({
					"import matplotlib.pyplot as _ipybridge_warm_plt",
					"_ipybridge_warm_plt.ion()",
					"_ipybridge_warm_fig = _ipybridge_warm_plt.figure()",
					"try:",
					"    _ipybridge_warm_win = getattr(_ipybridge_warm_fig.canvas.manager, 'window', None)",
					"    if _ipybridge_warm_win is not None:",
					"        try:",
					"            _ipybridge_warm_win.setWindowTitle('Matplotlib')",
					"        except Exception:",
					"            pass",
					"        try:",
					"            _ipybridge_warm_win.show()",
					"        except Exception:",
					"            pass",
					"        for _ipybridge_warm_attr in ('showNormal', 'raise_', 'activateWindow'):",
					"            try:",
					"                getattr(_ipybridge_warm_win, _ipybridge_warm_attr)()",
					"            except Exception:",
					"                pass",
					"    _ipybridge_warm_plt.pause(0.25)",
					"finally:",
					"    try:",
					"        _ipybridge_warm_win = getattr(_ipybridge_warm_fig.canvas.manager, 'window', None)",
					"        if _ipybridge_warm_win is not None:",
					"            try:",
					"                _ipybridge_warm_win.close()",
					"            except Exception:",
					"                pass",
					"    except Exception:",
					"        pass",
					"    _ipybridge_warm_plt.close(_ipybridge_warm_fig)",
					"    del _ipybridge_warm_fig",
				}, "\n")
			end
		end
	end

	if config.ipython_colors and #tostring(config.ipython_colors) > 0 then
		local c = tostring(config.ipython_colors)
		table.insert(startup_magics, string.format("%%colors %s", c))
	end

	local ar = config.autoreload
	if ar == nil then
		ar = 2
	end
	local mode = tostring(ar)
	if mode == "1" or mode == "2" then
		table.insert(startup_magics, "%load_ext autoreload")
		table.insert(startup_magics, string.format("%%autoreload %s", mode))
	end

	local startup_stmt = nil
	local path_startup_script = ctx.fs.joinpath(cwd, config.startup_script)
	if ctx.utils.file_exists(path_startup_script) then
		startup_stmt = ctx.utils.exec_file_stmt(path_startup_script)
	end

	return {
		magics = startup_magics,
		warmup_code = warmup_code,
		startup_stmt = startup_stmt,
	}
end

return M
