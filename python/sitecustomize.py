"""Runtime patches that make jupyter-console/ipdb cooperate with Neovim.

When the bridge launches a console this module suppresses readline TAB
completion, proxies prompt_toolkit input, wires ipdb history to a shared file
so up/down arrows survive sessions, and surfaces diagnostic logging so editor
completion engines stay responsive even inside ipdb.
"""

from __future__ import annotations

import atexit
import builtins
import codeop
from contextlib import contextmanager
import os
import re
import sys
import traceback


_PATCH_FLAG = os.environ.get("IPYBRIDGE_CONSOLE_PATCH", "1") != "0"
_PATCH_SILENT = os.environ.get("IPYBRIDGE_CONSOLE_PATCH_SILENT", "1") == "1"
_SUPPRESS_READLINE_TAB = os.environ.get("IPYBRIDGE_SUPPRESS_READLINE_TAB", "1") == "1"
_HISTORY_FILE_ENV = "IPYBRIDGE_IPDB_HISTORY_FILE"
_ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_IPYBRIDGE_MULTILINE_MODE = False
_IPYBRIDGE_INDENT_STEP = 4
_IPYBRIDGE_DEDENT_TOKENS = {
    "elif",
    "else",
    "except",
    "except*",
    "finally",
    "case",
}
try:  # Optional prompt_toolkit formatted text helper.
    from prompt_toolkit.formatted_text import ANSI as _PT_ANSI  # type: ignore
except Exception:
    _PT_ANSI = None
try:  # Optional jupyter_console async helper.
    from jupyter_console.utils import run_sync as _JC_RUN_SYNC  # type: ignore
except Exception:
    _JC_RUN_SYNC = None


def _log(message: str) -> None:
    """Emit a short diagnostic to stderr when console patching is requested."""
    if not _PATCH_FLAG or _PATCH_SILENT:
        return
    try:
        sys.stderr.write(f"[ipybridge.console] {message}\n")
        sys.stderr.flush()
    except Exception:
        pass


def _resolve_history_path(path: str | None) -> str | None:
    if not path:
        return None
    try:
        expanded = os.path.expanduser(path)
    except Exception:
        expanded = path
    try:
        parent = os.path.dirname(expanded)
        if parent:
            os.makedirs(parent, exist_ok=True)
    except Exception as exc:
        _log(f"history path unavailable: {exc}")
        return None
    return expanded


def _strip_ansi(text: str) -> str:
    if not text:
        return ""
    return _ANSI_ESCAPE_RE.sub("", text)


def _is_debug_prompt(prompt_text: str) -> bool:
    stripped = _strip_ansi(prompt_text).strip()
    if not stripped:
        return False
    return stripped.startswith(("ipdb>", "(Pdb)", "pdb>", "..."))


def _set_multiline_mode(enabled: bool) -> None:
    global _IPYBRIDGE_MULTILINE_MODE
    _IPYBRIDGE_MULTILINE_MODE = bool(enabled)


@contextmanager
def _multiline_prompt_state(enabled: bool):
    _set_multiline_mode(enabled)
    try:
        yield
    finally:
        _set_multiline_mode(False)


def _is_complete_input(source: str) -> bool:
    if not source or not source.strip():
        return True
    try:
        return codeop.compile_command(source, "<stdin>", "exec") is not None
    except (SyntaxError, OverflowError, ValueError):
        return True


def _line_indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def _strip_comment(line: str) -> str:
    if "#" not in line:
        return line
    return line.split("#", 1)[0]


def _first_token(text: str) -> str:
    stripped = text.lstrip()
    if not stripped:
        return ""
    token = stripped.split(None, 1)[0]
    if token.endswith(":"):
        token = token[:-1]
    return token


