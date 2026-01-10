"""IPython runtime helpers that keep the Neovim bridge in sync with a kernel.

The module installs custom magics, debugger signalers, variable snapshotters,
and OSC emitters so the editor can track execution state, surface structured
output, and control IPython sessions remotely.
"""

import ast
import base64
import bdb
import builtins
import codeop
import contextlib
from contextlib import redirect_stdout
import io
import json
import linecache
import os
import re
import shlex
import sys
import threading
import time
import traceback
import types
import warnings
from IPython.core.magic import register_line_magic

MODULE_B64 = "__MODULE_B64__"


try:
    _myipy_bootstrap_module
except NameError:  # pragma: no cover
    import types

    def _myipy_bootstrap_module():
        src = base64.b64decode(MODULE_B64).decode("utf-8")
        mod = sys.modules.get("ipybridge_ns")
        if mod is None:
            mod = types.ModuleType("ipybridge_ns")
            exec(compile(src, "<ipybridge_ns>", "exec"), mod.__dict__)
            sys.modules["ipybridge_ns"] = mod
        return mod


_MYIPY_MOD = _myipy_bootstrap_module()
from ipybridge_ns import (
    collect_namespace as _ipy_collect_namespace,
    get_var_filters as _ipy_get_var_filters,
    list_variables as _ipy_list_variables,
    log_debug as _ipy_log_debug,
)

_CELL_RE = re.compile(r"^# %%+")

_OSC_PREFIX = "\x1b]5379;ipybridge:"
_OSC_SUFFIX = "\x07"

_IPDB_PROMPT_COLORS = {
    "linux": "\x1b[92m",
    "neutral": "\x1b[32m",
    "lightbg": "\x1b[34m",
    "nocolor": "",
}


def _mi_emit_hidden_json(tag, payload):
    try:
        msg = json.dumps(payload, ensure_ascii=False)
    except Exception as exc:
        msg = json.dumps({"error": str(exc)}, ensure_ascii=False)
    try:
        sys.stdout.write(f"{_OSC_PREFIX}{tag}:{msg}{_OSC_SUFFIX}")
        sys.stdout.flush()
    except Exception:  # pragma: no cover
        pass


def _mi_emit_debug_location(frame, lineno=None):
    if isinstance(frame, (tuple, list)) and len(frame) >= 2 and lineno is None:
        lineno = frame[1]
        frame = frame[0]
    filename = None
    func = None
    if frame is not None:
        try:
            code = frame.f_code
        except Exception:
            code = None
        if code is not None:
            try:
                filename = code.co_filename
            except Exception:
                filename = None
            try:
                func = code.co_name
            except Exception:
                func = None
        if lineno is None:
            try:
                lineno = frame.f_lineno
            except Exception:
                lineno = None
    if lineno is None:
        return
    try:
        lineno_int = int(lineno)
    except Exception:
        lineno_int = lineno
    if filename:
        try:
            filename = os.path.abspath(filename)
        except Exception:
            pass
    source = None
    if filename and isinstance(lineno_int, int):
        try:
            linecache.checkcache(filename)
            source = linecache.getline(filename, lineno_int).rstrip("\r\n") or None
        except Exception:
            source = None
    data = {
        "file": filename,
        "line": lineno_int,
        "function": func,
        "source": source,
    }
    _mi_emit_hidden_json("debug_location", data)


def _mi_emit_debug_status(active):
    _mi_emit_hidden_json("debug_status", {"active": bool(active)})


def _mi_plot_autocapture(reason=None):
    helper = globals().get("_myipy_plot_autocapture")
    if not callable(helper):
        return
    try:
        helper(reason)
    except Exception:
        pass


try:
    import matplotlib.pyplot as _mi_plt
except Exception:  # pragma: no cover
    _mi_plt = None


def _mi_emit_vars_snapshot(frame=None):
    debug_ns = globals().get("_mi_active_debug_namespace")
    if frame is not None and debug_ns is not None:
        sync = getattr(debug_ns, "sync_from_frame", None)
        if callable(sync):
            try:
                sync(frame)
            except Exception as exc:
                _ipy_log_debug(f"debug namespace sync failed: {exc}")
    helper = globals().get("_myipy_emit_debug_vars")
    if callable(helper):
        try:
            helper(frame)
            return
        except Exception as exc:
            _ipy_log_debug(f"debug vars helper failed: {exc}")
    try:
        if frame is not None:
            namespace = _ipy_collect_namespace(
                getattr(frame, "f_globals", globals()),
                getattr(frame, "f_locals", None),
            )
        else:
            namespace = _ipy_collect_namespace(globals())
        filters = _ipy_get_var_filters()
        data = _ipy_list_variables(
            namespace=namespace,
            max_repr=filters.get("max_repr") or 120,
            hide_names=filters.get("names"),
            hide_types=filters.get("types"),
        )
        _mi_emit_hidden_json("vars", data)
    except Exception as exc:
        _ipy_log_debug(f"debug vars emit failed: {exc}")


