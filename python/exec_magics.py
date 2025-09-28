"""IPython magics and debugger helpers injected by ipybridge.nvim."""

import base64
import contextlib
from contextlib import redirect_stdout
import io
import json
import linecache
import os
import re
import shlex
import sys
import warnings
import threading
import time
import traceback
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


try:
    import matplotlib.pyplot as _mi_plt
except Exception:  # pragma: no cover
    _mi_plt = None


def _mi_emit_vars_snapshot(frame=None):
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
_mi_qt_pump_thread = None
_mi_gui_enabled = False


def _mi_get_qapp():
    candidates = [
        ("qtpy.QtWidgets", "QApplication"),
        ("PyQt6.QtWidgets", "QApplication"),
        ("PySide6.QtWidgets", "QApplication"),
        ("PyQt5.QtWidgets", "QApplication"),
        ("PySide2.QtWidgets", "QApplication"),
    ]
    for mod_name, cls_name in candidates:
        try:
            module = __import__(mod_name, fromlist=[cls_name])
            cls = getattr(module, cls_name)
            app = cls.instance()
            if app is None:
                continue
            return app
        except Exception:
            continue
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
        self.session.send(self.stdin_socket, "input_request", content, parent, ident=ident)

        while True:
            _mi_process_qt_once()
            try:
                ready, _, xready = zmq.select([self.stdin_socket], [], [self.stdin_socket], 0.01)
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

        shells.extend(inst for inst in ZMQInteractiveShell.instance().__class__._instances)  # type: ignore[attr-defined]
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
                    shell.enable_matplotlib("qt5")
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


def _mi_enable_gui(backends=_MI_QT_BACKENDS):
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
    if _mi_enable_matplotlib(backends):
        _mi_gui_enabled = True
        return True
    return False


@contextlib.contextmanager
def _mi_qt_events(interval=0.03):
    _mi_patch_kernel_input()
    _mi_enable_matplotlib()
    _mi_enable_gui()
    _mi_start_qt_pump(interval)
    try:
        yield
    finally:
        pass


class _MiQtAwarePdb:
    _cls = None

    @classmethod
    def get(cls):
        if cls._cls is not None:
            return cls._cls
        try:
            from IPython.core.debugger import Pdb
        except Exception:
            return None

        class QtAwarePdb(Pdb):
            _mi_alias_map = {
                "!next": "next",
                "!step": "step",
                "!continue": "continue",
            }

            def interaction(self, *args, **kwargs):
                self._mi_autoprint = True
                with _mi_qt_events():
                    try:
                        _mi_emit_vars_snapshot(getattr(self, "curframe", None))
                        return super().interaction(*args, **kwargs)
                    finally:
                        try:
                            _mi_emit_vars_snapshot(getattr(self, "curframe", None))
                        except Exception:
                            pass
                        self._mi_autoprint = False

            def print_stack_entry(self, frame_lineno, prompt_prefix="\n-> ", context=None):
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
                        if sync is not None and frame is not None and lineno_int is not None:
                            filename = getattr(frame.f_code, "co_filename", None)
                            if filename:
                                sync(filename, lineno_int, 0)
                    except Exception:
                        pass
                    self._mi_autoprint = False
                    return
                return super().print_stack_entry(frame_lineno, prompt_prefix, context)

            def default(self, line):
                try:
                    cmd = line.strip().split()[0]
                except Exception:
                    cmd = ""
                target = self._mi_alias_map.get(cmd)
                if target:
                    method = getattr(self, "do_" + target, None)
                    if method is not None:
                        arg = line[len(cmd):].lstrip()
                        return method(arg)
                return super().default(line)

            def postcmd(self, stop, line):
                result = super().postcmd(stop, line)
                try:
                    _mi_emit_vars_snapshot(getattr(self, "curframe", None))
                except Exception:
                    pass
                return result

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


def runfile(filename, cwd=None):
    try:
        with io.open(filename, "r", encoding="utf-8") as handle:
            src = handle.read()
    except Exception as exc:
        print(f"runfile: cannot read {filename}: {exc}")
        return
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(src, filename, "exec"), globals(), globals())
            except SystemExit:
                pass
            except Exception:
                _mi_print_exception()


@register_line_magic("runfile")
def _runfile_magic(line):
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


def debugfile(filename, cwd=None):
    pdb_cls = _MiQtAwarePdb.get()
    if pdb_cls is None:
        print("debugfile: IPython debugger is unavailable")
        return
    try:
        with io.open(filename, "r", encoding="utf-8") as handle:
            src = handle.read()
    except Exception as exc:
        print(f"debugfile: cannot read {filename}: {exc}")
        return
    try:
        if _mi_plt is not None:
            _mi_plt.ion()
            _mi_start_qt_pump()
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
    _mi_enable_matplotlib()
    _mi_enable_gui()
    glbs = globals()
    dbg = pdb_cls()
    try:
        shell = getattr(dbg, "shell", None)
        colors = None
        if shell is not None:
            try:
                colors = getattr(shell, "colors", None)
            except Exception:
                colors = None
        target = "linux"
        if isinstance(colors, str) and colors:
            target = colors.strip().lower() or target
        if target == "nocolor":
            target = "linux"
        applied = False
        if hasattr(dbg, "set_theme_name"):
            try:
                dbg.set_theme_name(target)
                _ipy_log_debug(f"debug theme applied: {target}")
                applied = True
            except Exception as exc:
                _ipy_log_debug(f"debug theme apply failed: {exc}")
        if not applied and hasattr(dbg, "set_colors"):
            try:
                dbg.set_colors(target)
                _ipy_log_debug(f"debug colors legacy apply: {target}")
            except Exception as exc:
                _ipy_log_debug(f"debug legacy colors failed: {exc}")
        if shell is not None:
            try:
                color_map = {"linux": "Linux", "lightbg": "LightBG", "neutral": "Neutral", "nocolor": "NoColor"}
                magic_value = color_map.get(target, target)
                shell.run_line_magic('colors', magic_value)
                _ipy_log_debug(f"debug colors magic sent: {magic_value}")
            except Exception as exc:
                _ipy_log_debug(f"debug colors magic failed: {exc}")
    except Exception as exc:
        _ipy_log_debug(f"debug theme setup error: {exc}")
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
    try:
        with _mi_cwd(cwd):
            with _mi_exec_env(filename):
                code = compile(src, filename, "exec")
                dbg.reset()
                dbg.runctx(code, glbs, glbs)
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


@register_line_magic("debugfile")
def _debugfile_magic(line):
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