def _next_prompt_indent(source: str) -> str:
    lines = source.splitlines()
    if not lines:
        return ""
    last = lines[-1]
    if not last.strip():
        return ""
    indent = _line_indent(last)
    stripped = _strip_comment(last).rstrip()
    token = _first_token(stripped)
    if token in _IPYBRIDGE_DEDENT_TOKENS:
        indent = max(indent - _IPYBRIDGE_INDENT_STEP, 0)
    if stripped.endswith(":"):
        indent += _IPYBRIDGE_INDENT_STEP
    return " " * indent


def _debug_prompt_continuation(width, line_number, wrap_count):  # noqa: ARG001
    return "... "


class _ReadlineTabGuard:
    """Force TAB to self-insert so Neovim can surface nvim-cmp during ipdb."""

    def __init__(self, module) -> None:
        self._module = module
        self._original_parse_and_bind = getattr(module, "parse_and_bind", None)
        self._original_set_completer = getattr(module, "set_completer", None)
        self._completion_allowed = False

    def install(self) -> None:
        parse_ok = self._install_parse_guard()
        completer_ok = self._install_completer_guard()
        if not parse_ok and not completer_ok:
            _log("readline hooks unavailable; TAB suppression skipped")

    def _apply_tab_self_insert(self) -> None:
        """Bind TAB to literal insertion across GNU readline and libedit."""
        for binding in ("tab: self-insert", "bind ^I self-insert"):
            try:
                self._original_parse_and_bind(binding)
                return
            except Exception:
                continue

    def _install_parse_guard(self) -> bool:
        """Keep third-party code from rebinding TAB to the readline completer."""
        original = self._original_parse_and_bind
        if not callable(original):
            _log("readline parse_and_bind unavailable; TAB suppression skipped")
            return False

        def _guarded_parse_and_bind(command) -> None:
            if command is None:
                original(command)
                return
            try:
                text = (
                    command.decode(errors="ignore")
                    if isinstance(command, bytes)
                    else str(command)
                )
            except Exception:
                original(command)
                return
            lowered = text.strip().lower()
            if (
                ": complete" in lowered
                or " rl_complete" in lowered
                or lowered.startswith("bind ^i")
                or lowered.startswith("bind \\t")
            ):
                self._apply_tab_self_insert()
                return
            original(command)

        self._module.parse_and_bind = _guarded_parse_and_bind  # type: ignore[assignment]
        try:
            original("set editing-mode emacs")
            self._apply_tab_self_insert()
        except Exception as exc:
            _log(f"readline baseline bindings failed: {exc}")
        else:
            _log("readline editing enabled with TAB suppression")
        return True

    def _install_completer_guard(self) -> bool:
        """Allow ipybridge to opt-in to readline completion while keeping ipdb quiet."""
        original = self._original_set_completer
        if not callable(original):
            _log("readline set_completer unavailable; TAB suppression incomplete")
            return False

        def _guarded_set_completer(func):
            if self._completion_allowed:
                if func is None:
                    self._completion_allowed = False
                return original(func)
            return original(None)

        def _enable(func) -> None:
            self._completion_allowed = True
            original(func)

        def _block() -> None:
            self._completion_allowed = False
            original(None)

        self._module.set_completer = _guarded_set_completer  # type: ignore[assignment]
        self._module._ipybridge_enable_completion = _enable  # type: ignore[attr-defined]
        self._module._ipybridge_block_completion = _block  # type: ignore[attr-defined]
        return True


def _install_readline_guard() -> None:
    if not _SUPPRESS_READLINE_TAB:
        # Restore the default readline binding so TAB triggers completion.
        try:
            import readline  # type: ignore
        except Exception as exc:
            _log(f"readline unavailable; cannot enable TAB completion: {exc}")
            return
        try:
            readline.parse_and_bind("tab: complete")
        except Exception as exc:
            _log(f"failed to enable readline TAB completion: {exc}")
        return
    try:
        import readline  # type: ignore
    except Exception as exc:
        _log(f"readline unavailable: {exc}")
        return
    guard = _ReadlineTabGuard(readline)
    guard.install()