def _mi_print_exception(shell=None, exc_info=None):
    if exc_info is None:
        exc_info = sys.exc_info()
    etype, evalue, tb = exc_info
    if shell is None:
        try:
            from IPython import get_ipython

            shell = get_ipython()
        except Exception:
            shell = None
    try:
        if shell is not None:
            try:
                shell.showtraceback(exc_info)
                return
            except Exception as exc:
                _ipy_log_debug(f"shell.showtraceback failed: {exc}")
        try:
            traceback.print_exception(etype, evalue, tb)
        except Exception:
            pass
    finally:
        tb = None


_MI_QT_BACKENDS = ("qt", "qt5", "qt6")
_PDB_ALIAS_MAP = {
    "!next": "next",
    "!step": "step",
    "!continue": "continue",
    "!return": "return",
    "!exit": "quit",
}
_mi_qt_pump_thread = None
_mi_gui_enabled = False
_mi_qt_loop_running = False


def _mi_read_text(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except Exception as exc:
        print(f"{label}: cannot read {path}: {exc}")
        return None


def _mi_exec_source(source, filename, cwd=None):
    if source is None:
        return
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(source, filename, "exec"), globals(), globals())
            except SystemExit:
                pass
            except Exception:
                _mi_print_exception()


def _mi_matplotlib_backend_hint():
    """Return the active Matplotlib backend name if it points to Qt."""
    source = _mi_plt or sys.modules.get("matplotlib")
    getter = getattr(source, "get_backend", None)
    if not callable(getter):
        return None
    try:
        backend = getter()
    except Exception:
        return None
    if not backend:
        return None
    backend = str(backend).lower()
    return backend if "qt" in backend else None


def _mi_iter_loaded_qt_modules():
    """Yield Qt-related modules that are already loaded in sys.modules."""
    backend_hint = _mi_matplotlib_backend_hint()
    modules = []
    seen = set()
    for name, module in list(sys.modules.items()):
        if module is None or name in seen:
            continue
        lowered = name.lower()
        if "qt" not in lowered and not lowered.startswith(("pyqt", "pyside")):
            continue
        modules.append((name, module))
        seen.add(name)
    if backend_hint:
        modules.sort(
            key=lambda item: (
                0 if backend_hint in item[0].lower() else 1,
                item[0],
            )
        )
    else:
        modules.sort(key=lambda item: item[0])
    for _, module in modules:
        yield module


def _mi_qapp_from_module(module):
    """Return the QApplication instance exposed by the given module."""
    candidates = []
    direct = getattr(module, "QApplication", None)
    if direct is not None:
        candidates.append(direct)
    widgets = getattr(module, "QtWidgets", None)
    if widgets is not None:
        nested = getattr(widgets, "QApplication", None)
        if nested is not None:
            candidates.append(nested)
    for cls in candidates:
        instance = None
        try:
            instance = cls.instance() if hasattr(cls, "instance") else None
        except Exception:
            instance = None
        if instance is not None:
            return instance
    return None


def _mi_get_qapp():
    for module in _mi_iter_loaded_qt_modules():
        app = _mi_qapp_from_module(module)
        if app is not None:
            return app
    return None


def _mi_start_qt_pump(interval=0.03):
    global _mi_qt_pump_thread
    if _mi_qt_pump_thread is not None and _mi_qt_pump_thread.is_alive():
        return

    def _pump():
        while True:
            app = None
            try:
                app = _mi_get_qapp()
            except Exception:
                app = None
            if app is not None:
                try:
                    app.processEvents()
                except Exception:
                    pass
            time.sleep(interval)

    thread = threading.Thread(target=_pump, name="ipybridge-qt-pump", daemon=True)
    thread.start()
    _mi_qt_pump_thread = thread


def _mi_process_qt_once():
    app = _mi_get_qapp()
    if app is None:
        return
    try:
        app.processEvents()
    except Exception:
        pass


_mi_kernel_input_patched = False


def _mi_patch_kernel_input():
    global _mi_kernel_input_patched
    if _mi_kernel_input_patched:
        return
    try:
        from ipykernel import kernelbase as _mi_kbase
        from ipykernel.jsonutil import json_clean
        import zmq
    except Exception:
        return

    def _ipybridge_input_request(self, prompt, ident, parent, password=False):
        sys.stderr.flush()
        sys.stdout.flush()

        while True:
            try:
                self.stdin_socket.recv_multipart(zmq.NOBLOCK)
            except zmq.ZMQError as exc:
                if exc.errno == zmq.EAGAIN:
                    break
                raise

        assert self.session is not None
        content = json_clean(dict(prompt=prompt, password=password))
        self.session.send(
            self.stdin_socket, "input_request", content, parent, ident=ident
        )

        while True:
            _mi_process_qt_once()
            try:
                ready, _, xready = zmq.select(
                    [self.stdin_socket], [], [self.stdin_socket], 0.01
                )
                if ready or xready:
                    ident_reply, reply = self.session.recv(self.stdin_socket)
                    if (ident_reply, reply) != (None, None):
                        break
            except KeyboardInterrupt:
                raise KeyboardInterrupt("Interrupted by user") from None
            except Exception:
                self.log.warning("Invalid Message:", exc_info=True)

        try:
            value = reply["content"]["value"]
        except Exception:
            self.log.error("Bad input_reply: %s", parent)
            value = ""
        if value == "\x04":
            raise EOFError
        return value

    _mi_kbase.Kernel._input_request = _ipybridge_input_request
    _mi_kernel_input_patched = True


