"""High-value tests for the Plot Pane runtime and server."""

import sys
import types
from pathlib import Path

import pytest

PYTHON_ROOT = Path(__file__).resolve().parents[2] / "python"
if str(PYTHON_ROOT) not in sys.path:
	sys.path.insert(0, str(PYTHON_ROOT))

from plot_viewer import runtime as plot_server  # noqa: E402


def _make_entry(identifier: str, figure_number: int) -> plot_server.PlotEntry:
	return plot_server.PlotEntry(
		plot_id=identifier,
		figure_number=figure_number,
		label=f"Figure {figure_number}",
		title=f"Plot {figure_number}",
		reason="unit-test",
		backend=plot_server._PLOT_REQUIRED_BACKEND,
		created_at=figure_number + 0.5,
		width=640,
		height=480,
		dpi=100.0,
		png=b"\x89PNG\r\n\x1a\n",
	)


def _install_matplotlib_stubs(monkeypatch):
	backend_state = {"value": "qt5agg"}
	show_calls = []
	savefig_calls = []
	switch_calls = []

	matplotlib = types.ModuleType("matplotlib")
	matplotlib.__path__ = []  # mark as package

	def get_backend():
		return backend_state["value"]

	matplotlib.get_backend = get_backend

	pyplot = types.ModuleType("matplotlib.pyplot")

	def show(*args, **kwargs):
		show_calls.append((args, kwargs))
		return "show-called"

	def savefig(*args, **kwargs):
		savefig_calls.append((args, kwargs))
		return "savefig-called"

	def switch_backend(name):
		switch_calls.append(name)
		backend_state["value"] = name
		return name

	pyplot.show = show
	pyplot.savefig = savefig
	pyplot.switch_backend = switch_backend
	matplotlib.pyplot = pyplot

	helpers = types.ModuleType("matplotlib._pylab_helpers")

	class FakeGcf:
		@staticmethod
		def get_all_fig_managers():
			return []

	helpers.Gcf = FakeGcf

	backend_agg = types.ModuleType("matplotlib.backends.backend_agg")

	class FakeFigureCanvasAgg:
		def __init__(self, figure):
			self._figure = figure

		def draw(self):
			return None

		def print_png(self, buf):
			buf.write(b"fake-png")

		def get_width_height(self):
			return (640, 480)

	backend_agg.FigureCanvasAgg = FakeFigureCanvasAgg

	inline_pkg = types.ModuleType("matplotlib_inline")
	inline_pkg.__path__ = []  # mark as package

	backend_inline = types.ModuleType("matplotlib_inline.backend_inline")
	inline_display_calls = []

	def inline_display(*args, **kwargs):
		inline_display_calls.append((args, kwargs))
		return "inline-display"

	backend_inline.display = inline_display
	inline_pkg.backend_inline = backend_inline

	monkeypatch.setitem(sys.modules, "matplotlib", matplotlib)
	monkeypatch.setitem(sys.modules, "matplotlib.pyplot", pyplot)
	monkeypatch.setitem(sys.modules, "matplotlib._pylab_helpers", helpers)
	monkeypatch.setitem(sys.modules, "matplotlib.backends.backend_agg", backend_agg)
	monkeypatch.setitem(sys.modules, "matplotlib_inline", inline_pkg)
	monkeypatch.setitem(sys.modules, "matplotlib_inline.backend_inline", backend_inline)

	return {
		"backend_state": backend_state,
		"show_calls": show_calls,
		"savefig_calls": savefig_calls,
		"switch_calls": switch_calls,
		"pyplot": pyplot,
		"inline_module": backend_inline,
		"inline_display_calls": inline_display_calls,
	}


def test_plot_runtime_enable_installs_hooks_and_resets_backend(monkeypatch):
	stubs = _install_matplotlib_stubs(monkeypatch)
	capture_calls = []

	def fake_capture(self, reason):
		capture_calls.append(reason)

	monkeypatch.setattr(plot_server.PlotRuntime, "capture", fake_capture)

	def fake_start(self):
		if self._httpd:
			return

		class DummyHTTPD:
			server_address = ("127.0.0.1", 3333)

			def shutdown(self):
				return None

			def server_close(self):
				return None

		self._httpd = DummyHTTPD()
		self._port = DummyHTTPD.server_address[1]
		self._thread = None

	monkeypatch.setattr(plot_server.PlotServer, "start", fake_start, raising=False)

	runtime = plot_server.PlotRuntime()
	status = runtime.enable()

	assert status["status"] == "ready"
	assert status["backend"] == plot_server._PLOT_REQUIRED_BACKEND
	assert stubs["switch_calls"] == [plot_server._PLOT_REQUIRED_BACKEND]

	stubs["pyplot"].show(1, key="value")
	stubs["pyplot"].savefig("fig.png")

	assert capture_calls == ["pyplot.show", "pyplot.savefig"]
	assert stubs["show_calls"] == [((1,), {"key": "value"})]
	assert stubs["savefig_calls"] == [(("fig.png",), {})]

	runtime.disable()