def _install_readline_history(path: str | None) -> None:
    """Bind readline history to a persistent file when available."""
    try:
        import readline  # type: ignore
    except Exception as exc:
        _log(f"readline unavailable; history disabled: {exc}")
        return
    expanded = _resolve_history_path(path)
    if not expanded:
        return
    try:
        readline.read_history_file(expanded)
    except FileNotFoundError:
        pass
    except Exception as exc:
        _log(f"history load failed: {exc}")
    try:
        atexit.register(readline.write_history_file, expanded)
    except Exception as exc:
        _log(f"history write hook failed: {exc}")


def _create_prompt_session():
    try:
        from prompt_toolkit.history import FileHistory, InMemoryHistory
        from prompt_toolkit.shortcuts import PromptSession
        from prompt_toolkit.key_binding import KeyBindings
    except Exception as exc:
        _log(f"prompt_toolkit unavailable: {exc}")
        return None

    history = InMemoryHistory()
    file_path = _resolve_history_path(os.environ.get(_HISTORY_FILE_ENV))
    if file_path:
        try:
            history = FileHistory(file_path)
        except Exception as exc:
            _log(f"history file disabled ({file_path}): {exc}")

    try:
        bindings = KeyBindings()

        @bindings.add("enter")
        def _accept_or_indent(event):
            if not _IPYBRIDGE_MULTILINE_MODE:
                event.current_buffer.validate_and_handle()
                return
            text = event.current_buffer.text
            if _is_complete_input(text):
                event.current_buffer.validate_and_handle()
                return
            indent = _next_prompt_indent(text)
            event.current_buffer.insert_text("\n" + indent)

        session = PromptSession(history=history, key_bindings=bindings)
    except Exception as exc:
        _log(f"prompt_toolkit session init failed: {exc}")
        return None
    _log("prompt_toolkit session ready")
    return session


def _prompt_message(prompt_text: str):
    if _PT_ANSI is not None and "\x1b[" in prompt_text:
        try:
            return _PT_ANSI(prompt_text)
        except Exception:
            return prompt_text
    return prompt_text


def _should_use_prompt_toolkit(session, debug_prompt: bool) -> bool:
    if session is None:
        return False
    return _SUPPRESS_READLINE_TAB or debug_prompt


def _prompt_with_session(session, prompt_text: str, multiline: bool) -> str:
    kwargs = {}
    if multiline:
        kwargs["multiline"] = True
        kwargs["prompt_continuation"] = _debug_prompt_continuation
    message = _prompt_message(prompt_text)
    prompt_async = getattr(session, "prompt_async", None)
    if callable(prompt_async) and _JC_RUN_SYNC is not None:
        try:
            return _JC_RUN_SYNC(prompt_async)(message, **kwargs)
        except Exception:
            pass
    return session.prompt(message, **kwargs)


def _install_input_patch(original_input) -> None:
    session = _create_prompt_session()
    input_failure_logged = False

    def _patched_input(prompt_text: str = "") -> str:
        """Wrapper around input() that prefers prompt_toolkit for key handling."""
        nonlocal input_failure_logged, session
        debug_prompt = _is_debug_prompt(prompt_text)
        if _should_use_prompt_toolkit(session, debug_prompt):
            try:
                with _multiline_prompt_state(debug_prompt):
                    return _prompt_with_session(session, prompt_text, debug_prompt)
            except (EOFError, KeyboardInterrupt):
                raise
            except Exception:
                if not input_failure_logged:
                    _log(f"prompt session failed:\n{traceback.format_exc().rstrip()}")
                    input_failure_logged = True
        if callable(original_input):
            return original_input(prompt_text)
        raise RuntimeError("builtins.input is not callable")

    if callable(original_input):
        builtins.input = _patched_input  # type: ignore[assignment]
        _log("input() patched for enhanced console editing")
    else:
        _log("input() could not be patched; original is missing")


if _PATCH_FLAG:
    _log("activating console patches")
    original_input = getattr(builtins, "input", None)
    _install_readline_history(os.environ.get(_HISTORY_FILE_ENV))
    _install_readline_guard()
    _install_input_patch(original_input)
