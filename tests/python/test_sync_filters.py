import io
import json
from pathlib import Path

import pytest


def _run_sync_filters(monkeypatch, *, names, types_list, max_repr, enable_logs, namespace):
	root = Path(__file__).resolve().parents[2]
	template_path = root / "python" / "sync_filters.py"
	template = template_path.read_text(encoding="utf-8")
	script = (
		template.replace("__NAMES_JSON__", json.dumps(names))
		.replace("__TYPES_JSON__", json.dumps(types_list))
		.replace("__MAX_REPR__", str(max_repr))
		.replace("__ENABLE_LOGS__", "True" if enable_logs else "False")
	)
	globals_ns = {"__builtins__": __builtins__}
	globals_ns.update(namespace)
	exec(compile(script, str(template_path), "exec"), globals_ns)
	return globals_ns


def test_sync_filters_invokes_bridge_functions(monkeypatch):
	calls = []

	def fake_sync(names, types, max_repr):
		calls.append(("sync", names, types, max_repr))

	def fake_logging(enabled):
		calls.append(("log", enabled))

	ns = {
		"_myipy_sync_var_filters": fake_sync,
		"_myipy_set_debug_logging": fake_logging,
	}

	_run_sync_filters(
		monkeypatch,
		names=["alpha", "beta"],
		types_list=["int", "str"],
		max_repr=120,
		enable_logs=True,
		namespace=ns,
	)

	assert calls[0] == ("sync", ["alpha", "beta"], ["int", "str"], 120)
	assert calls[1] == ("log", True)


def test_sync_filters_logs_sync_failure(monkeypatch):
	def failing_sync(*_args, **_kwargs):
		raise RuntimeError("boom")

	log_calls = []

	def fake_logging(enabled):
		log_calls.append(enabled)

	ns = {
		"_myipy_sync_var_filters": failing_sync,
		"_myipy_set_debug_logging": fake_logging,
	}

	buffer = io.StringIO()
	monkeypatch.setattr("sys.stderr", buffer)

	_run_sync_filters(
		monkeypatch,
		names=["name"],
		types_list=["type"],
		max_repr=64,
		enable_logs=False,
		namespace=ns,
	)

	assert "sync filters failed" in buffer.getvalue()
	assert log_calls == [False]


def test_sync_filters_missing_dependency_raises(monkeypatch):
	with pytest.raises(RuntimeError):
		_run_sync_filters(
			monkeypatch,
			names=[],
			types_list=[],
			max_repr=10,
			enable_logs=False,
			namespace={"_myipy_set_debug_logging": lambda *_: None},
		)
