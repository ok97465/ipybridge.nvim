"""Regression tests for the exec_magics helpers injected into kernels."""

import base64
import bdb
import sys
import types
from pathlib import Path


def _load_exec_magics(monkeypatch):
    registered = {}

    def register_line_magic(name):
        def decorator(func):
            registered[name] = func
            return func

        return decorator

    magic_mod = types.ModuleType("IPython.core.magic")
    magic_mod.register_line_magic = register_line_magic

    core_mod = types.ModuleType("IPython.core")
    core_mod.magic = magic_mod

    debugger_mod = types.ModuleType("IPython.core.debugger")

    class _SimplePdb(bdb.Bdb):
        def do_clear(self, _arg):
            pass

        def setup(self, frame, tb):
            return (frame, tb)

        def postcmd(self, stop, line):
            return stop

    debugger_mod.Pdb = _SimplePdb

    ipy_mod = types.ModuleType("IPython")
    ipy_mod.core = types.SimpleNamespace(  # type: ignore[attr-defined]
        magic=magic_mod, debugger=debugger_mod
    )
    ipy_mod.get_ipython = lambda: None

    monkeypatch.setitem(sys.modules, "IPython", ipy_mod)
    monkeypatch.setitem(sys.modules, "IPython.core", core_mod)
    monkeypatch.setitem(sys.modules, "IPython.core.magic", magic_mod)
    monkeypatch.setitem(sys.modules, "IPython.core.debugger", debugger_mod)

    template_path = Path(__file__).resolve().parents[2] / "python" / "exec_magics.py"
    ns_path = Path(__file__).resolve().parents[2] / "python" / "ipybridge_ns.py"
    template = template_path.read_text(encoding="utf-8")
    module_b64 = base64.b64encode(ns_path.read_bytes()).decode("ascii")
    script = template.replace("__MODULE_B64__", module_b64)

    module = types.ModuleType("exec_magics_runtime")
    exec(compile(script, str(template_path), "exec"), module.__dict__)
    return module, registered


def _prepare_debugfile_runtime(monkeypatch, module, user_ns):
    monkeypatch.setattr(module, "_mi_start_qt_pump", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_matplotlib", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_gui", lambda *a, **k: None)
    module.__dict__["_mi_acquire_user_namespace"] = lambda: user_ns

    captured = {}

    class FakeDebugger(bdb.Bdb):
        def __init__(self):
            super().__init__()
            self.shell = types.SimpleNamespace(
                colors="linux", hooks=types.SimpleNamespace(synchronize_with_editor=None)
            )
            self.prompt = ""
            self.quitting = False

        def clear_all_breaks(self):
            pass

        def set_break(self, *_args, **_kwargs):
            pass

        def reset(self):
            pass

        def runctx(self, code, glbs, locs):
            exec(code, glbs, locs)
            captured["globals"] = dict(glbs)

        def set_trace(self, *_args, **_kwargs):
            pass

    monkeypatch.setattr(
        module._MiQtAwarePdb,
        "get",
        classmethod(lambda cls: FakeDebugger),
    )
    return captured


def test_runcell_executes_cells(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)
    file_path = tmp_path / "sample.py"
    file_path.write_text(
        "# %%\nvalue = 21\n# %% next\nvalue = value * 2\n", encoding="utf-8"
    )

    module.runcell(0, str(file_path))
    assert module.__dict__["value"] == 21

    module.runcell(1, str(file_path))
    assert module.__dict__["value"] == 42


def test_runcell_handles_out_of_range(monkeypatch, tmp_path, capsys):
    module, _ = _load_exec_magics(monkeypatch)
    file_path = tmp_path / "cells.py"
    file_path.write_text("# %%\npass\n", encoding="utf-8")

    module.runcell(5, str(file_path))
    captured = capsys.readouterr()
    assert "out of range" in captured.out


def test_runcell_magic_registered(monkeypatch):
    _, registered = _load_exec_magics(monkeypatch)
    assert "runcell" in registered


def test_debugcell_magic_registered(monkeypatch):
    _, registered = _load_exec_magics(monkeypatch)
    assert "debugcell" in registered


def test_conditional_breakpoint_ignores_eval_errors(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)
    pdb_cls = module._MiQtAwarePdb.get()
    assert pdb_cls is not None

    debugger = pdb_cls()
    source_path = tmp_path / "bp_sample.py"
    source_path.write_text("print(1)\n", encoding="utf-8")
    canonical = debugger.canonic(str(source_path.resolve()))

    debugger.set_break(canonical, 1, cond='foo == "foo"')

    dummy_code = types.SimpleNamespace(
        co_filename=canonical, co_firstlineno=1, co_name="dummy"
    )
    missing_frame = types.SimpleNamespace(
        f_code=dummy_code, f_lineno=1, f_globals={}, f_locals={}
    )
    assert debugger.break_here(missing_frame) is False

    populated_frame = types.SimpleNamespace(
        f_code=dummy_code,
        f_lineno=1,
        f_globals={},
        f_locals={"foo": "foo"},
    )
    assert debugger.break_here(populated_frame) is True


