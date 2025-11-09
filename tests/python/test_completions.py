"""Tests covering the completion helpers embedded in bootstrap_helpers."""

import base64
import importlib
import sys
import types

import pytest


STUB_IPYBRIDGE_NS = """
def collect_namespace(globals_ns=None, locals_ns=None):
    result = {}
    if isinstance(globals_ns, dict):
        result.update(globals_ns)
    if isinstance(locals_ns, dict):
        result.update(locals_ns)
    return result


def get_var_filters():
    return {}


def list_variables(namespace=None, max_repr=None, hide_names=None, hide_types=None):
    return {}


def log_debug(message):
    # Logging is suppressed during tests.
    return None


def preview_data(name, namespace=None, max_rows=None, max_cols=None):
    payload = None
    if isinstance(namespace, dict):
        payload = namespace.get(name)
    return {"name": name, "value": payload}


def set_debug_logging(flag):
    return None


def set_var_filters(names=None, types=None, max_repr=None):
    return None


def resolve_path(name, namespace):
    value = None
    if isinstance(namespace, dict):
        value = namespace.get(name)
    return True, value, None
"""


@pytest.fixture
def helpers(monkeypatch):
    stub_bytes = STUB_IPYBRIDGE_NS.encode("utf-8")
    real_decode = base64.b64decode

    def fake_decode(data, *args, **kwargs):
        key = data.decode("utf-8") if isinstance(data, (bytes, bytearray)) else data
        if key == "__MODULE_B64__":
            return stub_bytes
        return real_decode(data, *args, **kwargs)

    monkeypatch.setattr(base64, "b64decode", fake_decode)
    sys.modules.pop("python.bootstrap_helpers", None)
    sys.modules.pop("ipybridge_ns", None)
    module = importlib.import_module("python.bootstrap_helpers")
    module.provisionalcompleter = None
    module.ProvisionalCompleterWarning = None
    return module


def _make_completion(text, start, end, origin):
    return types.SimpleNamespace(text=text, start=start, end=end, _origin=origin)


class DummyTrap:
    def __init__(self):
        self.entered = False
        self.exited = False

    def __enter__(self):
        self.entered = True
        return self

    def __exit__(self, exc_type, exc, tb):
        self.exited = True
        return False


class DummyCompleter:
    def __init__(self, entries):
        self.entries = entries
        self.calls = []

    def completions(self, code, cursor_pos):
        self.calls.append((code, cursor_pos))
        return list(self.entries)


class DummyShell:
    def __init__(self, entries):
        self.Completer = DummyCompleter(entries)
        self.builtin_trap = DummyTrap()
        self.frames = []
        self.legacy_calls = 0

    def set_completer_frame(self, frame=None):
        self.frames.append(frame)

    def complete(self, text, line, cursor):
        self.legacy_calls += 1
        return "", []


class DummyDebugger:
    def __init__(self, shell, names):
        self.shell = shell
        self.names = names
        self.curframe_locals = {"value": 1}
        self.curframe = types.SimpleNamespace(f_globals={"__name__": "__main__"})
        self.pdb_use_exclamation_mark = False
        self.calls = []

    def completenames(self, text, line, begidx, endidx):
        self.calls.append((text, line, begidx, endidx))
        return list(self.names)

    @staticmethod
    def parseline(line):
        if not line:
            return "", "", line
        parts = line.split(None, 1)
        if len(parts) == 1:
            return parts[0], "", line
        return parts[0], parts[1], line


def test_ipython_only_completion_uses_modern_api(monkeypatch, helpers):
    shell = DummyShell(
        [
            _make_completion("alpha", 0, 5, "python"),
            _make_completion("alpha_attr", 0, 5, "module"),
        ]
    )
    monkeypatch.setattr(helpers, "get_ipython", lambda: shell)

    result = helpers._mi_ipython_only_complete("alpha", 5)

    assert result["matches"] == ["alpha", "alpha_attr"]
    assert result["cursor_start"] == 0
    assert result["cursor_end"] == 5
    assert result["metadata"]["source_counts"] == {"python": 1, "module": 1}
    assert [item["source"] for item in result["items"]] == ["python", "module"]
    assert shell.Completer.calls == [("alpha", 5)]
    assert shell.legacy_calls == 0


def test_debug_completion_merges_pdb_and_ipython(monkeypatch, helpers):
    shell = DummyShell(
        [
            _make_completion("print", 0, 3, "python"),
            _make_completion("printf", 0, 3, "python"),
        ]
    )
    debugger = DummyDebugger(shell, ["print"])
    monkeypatch.setattr(helpers, "_mi_active_debugger", debugger, raising=False)
    monkeypatch.setattr(helpers, "get_ipython", lambda: shell)

    result = helpers._mi_debug_complete_payload("pri", 3, debug=True)

    assert result["matches"] == ["print", "printf"]
    assert result["cursor_start"] == 0
    assert result["cursor_end"] == 3
    assert result["metadata"]["source_counts"] == {"pdb": 1, "python": 1}
    assert [item["source"] for item in result["items"]] == ["pdb", "python"]
    assert shell.Completer.calls == [("pri", 3)]
    assert shell.legacy_calls == 0
    assert debugger.calls and debugger.calls[0][0] == "pri"