def _mi_enable_matplotlib(backends=_MI_QT_BACKENDS):
    global _mi_gui_enabled
    shells = []
    try:
        from IPython import get_ipython

        ip = get_ipython()
        if ip is not None:
            shells.append(ip)
    except Exception:
        pass
    try:
        from ipykernel.zmqshell import ZMQInteractiveShell

        shells.extend(
            inst for inst in ZMQInteractiveShell.instance().__class__._instances
        )  # type: ignore[attr-defined]
    except Exception:
        pass
    for shell in shells:
        try:
            with warnings.catch_warnings():
                warnings.filterwarnings(
                    "ignore",
                    message="Cannot change to a different GUI toolkit",
                    category=UserWarning,
                )
                with redirect_stdout(io.StringIO()):
                    shell.enable_matplotlib("qt")
            _mi_gui_enabled = True
            return True
        except Exception:
            continue
    try:
        from ipykernel import eventloops as _mi_eventloops

        for backend in backends:
            try:
                with warnings.catch_warnings():
                    warnings.filterwarnings(
                        "ignore",
                        message="Cannot change to a different GUI toolkit",
                        category=UserWarning,
                    )
                    with redirect_stdout(io.StringIO()):
                        _mi_eventloops.enable_gui(backend)
                _mi_gui_enabled = True
                return True
            except Exception:
                continue
    except Exception:
        pass
    return False


def _mi_enable_gui(backends=_MI_QT_BACKENDS, *, allow_backend_fallback=True):
    global _mi_gui_enabled
    if _mi_gui_enabled:
        return True
    try:
        from ipykernel.kernelapp import IPKernelApp

        app = IPKernelApp.instance()
    except Exception:
        app = None
    if app is not None:
        for backend in backends:
            try:
                if getattr(app, "_gui", None) == backend:
                    _mi_gui_enabled = True
                    return True
                with warnings.catch_warnings():
                    warnings.filterwarnings(
                        "ignore",
                        message="Cannot change to a different GUI toolkit",
                        category=UserWarning,
                    )
                    with redirect_stdout(io.StringIO()):
                        app.enable_gui(backend)
                _mi_gui_enabled = True
                return True
            except Exception:
                continue
    if allow_backend_fallback and _mi_enable_matplotlib(backends):
        _mi_gui_enabled = True
        return True
    return False


def _mi_maybe_start_qt_loop(interval=0.03):
    global _mi_qt_loop_running
    if _mi_qt_loop_running:
        return
    backend_hint = _mi_matplotlib_backend_hint()
    if not backend_hint:
        return
    try:
        _mi_enable_gui(allow_backend_fallback=False)
    except TypeError:  # pragma: no cover - compat guard
        _mi_enable_gui()
    _mi_start_qt_pump(interval)
    _mi_qt_loop_running = True


@contextlib.contextmanager
def _mi_qt_events(interval=0.03):
    _mi_patch_kernel_input()
    _mi_maybe_start_qt_loop(interval)
    try:
        yield
    finally:
        pass


