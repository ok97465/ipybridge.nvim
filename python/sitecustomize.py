"""Runtime patches that make jupyter-console/ipdb cooperate with Neovim.

When the bridge launches a console this module suppresses readline TAB
completion, proxies prompt_toolkit input, and surfaces diagnostic logging so
editor completion engines remain responsive even inside ipdb.
"""

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
    try:
        import readline  # type: ignore
    except Exception as exc:
        _log(f"readline unavailable: {exc}")
        return
    guard = _ReadlineTabGuard(readline)
    guard.install()


def _create_prompt_session():
    try:
        from prompt_toolkit.history import InMemoryHistory
        from prompt_toolkit.shortcuts import PromptSession
    except Exception as exc:
        _log(f"prompt_toolkit unavailable: {exc}")
        return None
    try:
        session = PromptSession(history=InMemoryHistory())
    except Exception as exc:
        _log(f"prompt_toolkit session init failed: {exc}")
        return None
    _log("prompt_toolkit session ready")
    return session


def _install_input_patch(original_input) -> None:
    session = _create_prompt_session()
    input_failure_logged = False

    def _patched_input(prompt_text: str = "") -> str:
        """Wrapper around input() that prefers prompt_toolkit for key handling."""
        nonlocal input_failure_logged, session
        loop_running = False
        try:
            asyncio.get_running_loop()
            loop_running = True
        except RuntimeError:
            loop_running = False
        if session is not None and not loop_running:
            try:
                return session.prompt(prompt_text)
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
    _install_readline_guard()
    _install_input_patch(original_input)
