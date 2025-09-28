"""Runtime patches for jupyter-console launched by ipybridge.nvim."""

from __future__ import annotations

import asyncio
import builtins
import os
import sys
import traceback


_PATCH_FLAG = os.environ.get("IPYBRIDGE_CONSOLE_PATCH")


def _log(message: str) -> None:
    """Emit a short diagnostic to stderr when console patching is requested."""
    if not _PATCH_FLAG:
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

        try:
            readline.parse_and_bind("set editing-mode emacs")
            readline.parse_and_bind("tab: complete")
        except Exception as exc:
            _log(f"readline configuration failed: {exc}")
        else:
            _log("readline editing enabled")
    except Exception as exc:
        _log(f"readline unavailable: {exc}")

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