class _MiQtAwarePdb:
    _cls = None

    @classmethod
    def get(cls):
        """Return the debugger class with Qt-aware breakpoint handling."""
        if cls._cls is not None:
            return cls._cls
        try:
            from IPython.core.debugger import Pdb
        except Exception:
            return None

        class QtAwarePdb(Pdb):
            def _mi_effective_ignore_eval_errors(self, file, line, frame):
                """Evaluate conditional breakpoints without stopping on errors."""
                possibles = bdb.Breakpoint.bplist.get((file, line))
                if not possibles:
                    return (None, None)
                for bp in possibles:
                    if not bp.enabled:
                        continue
                    if not bdb.checkfuncname(bp, frame):
                        continue
                    bp.hits += 1
                    if not bp.cond:
                        if bp.ignore > 0:
                            bp.ignore -= 1
                            continue
                        return (bp, True)
                    try:
                        should_stop = eval(bp.cond, frame.f_globals, frame.f_locals)
                    except Exception:
                        continue
                    if should_stop:
                        if bp.ignore > 0:
                            bp.ignore -= 1
                            continue
                        return (bp, True)
                return (None, None)

            def break_here(self, frame):
                filename = self.canonic(frame.f_code.co_filename)
                if filename not in self.breaks:
                    return False
                lineno = frame.f_lineno
                if lineno not in self.breaks[filename]:
                    lineno = frame.f_code.co_firstlineno
                    if lineno not in self.breaks[filename]:
                        return False

                bp, flag = self._mi_effective_ignore_eval_errors(
                    filename, lineno, frame
                )
                if bp:
                    self.currentbp = bp.number
                    if flag and bp.temporary:
                        self.do_clear(str(bp.number))
                    return True
                return False

            def setup(self, frame, tb):
                result = super().setup(frame, tb)
                try:
                    _mi_emit_vars_snapshot(getattr(self, "curframe", frame))
                except Exception:
                    pass
                try:
                    _mi_plot_autocapture("debug.break")
                except Exception:
                    pass
                return result

            def interaction(self, *args, **kwargs):
                self._mi_autoprint = True
                _mi_emit_debug_status(True)
                with _mi_qt_events():
                    try:
                        return super().interaction(*args, **kwargs)
                    finally:
                        try:
                            _mi_emit_vars_snapshot(getattr(self, "curframe", None))
                        except Exception:
                            pass
                        try:
                            if getattr(self, "quitting", False):
                                _mi_emit_debug_status(False)
                        except Exception:
                            pass
                        self._mi_autoprint = False

            def print_stack_entry(
                self, frame_lineno, prompt_prefix="\n-> ", context=None
            ):
                emit = getattr(self, "_mi_autoprint", False)
                if emit:
                    try:
                        frame, lineno = frame_lineno
                    except Exception:
                        frame, lineno = frame_lineno, None
                    try:
                        lineno_int = int(lineno)
                    except Exception:
                        lineno_int = lineno
                    _mi_emit_debug_location(frame, lineno_int)
                    try:
                        shell = getattr(self, "shell", None)
                        hooks = getattr(shell, "hooks", None)
                        sync = getattr(hooks, "synchronize_with_editor", None)
                        if (
                            sync is not None
                            and frame is not None
                            and lineno_int is not None
                        ):
                            filename = getattr(frame.f_code, "co_filename", None)
                            if filename:
                                sync(filename, lineno_int, 0)
                    except Exception:
                        pass
                    self._mi_autoprint = False
                    return
                return super().print_stack_entry(frame_lineno, prompt_prefix, context)

            _mi_multiline_prompt = "... "
            _mi_indent_step = 4
            _mi_dedent_tokens = {
                "elif",
                "else",
                "except",
                "except*",
                "finally",
                "case",
            }

            def _mi_read_input(self, prompt_text):
                """Read a single input line using cmd.Cmd semantics."""
                if self.use_rawinput:
                    try:
                        return input(prompt_text)
                    except EOFError:
                        return "EOF"
                self.stdout.write(prompt_text)
                self.stdout.flush()
                line = self.stdin.readline()
                if not line:
                    return "EOF"
                return line.rstrip("\r\n")

            def _mi_needs_multiline(self, source):
                if not source or not source.strip():
                    return False
                try:
                    return codeop.compile_command(
                        source, "<stdin>", "exec"
                    ) is None
                except (SyntaxError, OverflowError, ValueError):
                    return False

            def _mi_line_indent(self, line):
                return len(line) - len(line.lstrip())

            def _mi_strip_comment(self, line):
                if "#" not in line:
                    return line
                return line.split("#", 1)[0]

            def _mi_opens_block(self, line):
                if not line:
                    return False
                stripped = self._mi_strip_comment(line).rstrip()
                if not stripped or stripped.lstrip().startswith("#"):
                    return False
                return stripped.endswith(":")

            def _mi_first_token(self, text):
                if not text:
                    return ""
                stripped = text.lstrip()
                if not stripped:
                    return ""
                token = stripped.split(None, 1)[0]
                if token.endswith(":"):
                    token = token[:-1]
                return token

            def _mi_update_indent_stack(self, line, stack):
                if not line or not line.strip():
                    return
                indent = self._mi_line_indent(line)
                while len(stack) > 1 and stack[-1] > indent:
                    stack.pop()
                if self._mi_opens_block(line):
                    stack.append(indent + self._mi_indent_step)

            def _mi_next_indent(self, raw, stack):
                indent = stack[-1]
                token = self._mi_first_token(raw)
                if token in self._mi_dedent_tokens and len(stack) > 1:
                    indent = stack[-2]
                return indent

            def _mi_prompt_for_indent(self, indent):
                return self._mi_multiline_prompt + (" " * indent)

            def _mi_prepare_next_line(self, raw, stack):
                if not raw or not raw.strip():
                    return ""
                if raw[:1].isspace():
                    return raw
                indent = self._mi_next_indent(raw, stack)
                return (" " * indent) + raw

            def _mi_collect_multiline(self, line):
                if not self._mi_needs_multiline(line):
                    return line
                lines = [line]
                indent_stack = [0]
                self._mi_update_indent_stack(line, indent_stack)
                while True:
                    prompt = self._mi_prompt_for_indent(indent_stack[-1])
                    next_raw = self._mi_read_input(prompt)
                    if next_raw == "EOF":
                        break
                    next_line = self._mi_prepare_next_line(next_raw, indent_stack)
                    lines.append(next_line)
                    self._mi_update_indent_stack(next_line, indent_stack)
                    block = "\n".join(lines)
                    if not self._mi_needs_multiline(block):
                        return block
                return "\n".join(lines)

            def _mi_capture_last_expr(self, code_ast):
                if not code_ast.body:
                    return code_ast, None
                last = code_ast.body[-1]
                if not isinstance(last, ast.Expr):
                    return code_ast, None
                name = "_ipybridge_pdb_out"
                code_ast.body[-1] = ast.Assign(
                    targets=[ast.Name(id=name, ctx=ast.Store())],
                    value=last.value,
                )
                ast.fix_missing_locations(code_ast)
                return code_ast, name

            def _mi_prepare_exec(self, block, locals_):
                code_ast = ast.parse(block)
                code_ast, out_name = self._mi_capture_last_expr(code_ast)
                had_out = False
                prev_out = None
                if out_name is not None:
                    had_out = out_name in locals_
                    if had_out:
                        prev_out = locals_.get(out_name)
                code = compile(code_ast, "<stdin>", "exec")
                return code, out_name, had_out, prev_out

            def _mi_maybe_display_last_expr(self, out_name, locals_, had_out, prev_out):
                if out_name is None:
                    return
                out = locals_.pop(out_name, None)
                if had_out:
                    locals_[out_name] = prev_out
                if out is not None:
                    sys.displayhook(out)

            @contextlib.contextmanager
            def _mi_io_context(self):
                save_stdout = sys.stdout
                save_stdin = sys.stdin
                save_displayhook = sys.displayhook
                try:
                    sys.stdin = self.stdin
                    sys.stdout = self.stdout
                    sys.displayhook = self.displayhook
                    yield
                finally:
                    sys.stdout = save_stdout
                    sys.stdin = save_stdin
                    sys.displayhook = save_displayhook

            def _mi_exec_block(self, block):
                if "\n" not in block:
                    return super().default(block)
                if block[:1] == "!":
                    block = block[1:]
                locals_ = self.curframe_locals
                globals_ = self.curframe.f_globals
                try:
                    code, out_name, had_out, prev_out = self._mi_prepare_exec(
                        block, locals_
                    )
                    with self._mi_io_context():
                        exec(code, globals_, locals_)
                        self._mi_maybe_display_last_expr(
                            out_name, locals_, had_out, prev_out
                        )
                except BaseException:
                    self._error_exc()

            def _mi_error_with_colors(self, exc):
                colors = getattr(self, "color_scheme_table", None)
                if colors is None:
                    return super()._error_exc()
                active = getattr(colors, "active_colors", None)
                if not active:
                    return super()._error_exc()
                try:
                    exc_color = active.excName
                    normal_color = active.Normal
                except Exception:
                    try:
                        exc_color = active.get("excName")
                        normal_color = active.get("Normal")
                    except Exception:
                        return super()._error_exc()
                if not exc_color:
                    return super()._error_exc()
                message = f"{exc_color}{exc.__class__.__name__}{normal_color}"
                try:
                    details = str(exc)
                except Exception:
                    details = ""
                if details:
                    message += f": {details}"
                return super().error(message)

            def default(self, line):
                handled = self._mi_apply_alias(line)
                if handled is not None:
                    return handled
                if self._mi_handle_matplotlib_magic(line):
                    return None
                block = self._mi_collect_multiline(line)
                return self._mi_exec_block(block)

            def _error_exc(self):
                exc = sys.exception()
                if exc is None:
                    return super()._error_exc()
                theme = getattr(self, "theme", None)
                if theme is None:
                    return self._mi_error_with_colors(exc)
                try:
                    from pygments.token import Token
                except Exception:
                    return self._mi_error_with_colors(exc)
                try:
                    message = theme.format(
                        [
                            (Token.ExcName, exc.__class__.__name__),
                            (Token.Normal, f": {exc}"),
                        ]
                    )
                    super().error(message)
                except Exception:
                    self._mi_error_with_colors(exc)

            def _mi_apply_alias(self, line):
                try:
                    cmd = line.strip().split()[0]
                except Exception:
                    return None
                target = _PDB_ALIAS_MAP.get(cmd)
                if not target:
                    return None
                method = getattr(self, "do_" + target, None)
                if method is None:
                    return None
                arg = line[len(cmd) :].lstrip()
                return method(arg)

            def postcmd(self, stop, line):
                result = super().postcmd(stop, line)
                try:
                    _mi_emit_vars_snapshot(getattr(self, "curframe", None))
                except Exception:
                    pass
                return result

            def _mi_handle_matplotlib_magic(self, line):
                if not line:
                    return False
                try:
                    text = line.strip()
                except Exception:
                    text = line
                if not text.startswith("%"):
                    return False
                if text.startswith("%%"):
                    return False
                text = text[1:].lstrip()
                if not text:
                    return False
                parts = text.split(None, 1)
                magic_name = parts[0].strip()
                magic_key = magic_name.lower()
                if magic_key not in {"matplotlib", "pylab"}:
                    return False
                arg = parts[1].strip() if len(parts) > 1 else ""
                shell = getattr(self, "shell", None)
                runner = getattr(shell, "run_line_magic", None)
                if not callable(runner):
                    return False
                try:
                    runner(magic_name, arg)
                except Exception as exc:
                    handler = getattr(self, "error", None)
                    if callable(handler):
                        try:
                            handler(str(exc))
                        except Exception:
                            pass
                    else:
                        _ipy_log_debug(f"matplotlib magic failed: {exc}")
                else:
                    _mi_maybe_start_qt_loop()
                return True

        cls._cls = QtAwarePdb
        return cls._cls


