import base64
import os
import sys
import types
from pathlib import Path

import pytest


def _load_bootstrap_helpers(monkeypatch):
	root = Path(__file__).resolve().parents[2]
	template_path = root / "python" / "bootstrap_helpers.py"
	ns_path = root / "python" / "ipybridge_ns.py"

	template = template_path.read_text(encoding="utf-8")
	module_b64 = base64.b64encode(ns_path.read_bytes()).decode("ascii")
	source = template.replace("__MODULE_B64__", module_b64)

	ipy_mod = types.ModuleType("IPython")
	ipy_mod.get_ipython = lambda: None
	monkeypatch.setitem(sys.modules, "IPython", ipy_mod)

	module = types.ModuleType("bootstrap_helpers_runtime")
	exec(compile(source, str(template_path), "exec"), module.__dict__)
	return module


def test_normalize_breakpoints(monkeypatch, tmp_path):
	mod = _load_bootstrap_helpers(monkeypatch)
	path_a = tmp_path / "script_a.py"
	path_b = tmp_path / "script_b.py"

	raw_payload = {
		str(path_a): [
			{"line": "10", "condition": "  x > 1 "},
			{"line": "12"},
			{"line": -3},
			{"line": "12", "condition": ""},
			"not-a-line",
		],
		str(path_b): {
			"a": {"line": "5", "condition": "y"},
			"b": {"line": 7},
		},
		123: [1],
	}

	normalized = mod._myipy_normalize_breakpoints(raw_payload)

	assert normalized[str(path_a.resolve())] == [
		{"line": 10, "condition": "x > 1"},
		{"line": 12},
	]
	assert normalized[str(path_b.resolve())] == [
		{"line": 5, "condition": "y"},
		{"line": 7},
	]


def test_read_breakpoint_payload_tracks_signature(monkeypatch, tmp_path):
	mod = _load_bootstrap_helpers(monkeypatch)
	logs = []
	monkeypatch.setattr(mod, "_ipy_log_debug", lambda msg: logs.append(msg))
	mod._BREAKPOINT_STATE["signature"] = None
	mod._BREAKPOINT_STATE["data"] = {}
	file_path = tmp_path / "breakpoints.json"
	file_path.write_text('{"sample.py": [1, {"line": "2", "condition": "cond"}]}', encoding="utf-8")

	data, changed = mod._myipy_read_breakpoint_payload(str(file_path))
	assert changed is True
	assert data[str(Path("sample.py").resolve())] == [
		{"line": 1},
		{"line": 2, "condition": "cond"},
	]
	assert mod._BREAKPOINT_STATE["data"] == data
	assert mod._BREAKPOINT_STATE["signature"] is not None
	assert getattr(mod, "__ipybridge_breakpoints__") == data

	data2, changed2 = mod._myipy_read_breakpoint_payload(str(file_path))
	assert changed2 is False
	assert data2 == data
	assert logs == []


def test_read_breakpoint_payload_handles_decode_error(monkeypatch, tmp_path):
	mod = _load_bootstrap_helpers(monkeypatch)
	logs = []
	monkeypatch.setattr(mod, "_ipy_log_debug", lambda msg: logs.append(msg))
	mod._BREAKPOINT_STATE["signature"] = "previous"
	mod._BREAKPOINT_STATE["data"] = {"cached": [{"line": 3}]}
	file_path = tmp_path / "invalid.json"
	file_path.write_text("{not valid json", encoding="utf-8")

	data, changed = mod._myipy_read_breakpoint_payload(str(file_path))
	assert changed is False
	assert data == {"cached": [{"line": 3}]}
	assert logs and "decode failed" in logs[-1]


def test_apply_breakpoints_invokes_debugger(monkeypatch):
	mod = _load_bootstrap_helpers(monkeypatch)
	monkeypatch.setattr(mod, "_ipy_log_debug", lambda msg: None)

	class FakeDebugger:
		def __init__(self):
			self.cleared = 0
			self.calls = []

		def clear_all_breaks(self):
			self.cleared += 1

		def set_break(self, path, line, cond=None):
			self.calls.append((path, line, cond))

	dbg = FakeDebugger()
	payload = {
		"/tmp/test.py": [
			{"line": "4", "condition": "x > 0"},
			{"line": "4", "condition": ""},
			5,
			{"line": "6", "condition": "  y  "},
			"bad",
		]
	}

	result = mod._myipy_apply_breakpoints(payload=payload, dbg=dbg)

	assert result is True
	assert dbg.cleared == 1
	assert dbg.calls == [
		("/tmp/test.py", 4, None),
		("/tmp/test.py", 5, None),
		("/tmp/test.py", 6, "y"),
	]