def test_debugfile_uses_isolated_namespace(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)

    monkeypatch.setattr(module, "_mi_start_qt_pump", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_matplotlib", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_gui", lambda *a, **k: None)

    user_ns = {"persist": "value"}

    class DummyShell:
        def __init__(self):
            self.user_ns = user_ns

    monkeypatch.setattr(sys.modules["IPython"], "get_ipython", lambda: DummyShell())

    class FakeDebugger:
        def __init__(self):
            hooks = types.SimpleNamespace(synchronize_with_editor=None)
            self.shell = types.SimpleNamespace(colors="linux", hooks=hooks)
            self.prompt = ""
            self.quitting = False

        def clear_all_breaks(self):
            pass

        def set_break(self, *_args, **_kwargs):
            pass

        def reset(self):
            pass

        def runctx(self, code, glbs, locs):
            exec(code, glbs, locs)

        def set_trace(self, *_args, **_kwargs):
            pass

    monkeypatch.setattr(
        module._MiQtAwarePdb,
        "get",
        classmethod(lambda cls: FakeDebugger),
    )

    script_path = tmp_path / "script.py"
    script_path.write_text(
        "try:\n"
        "    foo\n"
        "except NameError:\n"
        "    foo_exists_before = False\n"
        "else:\n"
        "    foo_exists_before = True\n"
        "foo = 'foo'\n",
        encoding="utf-8",
    )

    module.debugfile(str(script_path))

    assert user_ns["foo"] == "foo"
    assert user_ns["foo_exists_before"] is False
    assert user_ns["persist"] == "value"

    user_ns["foo"] = "leftover"

    module.debugfile(str(script_path))

    assert user_ns["foo"] == "foo"
    assert user_ns["foo_exists_before"] is False


def test_debugfile_auto_imports_applied(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)
    user_ns = {}
    captured = _prepare_debugfile_runtime(monkeypatch, module, user_ns)
    module.__dict__["_myipy_get_debugfile_imports"] = lambda: "import math"

    script_path = tmp_path / "auto_import.py"
    script_path.write_text("result = math.sqrt(49)\n", encoding="utf-8")

    module.debugfile(str(script_path))

    assert captured["globals"]["result"] == 7.0


def test_debugfile_auto_import_error_prints(monkeypatch, tmp_path, capsys):
    module, _ = _load_exec_magics(monkeypatch)
    user_ns = {}
    captured = _prepare_debugfile_runtime(monkeypatch, module, user_ns)
    module.__dict__["_myipy_get_debugfile_imports"] = lambda: "import definitely_missing_module_123"

    script_path = tmp_path / "auto_import_error.py"
    script_path.write_text("value = 1\n", encoding="utf-8")

    module.debugfile(str(script_path))
    output = capsys.readouterr()

    assert "debugfile auto import failed" in output.out
    assert captured["globals"]["value"] == 1


def test_pdb_autocapture_hooks(monkeypatch):
    module, _ = _load_exec_magics(monkeypatch)
    calls = []
    module.__dict__["_myipy_plot_autocapture"] = lambda reason=None: calls.append(reason)
    pdb_cls = module._MiQtAwarePdb.get()
    assert pdb_cls is not None
    debugger = pdb_cls()
    debugger.shell = types.SimpleNamespace(
        colors="linux", hooks=types.SimpleNamespace(synchronize_with_editor=None)
    )
    frame = types.SimpleNamespace(
        f_code=types.SimpleNamespace(co_filename="sample.py", co_firstlineno=1, co_name="main"),
        f_lineno=1,
    )

    debugger.setup(frame, None)
    debugger.postcmd(False, "next")

    assert "debug.break" in calls
    assert "debug.postcmd" in calls


def test_debug_execute_source_autocapture_on_exit(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)
    user_ns = {}
    _prepare_debugfile_runtime(monkeypatch, module, user_ns)
    calls = []
    module.__dict__["_myipy_plot_autocapture"] = lambda reason=None: calls.append(reason)

    script_path = tmp_path / "autocapture_exit.py"
    script_path.write_text("value = 1\n", encoding="utf-8")

    module.debugfile(str(script_path))
    assert "debug.exit" in calls