@contextlib.contextmanager
def _mi_cwd(path):
    if not path:
        yield
        return
    try:
        old = os.getcwd()
    except Exception:
        old = None
    try:
        os.chdir(path)
        yield
    finally:
        if old is not None:
            try:
                os.chdir(old)
            except Exception:
                pass


@contextlib.contextmanager
def _mi_exec_env(filename):
    g = globals()
    prev_file = g.get("__file__", None)
    g["__file__"] = filename
    try:
        yield
    finally:
        if prev_file is None:
            g.pop("__file__", None)
        else:
            g["__file__"] = prev_file


def _mi_acquire_user_namespace():
    try:
        from IPython import get_ipython

        shell = get_ipython()
    except Exception:
        shell = None
    if shell is None:
        return None
    try:
        return getattr(shell, "user_ns", None)
    except Exception:
        return None


class _MiDebugNamespace:
    """Isolated execution namespace that syncs results back to IPython."""

    __slots__ = (
        "filename",
        "module",
        "globals",
        "_prev_main",
        "_user_ns",
        "_skip_keys",
    )

    def __init__(self, filename):
        self.filename = filename
        self.module = None
        self.globals = None
        self._prev_main = None
        self._user_ns = None
        self._skip_keys = {
            "__builtins__",
            "__cached__",
            "__doc__",
            "__loader__",
            "__package__",
            "__spec__",
        }

    def __enter__(self):
        self._user_ns = _mi_acquire_user_namespace()
        module = types.ModuleType("__ipybridge_debug__")
        module.__dict__["__name__"] = "__main__"
        module.__dict__["__file__"] = self.filename
        module.__dict__["__builtins__"] = builtins
        self.module = module
        self.globals = module.__dict__
        self._prev_main = sys.modules.get("__main__")
        sys.modules["__main__"] = module
        return self

    def seed_from_user_ns(self):
        """Seed the isolated namespace with the current IPython user_ns."""
        if not self._user_ns or not self.globals:
            return
        try:
            items = list(self._user_ns.items())
        except Exception:
            return
        for key, value in items:
            if not isinstance(key, str):
                continue
            if key in self._skip_keys or key.startswith("__"):
                continue
            self.globals[key] = value

    def __exit__(self, exc_type, exc, tb):
        if self._prev_main is None:
            sys.modules.pop("__main__", None)
        else:
            sys.modules["__main__"] = self._prev_main

    def commit(self):
        """Commit values back into the IPython user namespace."""
        if not self._user_ns:
            return
        try:
            self._user_ns["__file__"] = self.filename
            self._user_ns["__name__"] = "__main__"
        except Exception:
            pass
        for key, value in self.globals.items():
            if key in self._skip_keys or key.startswith("__"):
                continue
            self._user_ns[key] = value

    def sync_from_frame(self, frame):
        """Sync variables from a frame into the IPython user namespace."""
        if not self._user_ns:
            return
        mappings = []
        if frame is not None:
            try:
                frame_globals = getattr(frame, "f_globals", None)
            except Exception:
                frame_globals = None
            try:
                frame_locals = getattr(frame, "f_locals", None)
            except Exception:
                frame_locals = None
            if frame_globals:
                mappings.append(frame_globals)
            if frame_locals and frame_locals is not frame_globals:
                mappings.append(frame_locals)
        if not mappings and self.globals:
            mappings.append(self.globals)
        for mapping in mappings:
            try:
                items = list(mapping.items())
            except Exception:
                continue
            for key, value in items:
                if not isinstance(key, str):
                    continue
                if key.startswith("__") or key in self._skip_keys:
                    continue
                self._user_ns[key] = value


