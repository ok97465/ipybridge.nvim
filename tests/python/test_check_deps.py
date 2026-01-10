"""Tests for the check_deps helper script."""

import importlib
import runpy
import sys
from pathlib import Path


def _run_check_deps(monkeypatch, argv, import_stub):
    """Run check_deps.py with patched argv and importlib behavior."""
    module_path = Path(__file__).resolve().parents[2] / "python" / "check_deps.py"
    monkeypatch.setattr(sys, "argv", argv)
    monkeypatch.setattr(importlib, "import_module", import_stub)
    runpy.run_path(str(module_path), run_name="__main__")


def test_check_deps_reports_missing_modules(monkeypatch, capsys):
    """Report only the modules that fail to import."""
    missing = {"missing_mod", "another_missing"}

    def fake_import(name):
        if name in missing:
            raise ImportError("boom")
        return object()

    _run_check_deps(
        monkeypatch,
        ["check_deps.py", "sys", "missing_mod", "another_missing"],
        fake_import,
    )
    captured = capsys.readouterr()
    assert captured.err == ""
    assert captured.out.strip().splitlines() == ["missing_mod", "another_missing"]


def test_check_deps_silent_when_all_modules_resolve(monkeypatch, capsys):
    """Emit no output when every module is importable."""

    def fake_import(_name):
        return object()

    _run_check_deps(monkeypatch, ["check_deps.py", "sys"], fake_import)
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""
