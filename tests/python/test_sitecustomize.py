import builtins
import importlib.util
import sys
import uuid
from pathlib import Path


def _load_sitecustomize(monkeypatch):
	root = Path(__file__).resolve().parents[2]
	path = root / "python" / "sitecustomize.py"
	monkeypatch.delenv("IPYBRIDGE_CONSOLE_PATCH", raising=False)
	monkeypatch.delenv("IPYBRIDGE_CONSOLE_PATCH_SILENT", raising=False)
	name = f"sitecustomize_test_{uuid.uuid4().hex}"
	spec = importlib.util.spec_from_file_location(name, path)
	module = importlib.util.module_from_spec(spec)
	sys.modules[name] = module
	spec.loader.exec_module(module)
	return module


def test_log_respects_patch_flags(monkeypatch, capsys):
	mod = _load_sitecustomize(monkeypatch)

	mod._PATCH_FLAG = "1"
	mod._PATCH_SILENT = False
	mod._log("hello")
	assert "hello" in capsys.readouterr().err

	mod._PATCH_SILENT = True
	mod._log("hidden")
	captured = capsys.readouterr()
	assert captured.err == ""


def test_readline_guard_blocks_completion_rebinding(monkeypatch):
	mod = _load_sitecustomize(monkeypatch)

	class FakeReadline:
		def __init__(self):
			self.commands = []
			self.completer_calls = []

		def parse_and_bind(self, command):
			self.commands.append(command)

		def set_completer(self, func):
			self.completer_calls.append(func)

	readline = FakeReadline()
	guard = mod._ReadlineTabGuard(readline)
	guard.install()

	readline.parse_and_bind("bind ^I complete")
	assert not any(cmd == "bind ^I complete" for cmd in readline.commands)
	assert any("self-insert" in cmd for cmd in readline.commands)

	readline.set_completer(object())
	assert readline.completer_calls == [None]

	handler = object()
	readline._ipybridge_enable_completion(handler)
	assert readline.completer_calls[-1] is handler

	readline._ipybridge_block_completion()
	assert readline.completer_calls[-1] is None


def test_install_input_patch_prefers_prompt_session(monkeypatch):
	mod = _load_sitecustomize(monkeypatch)
	mod._PATCH_FLAG = "1"
	mod._PATCH_SILENT = False
	monkeypatch.setattr(mod, "_log", lambda *_args, **_kwargs: None)

	class FakeSession:
		def __init__(self):
			self.prompts = []

		def prompt(self, text):
			self.prompts.append(text)
			return "session-value"

	session = FakeSession()
	monkeypatch.setattr(mod, "_create_prompt_session", lambda: session)

	orig_calls = []

	def original_input(prompt):
		orig_calls.append(prompt)
		return "original"

	monkeypatch.setattr(builtins, "input", original_input)
	mod._install_input_patch(original_input)

	assert builtins.input("prompt?") == "session-value"
	assert session.prompts == ["prompt?"]
	assert orig_calls == []


def test_install_input_patch_falls_back_on_failure(monkeypatch):
	mod = _load_sitecustomize(monkeypatch)
	mod._PATCH_FLAG = "1"
	mod._PATCH_SILENT = False
	logs = []
	monkeypatch.setattr(mod, "_log", lambda message: logs.append(message))

	class FailingSession:
		def prompt(self, _text):
			raise ValueError("nope")

	session = FailingSession()
	monkeypatch.setattr(mod, "_create_prompt_session", lambda: session)

	fallback_calls = []

	def original_input(prompt):
		fallback_calls.append(prompt)
		return "fallback"

	monkeypatch.setattr(builtins, "input", original_input)
	mod._install_input_patch(original_input)

	assert builtins.input("prompt!") == "fallback"
	assert fallback_calls == ["prompt!"]
	assert any("prompt session failed" in entry for entry in logs)
