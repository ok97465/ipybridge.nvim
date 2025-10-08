"""Runtime patches for jupyter-console launched by ipybridge.nvim."""

from __future__ import annotations

import asyncio
import builtins
import os
import sys
import traceback


_PATCH_FLAG = os.environ.get("IPYBRIDGE_CONSOLE_PATCH")
_PATCH_SILENT_VALUE = os.environ.get("IPYBRIDGE_CONSOLE_PATCH_SILENT") or ""
_PATCH_SILENT = _PATCH_SILENT_VALUE.lower() in {"1", "true", "yes", "on"}


def _log(message: str) -> None:
    """Emit a short diagnostic to stderr when console patching is requested."""
    if not _PATCH_FLAG or _PATCH_SILENT:
        return
    try:
        sys.stderr.write(f"[ipybridge.console] {message}\n")
        sys.stderr.flush()
    except Exception:
        pass


if _PATCH_FLAG:
    _log("activating console patches")
    _original_input = getattr(builtins, "input", None)

    try:
        import readline  # type: ignore
    except Exception as exc:
        _log(f"readline unavailable: {exc}")
    else:
        completion_state = {"allow": False}
        original_parse_and_bind = getattr(readline, "parse_and_bind", None)
        original_set_completer = getattr(readline, "set_completer", None)

        if callable(original_parse_and_bind):

            def _apply_tab_self_insert() -> None:
                """Bind TAB to literal insertion across GNU readline and libedit."""
                for binding in ("tab: self-insert", "bind ^I self-insert"):
                    try:
                        original_parse_and_bind(binding)
                        return
                    except Exception:
                        continue

            def _guarded_parse_and_bind(command) -> None:
                """Prevent TAB from being rebound to readline's completer."""
                if command is None:
                    return original_parse_and_bind(command)
                if isinstance(command, bytes):
                    text = command.decode(errors="ignore")
                else:
                    text = str(command)
                lowered = text.strip().lower()
                if (
                    ": complete" in lowered
                    or " rl_complete" in lowered
                    or lowered.startswith("bind ^i")
                    or lowered.startswith("bind \\t")
                ):
                    _apply_tab_self_insert()
                    return
                original_parse_and_bind(command)

            readline.parse_and_bind = _guarded_parse_and_bind  # type: ignore[assignment]
            try:
                original_parse_and_bind("set editing-mode emacs")
                _apply_tab_self_insert()
            except Exception as exc:
                _log(f"readline baseline bindings failed: {exc}")
            else:
                _log("readline editing enabled with TAB suppression")
        else:
            _log("readline parse_and_bind unavailable; TAB suppression skipped")

        if callable(original_set_completer):

            def _guarded_set_completer(func):
                if completion_state["allow"]:
                    return original_set_completer(func)
                return original_set_completer(None)

            def _ipybridge_enable_completion(func) -> None:
                """Allow ipybridge to install its own completer later."""
                completion_state["allow"] = True
                original_set_completer(func)

            def _ipybridge_block_completion() -> None:
                """Re-disable readline completion when needed."""
                completion_state["allow"] = False
                original_set_completer(None)

            readline.set_completer = _guarded_set_completer  # type: ignore[assignment]
            readline._ipybridge_enable_completion = _ipybridge_enable_completion  # type: ignore[attr-defined]
            readline._ipybridge_block_completion = _ipybridge_block_completion  # type: ignore[attr-defined]
        else:
            _log("readline set_completer unavailable; TAB suppression incomplete")

    _session = None
    _input_failure_logged = False

    try:
        from prompt_toolkit.shortcuts import PromptSession
        from prompt_toolkit.history import InMemoryHistory

        _session = PromptSession(history=InMemoryHistory())
        _log("prompt_toolkit session ready")
    except Exception as exc:
        _session = None
        _log(f"prompt_toolkit unavailable: {exc}")

    def _patched_input(prompt_text: str = "") -> str:
        """Wrapper around input() that prefers prompt_toolkit for key handling."""
        global _input_failure_logged
        loop_running = False
        try:
            asyncio.get_running_loop()
            loop_running = True
        except RuntimeError:
            loop_running = False
        if _session is not None and not loop_running:
            try:
                return _session.prompt(prompt_text)
            except (EOFError, KeyboardInterrupt):
                raise
            except Exception:
                if not _input_failure_logged:
                    _log(f"prompt session failed:\n{traceback.format_exc().rstrip()}")
                    _input_failure_logged = True
        if callable(_original_input):
            return _original_input(prompt_text)
        raise RuntimeError("builtins.input is not callable")

    if callable(_original_input):
        builtins.input = _patched_input  # type: ignore[assignment]
        _log("input() patched for enhanced console editing")
    else:
        _log("input() could not be patched; original is missing")
