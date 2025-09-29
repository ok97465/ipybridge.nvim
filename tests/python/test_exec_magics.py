import base64
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

    magic_mod = types.ModuleType('IPython.core.magic')
    magic_mod.register_line_magic = register_line_magic

    core_mod = types.ModuleType('IPython.core')
    core_mod.magic = magic_mod

    ipy_mod = types.ModuleType('IPython')
    ipy_mod.core = types.SimpleNamespace(magic=magic_mod)  # type: ignore[attr-defined]
    ipy_mod.get_ipython = lambda: None

    monkeypatch.setitem(sys.modules, 'IPython', ipy_mod)
    monkeypatch.setitem(sys.modules, 'IPython.core', core_mod)
    monkeypatch.setitem(sys.modules, 'IPython.core.magic', magic_mod)

    template_path = Path(__file__).resolve().parents[2] / 'python' / 'exec_magics.py'
    ns_path = Path(__file__).resolve().parents[2] / 'python' / 'ipybridge_ns.py'
    template = template_path.read_text(encoding='utf-8')
    module_b64 = base64.b64encode(ns_path.read_bytes()).decode('ascii')
    script = template.replace('__MODULE_B64__', module_b64)

    module = types.ModuleType('exec_magics_runtime')
    exec(compile(script, str(template_path), 'exec'), module.__dict__)
    return module, registered


def test_runcell_executes_cells(monkeypatch, tmp_path):
    module, _ = _load_exec_magics(monkeypatch)
    file_path = tmp_path / 'sample.py'
    file_path.write_text("# %%\nvalue = 21\n# %% next\nvalue = value * 2\n", encoding='utf-8')

    module.runcell(0, str(file_path))
    assert module.__dict__['value'] == 21

    module.runcell(1, str(file_path))
    assert module.__dict__['value'] == 42


def test_runcell_handles_out_of_range(monkeypatch, tmp_path, capsys):
    module, _ = _load_exec_magics(monkeypatch)
    file_path = tmp_path / 'cells.py'
    file_path.write_text("# %%\npass\n", encoding='utf-8')

    module.runcell(5, str(file_path))
    captured = capsys.readouterr()
    assert 'out of range' in captured.out


def test_runcell_magic_registered(monkeypatch):
    _, registered = _load_exec_magics(monkeypatch)
    assert 'runcell' in registered