def _mi_resolve_cell(lines, index):
    markers = [lineno for lineno, text in enumerate(lines) if _CELL_RE.match(text)]
    if not markers:
        return None, None, 0
    try:
        idx = int(index)
    except Exception:
        return None, None, len(markers)
    if idx < 0 or idx >= len(markers):
        return None, None, len(markers)
    start = markers[idx] + 1
    end = len(lines)
    if idx + 1 < len(markers):
        end = markers[idx + 1]
    return (start, end), start, len(markers)


def runcell(cell_index, filename, cwd=None):
    """Execute the specified cell in a file that uses Jupyter-style markers."""
    text = _mi_read_text(filename, "runcell")
    if text is None:
        return
    lines = text.splitlines()

    region, start_line, total = _mi_resolve_cell(lines, cell_index)
    if region is None:
        if total == 0:
            print(f"runcell: no cell markers found in {filename}")
        else:
            try:
                idx = int(cell_index)
            except Exception:
                idx = cell_index
            print(f"runcell: cell {idx} out of range (total {total})")
        return

    start, end = region
    cell_lines = lines[start:end]
    if not cell_lines:
        return
    prefix = "\n" * start_line
    source = prefix + "\n".join(cell_lines)
    _mi_exec_source(source, filename, cwd)


@register_line_magic("runcell")
def _runcell_magic(line):
    """IPython line magic wrapper for runcell."""
    try:
        parts = shlex.split(line)
    except Exception:
        print("Usage: %runcell <index> <path> [cwd]")
        return
    if len(parts) < 2:
        print("Usage: %runcell <index> <path> [cwd]")
        return
    idx = parts[0]
    path = parts[1]
    cwd = parts[2] if len(parts) > 2 else None
    runcell(idx, path, cwd)