def test_plot_runtime_disable_restores_hooks(monkeypatch):
	stubs = _install_matplotlib_stubs(monkeypatch)

	def fake_start(self):
		self._httpd = types.SimpleNamespace(server_address=("127.0.0.1", 0))
		self._port = self._httpd.server_address[1]
		self._thread = None

	monkeypatch.setattr(plot_server.PlotServer, "start", fake_start, raising=False)
	monkeypatch.setattr(plot_server.PlotServer, "shutdown", lambda self: None, raising=False)

	runtime = plot_server.PlotRuntime()
	original_show = stubs["pyplot"].show
	original_savefig = stubs["pyplot"].savefig
	original_switch = stubs["pyplot"].switch_backend

	runtime.enable()
	assert stubs["pyplot"].show is not original_show
	assert stubs["pyplot"].savefig is not original_savefig
	assert stubs["pyplot"].switch_backend is not original_switch

	runtime.disable()

	assert stubs["pyplot"].show is original_show
	assert stubs["pyplot"].savefig is original_savefig
	assert stubs["pyplot"].switch_backend is original_switch


def test_plot_runtime_disables_inline_autoshow(monkeypatch):
	stubs = _install_matplotlib_stubs(monkeypatch)

	def fake_start(self):
		self._httpd = types.SimpleNamespace(server_address=("127.0.0.1", 0))
		self._port = self._httpd.server_address[1]
		self._thread = None

	monkeypatch.setattr(plot_server.PlotServer, "start", fake_start, raising=False)
	monkeypatch.setattr(plot_server.PlotServer, "shutdown", lambda self: None, raising=False)

	runtime = plot_server.PlotRuntime()
	inline_module = stubs["inline_module"]
	original_inline_display = inline_module.display

	runtime.enable()
	assert inline_module.display is not original_inline_display

	inline_module.display(1, key="value")
	assert stubs["inline_display_calls"] == []

	runtime.disable()
	assert inline_module.display is original_inline_display

	inline_module.display("after", flag=True)
	assert stubs["inline_display_calls"] == [(("after",), {"flag": True})]


def test_plot_runtime_skips_capture_when_backend_differs(monkeypatch):
	stubs = _install_matplotlib_stubs(monkeypatch)

	def fake_start(self):
		self._httpd = types.SimpleNamespace(server_address=("127.0.0.1", 0))
		self._port = self._httpd.server_address[1]
		self._thread = None

	monkeypatch.setattr(plot_server.PlotServer, "start", fake_start, raising=False)
	monkeypatch.setattr(plot_server.PlotServer, "shutdown", lambda self: None, raising=False)

	added = []

	def fake_add_entry(self, entry):
		added.append(entry)

	monkeypatch.setattr(plot_server.PlotServer, "add_entry", fake_add_entry, raising=False)

	runtime = plot_server.PlotRuntime()
	runtime.enable()
	assert stubs["backend_state"]["value"] == plot_server._PLOT_REQUIRED_BACKEND

	stubs["pyplot"].switch_backend("qt5agg")
	assert stubs["backend_state"]["value"] == "qt5agg"

	runtime.capture("pyplot.show")
	assert added == []


def test_plot_server_event_flow_tracks_selection_and_limits(monkeypatch):
	server = plot_server.PlotServer(max_entries=2)
	published = []
	monkeypatch.setattr(server.events, "publish", lambda event, payload: published.append((event, payload)))

	entry1 = _make_entry("plot-1", 1)
	entry2 = _make_entry("plot-2", 2)
	entry3 = _make_entry("plot-3", 3)

	server.add_entry(entry1)
	server.add_entry(entry2)
	server.add_entry(entry3)

	assert [item[0] for item in published[:6]] == [
		"plot-added",
		"plot-selected",
		"plot-added",
		"plot-selected",
		"plot-added",
		"plot-selected",
	]
	assert published[6][0] == "plot-removed"
	assert published[6][1]["id"] == entry1.plot_id

	state = server.list_plots()
	assert [entry["id"] for entry in state["entries"]] == [entry2.plot_id, entry3.plot_id]
	assert state["selected"]["id"] == entry3.plot_id

	rotate_result = server.rotate_plot(-1)
	assert rotate_result["ok"] is True
	assert rotate_result["selected"]["id"] == entry2.plot_id

	remove_result = server.remove_plot(entry2.plot_id)
	assert remove_result["ok"] is True
	assert remove_result["removed"]["id"] == entry2.plot_id
	assert remove_result["selected"]["id"] == entry3.plot_id

	clear_result = server.clear_plots()
	assert clear_result["ok"] is True
	assert clear_result["removed"][0]["id"] == entry3.plot_id
	assert published[-1] == ("plot-selected", None)
	assert server.list_plots() == {"entries": [], "selected": None}


def test_runtime_delete_command_prefers_selection_and_reports_errors():
	runtime = plot_server.PlotRuntime()
	server = plot_server.PlotServer(max_entries=5)
	server.events.publish = lambda *_, **__: None
	runtime._server = server

	entry_a = _make_entry("plot-a", 10)
	entry_b = _make_entry("plot-b", 11)
	server.add_entry(entry_a)
	server.add_entry(entry_b)

	response = runtime.handle_command("delete", {})
	assert response["ok"] is True
	assert response["removed"]["id"] == entry_b.plot_id
	assert response["selected"]["id"] == entry_a.plot_id

	missing = runtime.handle_command("delete", {"id": "missing"})
	assert missing["ok"] is False
	assert missing["error"] == "not found"

	final = runtime.handle_command("delete", {})
	assert final["ok"] is True
	assert final["removed"]["id"] == entry_a.plot_id
	assert final["selected"] is None

	no_selection = runtime.handle_command("delete", {})
	assert no_selection["ok"] is False
	assert no_selection["error"] == "no selection"