def test_debugcell_shares_namespace_and_breakpoints(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)

    monkeypatch.setattr(module, "_mi_start_qt_pump", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_matplotlib", lambda *a, **k: None)
    monkeypatch.setattr(module, "_mi_enable_gui", lambda *a, **k: None)

    script_path = tmp_path / "cells.py"
    script_path.write_text(
        "# %%\n" "counter = 1\n" "# %%\n" "counter = counter + 1\n",
        encoding="utf-8",
    )

    module.__dict__["__ipybridge_breakpoints__"] = {str(script_path): [4]}

    class DummyShell:
        def __init__(self):
            self.user_ns = module.__dict__

    monkeypatch.setattr(sys.modules["IPython"], "get_ipython", lambda: DummyShell())

    debuggers = []

    class RecorderDebugger(bdb.Bdb):
        def __init__(self):
            super().__init__()
            self.shell = types.SimpleNamespace(
                colors="linux", hooks=types.SimpleNamespace(synchronize_with_editor=None)
            )
            self.prompt = ""
            self.seen_breaks = []
            debuggers.append(self)

        def clear_all_breaks(self):
            self.seen_breaks.clear()

        def set_break(self, filename, lineno, cond=None):
            self.seen_breaks.append((filename, lineno, cond))

        def reset(self):
            pass

        def runctx(self, code, glbs, locs):
            exec(code, glbs, locs)

        def set_trace(self, *_args, **_kwargs):
            pass

    monkeypatch.setattr(
        module._MiQtAwarePdb,
        "get",
        classmethod(lambda cls: RecorderDebugger),
    )

    module.runcell(0, str(script_path))
    assert module.__dict__["counter"] == 1

    module.debugcell(1, str(script_path))
    assert module.__dict__["counter"] == 2

    module.runcell(1, str(script_path))
    assert module.__dict__["counter"] == 3

    assert debuggers, "debugger should be instantiated"
    latest = debuggers[-1]
    assert any(line == 4 for _, line, _ in latest.seen_breaks)


def test_ipdb_handles_matplotlib_magic(monkeypatch):
    module, _ = _load_exec_magics(monkeypatch)
    pdb_cls = module._MiQtAwarePdb.get()
    assert pdb_cls is not None

    class DummyShell:
        def __init__(self):
            self.calls = []

        def run_line_magic(self, name, arg):
            self.calls.append((name, arg))

    debugger = pdb_cls()
    shell = DummyShell()
    debugger.shell = shell

    debugger.default("   %matplotlib   inline  ")

    assert shell.calls == [("matplotlib", "inline")]


def test_qt_loop_only_starts_for_qt_backend(monkeypatch):
    module, _ = _load_exec_magics(monkeypatch)
    module._mi_qt_loop_running = False
    monkeypatch.setattr(module, "_mi_patch_kernel_input", lambda: None)

    calls = []

    def fake_gui(*_args, **_kwargs):
        calls.append("gui")
        return True

    def fake_pump(interval=0.03):
        calls.append(("pump", interval))

    monkeypatch.setattr(module, "_mi_enable_gui", fake_gui)
    monkeypatch.setattr(module, "_mi_start_qt_pump", fake_pump)

    monkeypatch.setattr(module, "_mi_matplotlib_backend_hint", lambda: None)
    with module._mi_qt_events():
        pass
    assert calls == []

    module._mi_qt_loop_running = False
    monkeypatch.setattr(module, "_mi_matplotlib_backend_hint", lambda: "qt5agg")
    with module._mi_qt_events():
        pass
    assert calls == ["gui", ("pump", 0.03)]

    module._mi_qt_loop_running = False


def test_qt_loop_starts_after_matplotlib_magic(monkeypatch):
    module, _ = _load_exec_magics(monkeypatch)
    pdb_cls = module._MiQtAwarePdb.get()
    assert pdb_cls is not None

    backend_state = {"value": None}
    module._mi_qt_loop_running = False
    pump_calls = []

    monkeypatch.setattr(module, "_mi_matplotlib_backend_hint", lambda: backend_state["value"])
    monkeypatch.setattr(module, "_mi_start_qt_pump", lambda interval=0.03: pump_calls.append(interval))
    monkeypatch.setattr(module, "_mi_enable_gui", lambda *a, **k: True)

    class DummyShell:
        def __init__(self):
            self.calls = []

        def run_line_magic(self, name, arg):
            self.calls.append((name, arg))
            backend_state["value"] = "qt5agg" if arg.strip().startswith("qt") else None

    debugger = pdb_cls()
    debugger.shell = DummyShell()

    debugger.default("%matplotlib inline")
    assert pump_calls == []

    debugger.default("%matplotlib qt")
    assert pump_calls == [0.03]
    assert debugger.shell.calls == [("matplotlib", "inline"), ("matplotlib", "qt")]

    module._mi_qt_loop_running = False


def test_emit_vars_snapshot_syncs_namespace(monkeypatch):
    module, _ = _load_exec_magics(monkeypatch)

    calls = []

    class StubNamespace:
        def sync_from_frame(self, frame):
            calls.append(frame)

    frame_marker = object()

    dummy_helper_called = []

    monkeypatch.setitem(module.__dict__, "_mi_active_debug_namespace", StubNamespace())
    monkeypatch.setitem(module.__dict__, "_myipy_emit_debug_vars", lambda frame=None: dummy_helper_called.append(frame))

    module._mi_emit_vars_snapshot(frame_marker)

    assert calls == [frame_marker]
    assert dummy_helper_called == [frame_marker]