def runfile(filename, cwd=None):
    """Execute an entire Python file in the user namespace."""
    source = _mi_read_text(filename, "runfile")
    if source is None:
        return
    _mi_exec_source(source, filename, cwd)


@register_line_magic("runfile")
def _runfile_magic(line):
    """IPython line magic wrapper for runfile."""
    try:
        parts = shlex.split(line)
    except Exception:
        print("Usage: %runfile <path> [cwd]")
        return
    if len(parts) < 1:
        print("Usage: %runfile <path> [cwd]")
        return
    path = parts[0]
    cwd = parts[1] if len(parts) > 1 else None
    runfile(path, cwd)


def _debug_execute_source(label, source, filename, cwd=None, seed_user_ns=False):
    pdb_cls = _MiQtAwarePdb.get()
    if pdb_cls is None:
        print(f"{label}: IPython debugger is unavailable")
        return
    try:
        if _mi_plt is not None:
            if not hasattr(_mi_plt, "_myipy_orig_show"):
                _mi_plt._myipy_orig_show = _mi_plt.show

                def _mi_debug_show(*args, **kwargs):
                    kwargs.setdefault("block", False)
                    result = _mi_plt._myipy_orig_show(*args, **kwargs)
                    app = _mi_get_qapp()
                    if app is not None:
                        for _ in range(5):
                            try:
                                app.processEvents()
                            except Exception:
                                break
                            time.sleep(0.01)
                    return result

                _mi_plt.show = _mi_debug_show
    except Exception:
        pass
    _mi_maybe_start_qt_loop()
    glbs = globals()
    dbg = pdb_cls()
    glbs["_mi_active_debugger"] = dbg
    shell = None
    try:
        shell = getattr(dbg, "shell", None)
    except Exception:
        pass
    if shell is not None:
        try:
            theme_name = getattr(shell, "colors", None)
        except Exception:
            theme_name = None
    else:
        theme_name = None
    theme_name = (theme_name or "linux").lower()
    prompt_prefix = _IPDB_PROMPT_COLORS.get(theme_name)
    if not prompt_prefix:
        prompt_prefix = _IPDB_PROMPT_COLORS.get("linux", "")
    if prompt_prefix:
        dbg.prompt = f"{prompt_prefix}ipdb>\x1b[0m "
    else:
        dbg.prompt = "ipdb> "
    helper_prepare = glbs.get("_myipy_prepare_breakpoints_for_debug")
    if callable(helper_prepare):
        try:
            helper_prepare(dbg)
        except Exception as exc:
            _ipy_log_debug(f"debug breakpoint prepare failed: {exc}")
    else:
        try:
            dbg.clear_all_breaks()
        except Exception:
            pass
        try:
            bp_map = glbs.get("__ipybridge_breakpoints__", {})
        except Exception:
            bp_map = {}
        if isinstance(bp_map, dict):
            for bp_file, bp_lines in bp_map.items():
                if not isinstance(bp_lines, (list, tuple, set)):
                    continue
                for bp_line in bp_lines:
                    try:
                        line_no = int(bp_line)
                    except Exception:
                        continue
                    try:
                        dbg.set_break(bp_file, line_no)
                    except Exception:
                        pass
    old_break_hook = getattr(sys, "breakpointhook", None)
    try:
        sys.breakpointhook = dbg.set_trace
    except Exception:
        old_break_hook = None
    auto_import_block = None
    if label == "debugfile":
        helper_imports = glbs.get("_myipy_get_debugfile_imports")
        if callable(helper_imports):
            candidate = helper_imports()
            if isinstance(candidate, str):
                candidate = candidate.strip()
                if candidate:
                    auto_import_block = candidate
    try:
        with _mi_cwd(cwd):
            with _mi_exec_env(filename):
                with _MiDebugNamespace(filename) as debug_ns:
                    glbs["_mi_active_debug_namespace"] = debug_ns
                    if seed_user_ns:
                        try:
                            debug_ns.seed_from_user_ns()
                        except Exception as exc:
                            _ipy_log_debug(f"debug namespace seed failed: {exc}")
                    should_commit = False
                    try:
                        if auto_import_block:
                            try:
                                exec(
                                    auto_import_block,
                                    debug_ns.globals,
                                    debug_ns.globals,
                                )
                            except Exception as exc:
                                print(f"debugfile auto import failed: {exc}")
                        code = compile(source, filename, "exec")
                        should_commit = True
                        dbg.reset()
                        dbg.runctx(code, debug_ns.globals, debug_ns.globals)
                    finally:
                        try:
                            glbs.pop("_mi_active_debug_namespace", None)
                        except Exception:
                            glbs["_mi_active_debug_namespace"] = None
                        if should_commit:
                            try:
                                debug_ns.commit()
                            except Exception as exc:
                                _ipy_log_debug(f"debug namespace commit failed: {exc}")
    except SystemExit:
        pass
    except Exception:
        _mi_print_exception(getattr(dbg, "shell", None))
    finally:
        if _mi_plt is not None and hasattr(_mi_plt, "_myipy_orig_show"):
            try:
                _mi_plt.show = _mi_plt._myipy_orig_show
            except Exception:
                pass
            try:
                delattr(_mi_plt, "_myipy_orig_show")
            except Exception:
                pass
        if old_break_hook is not None:
            try:
                sys.breakpointhook = old_break_hook
            except Exception:
                pass
        else:
            try:
                del sys.breakpointhook
            except Exception:
                pass
        try:
            dbg.quitting = True
        except Exception:
            pass
        try:
            glbs["_mi_active_debugger"] = None
        except Exception:
            pass
        try:
            _mi_emit_debug_status(False)
        except Exception:
            pass
        try:
            _mi_plot_autocapture("debug.exit")
        except Exception:
            pass