def test_apply_breakpoints_handles_errors(monkeypatch):
	mod = _load_bootstrap_helpers(monkeypatch)
	records = []
	monkeypatch.setattr(mod, "_ipy_log_debug", lambda msg: records.append(msg))

	class FlakyDebugger:
		def clear_all_breaks(self):
			raise RuntimeError("boom")

		def set_break(self, *_args, **_kwargs):
			raise RuntimeError("fail")

	result = mod._myipy_apply_breakpoints(
		payload={"/tmp/test.py": [1]}, dbg=FlakyDebugger()
	)

	assert result is False
	assert any("clear failed" in msg or "set failed" in msg for msg in records)


def test_register_breakpoints_file_sets_environment(monkeypatch, tmp_path):
	mod = _load_bootstrap_helpers(monkeypatch)
	called_paths = []
	watcher_started = []
	monkeypatch.setattr(
		mod,
		"_myipy_start_breakpoint_watcher",
		lambda: watcher_started.append(True),
	)
	def _fake_read(path):
		called_paths.append(path)
		return {}, False

	monkeypatch.setattr(mod, "_myipy_read_breakpoint_payload", _fake_read)
	monkeypatch.setenv(mod._BREAKPOINT_FILE_ENV, "placeholder")
	mod._BREAKPOINT_STATE["path"] = None

	target = tmp_path / "bps.json"
	target.write_text("{}", encoding="utf-8")
	result = mod._myipy_register_breakpoints_file(str(target))

	assert result is True
	assert called_paths == [str(target.resolve())]
	assert watcher_started == [True]
	assert mod._BREAKPOINT_STATE["path"] == str(target.resolve())
	assert os.environ[mod._BREAKPOINT_FILE_ENV] == str(target.resolve())


def test_prepare_breakpoints_for_debug_uses_capture(monkeypatch):
	mod = _load_bootstrap_helpers(monkeypatch)
	captured = {"value": 1}
	applied = []
	monkeypatch.setattr(mod, "_myipy_capture_breakpoints", lambda: captured)
	monkeypatch.setattr(
		mod,
		"_myipy_apply_breakpoints",
		lambda payload, dbg=None: applied.append((payload, dbg)),
	)

	class Debugger:
		pass

	debugger = Debugger()
	result = mod._myipy_prepare_breakpoints_for_debug(debugger)

	assert result is captured
	assert applied == [(captured, debugger)]
	assert mod.__dict__["_mi_active_debugger"] is debugger


@pytest.mark.parametrize(
	"value, default, expected",
	[
		("5", 1, 5),
		(None, 3, 3),
		("bad", 2, 2),
	],
)
def test_coerce_int(value, default, expected, monkeypatch):
	mod = _load_bootstrap_helpers(monkeypatch)
	assert mod._coerce_int(value, default) == expected


def test_debug_preview_context_capture_and_compute(monkeypatch):
	mod = _load_bootstrap_helpers(monkeypatch)
	logs = []
	monkeypatch.setattr(mod, "_ipy_log_debug", lambda msg: logs.append(msg))
	context = mod._DebugPreviewContext()

	namespace = {"a": 1}
	context.capture(None, namespace, rows="10", cols="5")
	assert context.namespace is namespace
	assert context.rows == 10
	assert context.cols == 5
	assert context.scoped is False

	frame = object()
	context.capture(frame, {"b": 2}, rows="-1", cols=0)
	assert context.frame is frame
	assert context.frame_id == id(frame)
	assert context.scoped is True
	assert context.rows == mod._PREVIEW_LIMITS["rows"]
	assert context.cols == mod._PREVIEW_LIMITS["cols"]

	monkeypatch.setattr(mod, "_myipy_current_namespace", lambda frame=None: {"x": 1})
	calls = []

	def _preview(name, **kwargs):
		calls.append((name, kwargs))
		return {"name": name, "rows": kwargs["max_rows"], "row_offset": kwargs["row_offset"]}

	monkeypatch.setattr(mod, "_ipy_preview_data", _preview)

	result = context.compute("target", rows=15, cols=None, row_offset=-5, col_offset=2)
	assert result["rows"] == 15
	assert result["row_offset"] == 0
	assert calls and calls[0][0] == "target"
	assert any("debug context stored" in msg for msg in logs)