def debugfile(filename, cwd=None):
    """Debug a Python file using the IPython debugger."""
    source = _mi_read_text(filename, "debugfile")
    if source is None:
        return
    _debug_execute_source("debugfile", source, filename, cwd, seed_user_ns=False)


def debugcell(cell_index, filename, cwd=None):
    """Debug a specific cell in a file that uses Jupyter-style markers."""
    text = _mi_read_text(filename, "debugcell")
    if text is None:
        return
    lines = text.splitlines()

    region, start_line, total = _mi_resolve_cell(lines, cell_index)
    if region is None:
        if total == 0:
            print(f"debugcell: no cell markers found in {filename}")
        else:
            try:
                idx = int(cell_index)
            except Exception:
                idx = cell_index
            print(f"debugcell: cell {idx} out of range (total {total})")
        return

    start, end = region
    cell_lines = lines[start:end]
    if not cell_lines:
        print("debugcell: selected cell is empty")
        return
    prefix = "\n" * start_line
    source = prefix + "\n".join(cell_lines)
    _debug_execute_source("debugcell", source, filename, cwd, seed_user_ns=True)


@register_line_magic("debugfile")
def _debugfile_magic(line):
    """IPython line magic wrapper for debugfile."""
    try:
        parts = shlex.split(line)
    except Exception:
        print("Usage: %debugfile <path> [cwd]")
        return
    if len(parts) < 1:
        print("Usage: %debugfile <path> [cwd]")
        return
    path = parts[0]
    cwd = parts[1] if len(parts) > 1 else None
    debugfile(path, cwd)


@register_line_magic("debugcell")
def _debugcell_magic(line):
    """IPython line magic wrapper for debugcell."""
    try:
        parts = shlex.split(line)
    except Exception:
        print("Usage: %debugcell <index> <path> [cwd]")
        return
    if len(parts) < 2:
        print("Usage: %debugcell <index> <path> [cwd]")
        return
    idx = parts[0]
    path = parts[1]
    cwd = parts[2] if len(parts) > 2 else None
    debugcell(idx, path, cwd)
