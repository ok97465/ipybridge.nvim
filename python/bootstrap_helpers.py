"""Bootstrap helpers imported into the user kernel by ipybridge.nvim.

The module patches kernel control handlers, manages comm traffic, maintains
debug snapshots, tracks breakpoints, and exposes data preview / completion
utilities that the Neovim side can invoke over ZMQ.
"""

import base64
import io
import json
import os
import signal
import socket
import sys
import threading
import time
import types
import warnings
from collections import namedtuple
from contextlib import ExitStack
from _thread import interrupt_main
from IPython import get_ipython

try:
    from plot_viewer import create_runtime as _plot_create_runtime
except Exception:
    _plot_create_runtime = None

try:
    from IPython.core.completer import (
        ProvisionalCompleterWarning,
        provisionalcompleter,
    )
except Exception:
    ProvisionalCompleterWarning = None
    provisionalcompleter = None


_CONTROL_COMM_NAME = "ipybridge.control"


def _myipy_prepare_control_handlers():
    """Ensure control channel forwards comm messages to the comm manager."""
    kernel = _myipy_get_kernel()
    if kernel is None:
        _ipy_log_debug("control handlers setup skipped: kernel missing")
        return False
    handlers = getattr(kernel, "control_handlers", None)
    manager = getattr(kernel, "comm_manager", None)
    if not isinstance(handlers, dict) or manager is None:
        _ipy_log_debug("control handlers setup skipped: prerequisites missing")
        return False
    updated = False
    for name in ("comm_open", "comm_msg", "comm_close"):
        handler = getattr(manager, name, None)
        if handler is None:
            continue
        if handlers.get(name) is handler:
            continue
        handlers[name] = handler
        updated = True
    if not updated:
        return True
    _ipy_log_debug("control handlers updated for comm messages")
    return True


_PREVIEW_LIMITS = {"rows": 30, "cols": 20}

# Track baseline object ids captured at debug start so stale globals stay hidden.
_DEBUG_BASELINE = {}
_DEBUGFILE_IMPORTS = ""

_BREAKPOINT_FILE_ENV = "IPYBRIDGE_BREAKPOINT_FILE"
_BREAKPOINT_STATE = {"path": None, "signature": None, "data": {}}
_BREAKPOINT_STATE_LOCK = threading.Lock()
_BREAKPOINT_WATCHER_STARTED = False


def _debug_baseline_snapshot(namespace):
    if not isinstance(namespace, dict):
        return {}
    snapshot = {}
    for name, value in namespace.items():
        if not isinstance(name, str):
            continue
        try:
            snapshot[name] = id(value)
        except Exception:
            continue
    return snapshot


def _filter_debug_baseline(namespace):
    if not _DEBUG_BASELINE or not isinstance(namespace, dict):
        return namespace
    filtered = {}
    for name, value in namespace.items():
        baseline_id = _DEBUG_BASELINE.get(name)
        if baseline_id is not None:
            try:
                if id(value) == baseline_id:
                    continue
            except Exception:
                pass
        filtered[name] = value
    return filtered


def _myipy_reset_debug_baseline(frame=None):
    try:
        namespace = _myipy_current_namespace(frame)
    except Exception:
        namespace = {}
    if not isinstance(namespace, dict):
        namespace = {}
    _DEBUG_BASELINE.clear()
    _DEBUG_BASELINE.update(_debug_baseline_snapshot(namespace))


def _myipy_set_debugfile_imports(import_block):
    global _DEBUGFILE_IMPORTS
    if not isinstance(import_block, str):
        import_block = ""
    _DEBUGFILE_IMPORTS = import_block.strip()


def _myipy_get_debugfile_imports():
    return _DEBUGFILE_IMPORTS


def _myipy_normalize_breakpoints(raw):
    result = {}
    if isinstance(raw, dict):
        for raw_path, entries in raw.items():
            if not isinstance(raw_path, str):
                continue
            try:
                norm_path = os.path.abspath(raw_path)
            except Exception:
                norm_path = raw_path
            collected = {}
            source = entries
            if isinstance(entries, dict):
                source = list(entries.values())
            if isinstance(source, (list, tuple, set)):
                for entry in source:
                    line_no = None
                    condition = None
                    if isinstance(entry, dict):
                        try:
                            line_no = int(entry.get("line"))
                        except Exception:
                            continue
                        if not line_no or line_no <= 0:
                            continue
                        cond_val = entry.get("condition")
                        if isinstance(cond_val, str):
                            cond_val = cond_val.strip()
                            if cond_val == "":
                                cond_val = None
                        else:
                            cond_val = None
                        condition = cond_val
                    else:
                        try:
                            line_no = int(entry)
                        except Exception:
                            continue
                        if not line_no or line_no <= 0:
                            continue
                    existing = collected.get(line_no)
                    if existing is None:
                        if condition:
                            collected[line_no] = {
                                "line": line_no,
                                "condition": condition,
                            }
                        else:
                            collected[line_no] = {"line": line_no}
                    elif condition:
                        existing["condition"] = condition
            if collected:
                ordered = []
                for line_no in sorted(collected):
                    item = collected[line_no]
                    if not isinstance(item, dict):
                        item = {"line": line_no}
                    if "line" not in item:
                        item = {"line": line_no, "condition": item.get("condition")}
                    ordered.append(item)
                result[norm_path] = ordered
    return result


def _myipy_read_breakpoint_payload(path):
    try:
        with io.open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        text = ""
    except Exception as exc:
        _ipy_log_debug(f"breakpoint file read failed: {exc}")
        with _BREAKPOINT_STATE_LOCK:
            current = dict(_BREAKPOINT_STATE.get("data") or {})
        return current, False
    raw_obj = {}
    if text:
        try:
            raw_obj = json.loads(text)
        except Exception as exc:
            _ipy_log_debug(f"breakpoint file decode failed: {exc}")
            with _BREAKPOINT_STATE_LOCK:
                current = dict(_BREAKPOINT_STATE.get("data") or {})
            return current, False
    normalized = _myipy_normalize_breakpoints(raw_obj)
    signature = json.dumps(
        normalized,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    with _BREAKPOINT_STATE_LOCK:
        changed = signature != _BREAKPOINT_STATE.get("signature")
        _BREAKPOINT_STATE["signature"] = signature
        _BREAKPOINT_STATE["data"] = normalized
    globals()["__ipybridge_breakpoints__"] = normalized
    return normalized, changed


def _myipy_capture_breakpoints():
    path = os.environ.get(_BREAKPOINT_FILE_ENV)
    if not path:
        return {}
    with _BREAKPOINT_STATE_LOCK:
        _BREAKPOINT_STATE["path"] = path
    data, _ = _myipy_read_breakpoint_payload(path)
    return data


def _myipy_apply_breakpoints(payload=None, dbg=None):
    if dbg is None:
        dbg = globals().get("_mi_active_debugger")
    if payload is None:
        with _BREAKPOINT_STATE_LOCK:
            payload = dict(_BREAKPOINT_STATE.get("data") or {})
    if not isinstance(payload, dict):
        payload = {}
    if dbg is None:
        return False
    set_break = getattr(dbg, "set_break", None)
    clear = getattr(dbg, "clear_all_breaks", None)
    success = True
    if callable(clear):
        try:
            clear()
        except Exception as exc:
            _ipy_log_debug(f"debug break clear failed: {exc}")
            success = False
    if not payload:
        return success
    if not callable(set_break):
        return success
    for bp_file, bp_entries in payload.items():
        if isinstance(bp_entries, dict):
            entries = list(bp_entries.values())
        else:
            entries = bp_entries
        if not isinstance(entries, (list, tuple, set)):
            continue
        latest = {}
        for entry in entries:
            line_no = None
            condition = None
            if isinstance(entry, dict):
                try:
                    line_no = int(entry.get("line"))
                except Exception:
                    continue
                if not line_no or line_no <= 0:
                    continue
                cond_val = entry.get("condition")
                if isinstance(cond_val, str):
                    cond_val = cond_val.strip()
                    if cond_val == "":
                        cond_val = None
                else:
                    cond_val = None
                condition = cond_val
            else:
                try:
                    line_no = int(entry)
                except Exception:
                    continue
                if not line_no or line_no <= 0:
                    continue
            latest[line_no] = condition
        for line_no in sorted(latest):
            condition = latest[line_no]
            try:
                if condition:
                    set_break(bp_file, line_no, cond=condition)
                else:
                    set_break(bp_file, line_no)
            except Exception as exc:
                _ipy_log_debug(
                    f"debug breakpoint set failed {bp_file}:{line_no}: {exc}"
                )
                success = False
    return success


def _myipy_breakpoint_watcher_loop(path):
    last_mtime = None
    while True:
        try:
            stat = os.stat(path)
            mtime = getattr(stat, "st_mtime_ns", None)
            if mtime is None:
                mtime = int(stat.st_mtime * 1_000_000_000)
        except FileNotFoundError:
            time.sleep(0.25)
            continue
        except Exception as exc:
            _ipy_log_debug(f"breakpoint stat failed: {exc}")
            time.sleep(0.25)
            continue
        if last_mtime is not None and mtime == last_mtime:
            time.sleep(0.15)
            continue
        last_mtime = mtime
        data, changed = _myipy_read_breakpoint_payload(path)
        if changed:
            try:
                _myipy_apply_breakpoints(payload=data)
            except Exception as exc:
                _ipy_log_debug(f"breakpoint watcher apply failed: {exc}")
        time.sleep(0.15)


def _myipy_start_breakpoint_watcher():
    global _BREAKPOINT_WATCHER_STARTED
    if _BREAKPOINT_WATCHER_STARTED:
        return
    path = _BREAKPOINT_STATE.get("path") or os.environ.get(_BREAKPOINT_FILE_ENV)
    if not path:
        return
    with _BREAKPOINT_STATE_LOCK:
        _BREAKPOINT_STATE["path"] = path
    _myipy_read_breakpoint_payload(path)
    try:
        watcher = threading.Thread(
            target=_myipy_breakpoint_watcher_loop,
            args=(path,),
            name="ipybridge-bp-watch",
            daemon=True,
        )
        watcher.start()
        _BREAKPOINT_WATCHER_STARTED = True
    except Exception as exc:
        _ipy_log_debug(f"breakpoint watcher start failed: {exc}")


def _myipy_register_breakpoints_file(path):
    if not path:
        return False
    try:
        abs_path = os.path.abspath(path)
    except Exception:
        abs_path = path
    try:
        os.environ[_BREAKPOINT_FILE_ENV] = abs_path
    except Exception:
        pass
    with _BREAKPOINT_STATE_LOCK:
        _BREAKPOINT_STATE["path"] = abs_path
    _myipy_read_breakpoint_payload(abs_path)
    _myipy_start_breakpoint_watcher()
    return True


def _myipy_prepare_breakpoints_for_debug(dbg=None):
    if dbg is not None:
        globals()["_mi_active_debugger"] = dbg
    else:
        dbg = globals().get("_mi_active_debugger")
    data = _myipy_capture_breakpoints()
    try:
        _myipy_apply_breakpoints(payload=data, dbg=dbg)
    except Exception as exc:
        _ipy_log_debug(f"debug breakpoint apply failed: {exc}")
    return data


def _coerce_int(value, default):
    try:
        if value is None:
            return default
        return int(value)
    except Exception:
        return default


class _DebugPreviewContext:
    """Track the latest debug namespace and preview limits."""

    __slots__ = ("namespace", "frame", "frame_id", "scoped", "rows", "cols", "globals")

    def __init__(self):
        self.namespace = None
        self.frame = None
        self.frame_id = None
        self.scoped = False
        self.rows = int(_PREVIEW_LIMITS.get("rows") or 30)
        self.cols = int(_PREVIEW_LIMITS.get("cols") or 20)
        self.globals = None

    def capture(self, frame, namespace, rows, cols):
        """Capture the latest debug frame/namespace and preview limits."""
        if frame is not None:
            if isinstance(namespace, dict):
                self.namespace = namespace
            self.frame = frame
            self.frame_id = id(frame)
            self.scoped = True
        else:
            self.scoped = False
            if isinstance(namespace, dict):
                self.globals = namespace
        if frame is None and self.frame is None and isinstance(namespace, dict):
            self.namespace = namespace
        self.rows = _coerce_int(rows, self.rows)
        if self.rows <= 0:
            self.rows = int(_PREVIEW_LIMITS.get("rows") or 30)
        self.cols = _coerce_int(cols, self.cols)
        if self.cols <= 0:
            self.cols = int(_PREVIEW_LIMITS.get("cols") or 20)
        _ipy_log_debug(
            "debug context stored frame_id=%s namespace_items=%s"
            % (
                self.frame_id if self.frame_id is not None else "none",
                len(self.namespace) if isinstance(self.namespace, dict) else 0,
            )
        )

    def compute(self, name, rows=None, cols=None, row_offset=None, col_offset=None):
        """Compute a preview payload for a variable in the captured context."""
        effective_rows = _coerce_int(rows, self.rows)
        effective_cols = _coerce_int(cols, self.cols)
        if effective_rows <= 0:
            effective_rows = self.rows
        if effective_cols <= 0:
            effective_cols = self.cols
        row_base = _coerce_int(row_offset, 0)
        col_base = _coerce_int(col_offset, 0)
        if row_base < 0:
            row_base = 0
        if col_base < 0:
            col_base = 0
        namespace = self.namespace if isinstance(self.namespace, dict) else None
        frame = self.frame if self.frame_id is not None else None
        if namespace is None and frame is not None:
            try:
                rebuilt = _myipy_current_namespace(frame)
            except Exception:
                rebuilt = None
            if isinstance(rebuilt, dict):
                namespace = rebuilt
                self.namespace = rebuilt
        if namespace is None and isinstance(self.globals, dict):
            namespace = self.globals
        if namespace is None:
            try:
                rebuilt = _myipy_current_namespace()
            except Exception:
                rebuilt = None
            if isinstance(rebuilt, dict) and rebuilt:
                namespace = rebuilt
                self.namespace = rebuilt
        if not namespace:
            _ipy_log_debug(
                f"debug preview compute skipped name={name} reason=no-context"
            )
            return {"name": name, "error": "debug namespace unavailable"}
        try:
            payload = _ipy_preview_data(
                name,
                namespace=namespace,
                max_rows=effective_rows,
                max_cols=effective_cols,
                row_offset=row_base,
                col_offset=col_base,
            )
        except Exception as exc:
            payload = {"name": name, "error": f"preview error: {exc}"}
        status = "error" if isinstance(payload, dict) and payload.get("error") else "ok"
        _ipy_log_debug(
            f"debug preview compute name={name} frame_id={self.frame_id} status={status} rows={effective_rows} cols={effective_cols} row_offset={row_base} col_offset={col_base}"
        )
        return payload

    def complete(self, code, cursor_pos=None, debug=True):
        """Proxy debug completions through the in-kernel helper."""
        try:
            payload = _mi_debug_complete_payload(code, cursor_pos, bool(debug))
        except Exception as exc:
            _ipy_log_debug(f"debug completion compute failed: {exc}")
            return False, None, str(exc)
        return True, payload, None


class _DebugPreviewServer:
    """Accept socket requests and serve debug previews on demand."""

    def __init__(self, context):
        self._context = context
        self._socket = None
        self._thread = None
        self._port = None

    @property
    def context(self):
        """Return the active debug preview context."""
        return self._context

    def ensure_running(self):
        """Start the preview server thread if needed and return the port."""
        if self._port:
            return self._port
        try:
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", 0))
            server.listen(5)
        except Exception as exc:
            _ipy_log_debug(f"debug preview server start failed: {exc}")
            return None
        port = server.getsockname()[1]
        if not port or port <= 0:
            _ipy_log_debug("debug preview server yielded invalid port")
            try:
                server.close()
            except Exception:
                pass
            self._socket = None
            return None
        self._socket = server
        thread = threading.Thread(
            target=self._serve, name="ipybridge-debug-preview", daemon=True
        )
        thread.start()
        self._thread = thread
        self._port = port
        _ipy_log_debug(f"debug preview server listening port={port}")
        return port

    def _serve(self):
        server = self._socket
        if server is None:
            return
        while True:
            try:
                conn, _ = server.accept()
            except Exception as exc:
                _ipy_log_debug(f"debug preview server accept failed: {exc}")
                break
            try:
                request = self._read_request(conn)
                if request is None:
                    continue
                payload = self._build_response(request)
                conn.sendall(payload)
            except Exception as exc:
                _ipy_log_debug(f"debug preview server error: {exc}")
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

    def _read_request(self, conn):
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in chunk:
                break
        if not data:
            return None
        try:
            return json.loads(data.decode("utf-8").strip())
        except Exception as exc:
            return {"_error": f"decode error: {exc}"}

    def _build_response(self, request):
        err = request.get("_error") if isinstance(request, dict) else None
        if err:
            result = {"ok": False, "error": err}
        else:
            op = request.get("op") if isinstance(request, dict) else None
            if op in (None, "preview"):
                name = request.get("name")
                rows = request.get("max_rows")
                cols = request.get("max_cols")
                row_offset = request.get("row_offset")
                col_offset = request.get("col_offset")
                data = self._context.compute(name, rows, cols, row_offset, col_offset)
                result = {"ok": True, "data": data}
            elif op == "complete":
                code = request.get("code") or ""
                cursor = request.get("cursor_pos")
                debug = request.get("debug")
                ok, data, err = self._context.complete(code, cursor, debug)
                if ok:
                    result = {"ok": True, "data": data}
                else:
                    result = {"ok": False, "error": err or "debug completion failed"}
            else:
                result = {"ok": False, "error": f"unknown op: {op}"}
        return json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n"

    def compute(self, name, rows=None, cols=None, row_offset=None, col_offset=None):
        return self._context.compute(name, rows, cols, row_offset, col_offset)


_DEBUG_PREVIEW = _DebugPreviewServer(_DebugPreviewContext())

MODULE_B64 = "__MODULE_B64__"


def _myipy_bootstrap_module():
    """Ensure ipybridge_ns is loaded into the kernel."""
    src = base64.b64decode(MODULE_B64).decode("utf-8")
    mod = sys.modules.get("ipybridge_ns")
    if mod is None:
        mod = types.ModuleType("ipybridge_ns")
        exec(compile(src, "<ipybridge_ns>", "exec"), mod.__dict__)
        sys.modules["ipybridge_ns"] = mod
    return mod


_ipy_mod = _myipy_bootstrap_module()
from ipybridge_ns import (
    collect_namespace as _ipy_collect_namespace,
    get_var_filters as _ipy_get_var_filters,
    list_variables as _ipy_list_variables,
    log_debug as _ipy_log_debug,
    preview_data as _ipy_preview_data,
    set_debug_logging as _ipy_set_debug_logging,
    set_var_filters as _ipy_set_var_filters,
    resolve_path as _ipy_resolve_path,
)


def _myipy_get_kernel():
    """Return the currently active IPykernel instance, if any."""
    try:
        ipy = get_ipython()
    except Exception:
        return None
    if ipy is None:
        return None
    return getattr(ipy, "kernel", None)


def _myipy_raise_interrupt_signal():
    """Attempt to interrupt the main execution thread."""
    kernel = _myipy_get_kernel()
    if kernel is None:
        _ipy_log_debug("interrupt request ignored: kernel unavailable")
        return False

    if os.name == "nt":
        handler = signal.getsignal(signal.SIGINT)
        if callable(handler):
            try:
                interrupt_main()
                return True
            except Exception as exc:
                _ipy_log_debug(f"interrupt_main failed: {exc}")
                return False
        _ipy_log_debug("interrupt request ignored: SIGINT handler not callable")
        return False

    sender = getattr(kernel, "_send_interupt_children", None)
    if sender is None:
        sender = getattr(kernel, "_send_interrupt_children", None)
    if sender is None:
        try:
            os.kill(os.getpid(), signal.SIGINT)
            return True
        except Exception as exc:
            _ipy_log_debug(f"interrupt fallback failed: {exc}")
            return False

    try:
        sender()
        return True
    except Exception as exc:
        _ipy_log_debug(f"interrupt send failed: {exc}")
        try:
            os.kill(os.getpid(), signal.SIGINT)
            return True
        except Exception as fallback_exc:
            _ipy_log_debug(f"interrupt os.kill fallback failed: {fallback_exc}")
            return False


def _myipy_control_comm_open(comm, _msg):
    """Register handlers for a newly opened control comm."""
    reply_lock = threading.Lock()

    def send_response(payload):
        """Send a response to the frontend, guarding against double sends."""
        try:
            with reply_lock:
                comm.send({"response": payload})
        except Exception as exc:
            _ipy_log_debug(f"control comm reply failed: {exc}")

    def handle_request(data):
        request = data.get("request")
        request_id = data.get("request_id")
        if request == "interrupt":
            ok = _myipy_raise_interrupt_signal()
            send_response(
                {
                    "request": request,
                    "request_id": request_id,
                    "ok": bool(ok),
                }
            )
            return
        if request == "ping":
            send_response(
                {
                    "request": request,
                    "request_id": request_id,
                    "ok": True,
                }
            )
            return
        send_response(
            {
                "request": request,
                "request_id": request_id,
                "ok": False,
                "error": "unknown request",
            }
        )

    def on_msg(msg):
        try:
            content = msg.get("content") or {}
            data = content.get("data") or {}
        except Exception:
            data = {}
        handle_request(data)

    try:
        comm.on_msg(on_msg)
        comm.on_close(lambda *_: None)
    except Exception as exc:
        _ipy_log_debug(f"control comm setup failed: {exc}")


def _myipy_register_control_comm():
    """Register the control comm target used by the frontend."""
    kernel = _myipy_get_kernel()
    if kernel is None:
        _ipy_log_debug("control comm registration skipped: kernel missing")
        return False
    manager = getattr(kernel, "comm_manager", None)
    if manager is None:
        _ipy_log_debug("control comm registration skipped: comm manager missing")
        return False
    _myipy_prepare_control_handlers()
    register = getattr(manager, "register_target", None)
    if callable(register):
        try:
            register(_CONTROL_COMM_NAME, _myipy_control_comm_open)
            return True
        except ValueError:
            return True
        except Exception as exc:
            _ipy_log_debug(f"control comm registration failed: {exc}")
            # Fall through to manual registration
    targets = getattr(manager, "targets", None)
    if isinstance(targets, dict):
        if _CONTROL_COMM_NAME not in targets:
            targets[_CONTROL_COMM_NAME] = _myipy_control_comm_open
        return True
    _ipy_log_debug("control comm registration failed: unknown manager layout")
    return False


_OSC_PREFIX = "\x1b]5379;ipybridge:"
_OSC_SUFFIX = "\x07"


def _myipy_set_debug_logging(enabled):
    try:
        _ipy_set_debug_logging(bool(enabled))
    except Exception as exc:  # pragma: no cover - best effort logging
        _ipy_log_debug(f"set_debug_logging failed: {exc}")


def _myipy_sync_var_filters(names=None, types=None, max_repr=None):
    try:
        _ipy_set_var_filters(names, types, max_repr)
    except Exception as exc:
        _ipy_log_debug(f"sync filters error: {exc}")


def _myipy_emit(tag, payload):
    try:
        body = json.dumps(payload, ensure_ascii=False)
    except Exception as exc:
        body = json.dumps({"error": str(exc)}, ensure_ascii=False)
    try:
        sys.stdout.write(f"{_OSC_PREFIX}{tag}:{body}{_OSC_SUFFIX}")
        sys.stdout.flush()
    except Exception:  # pragma: no cover - terminal write safeguard
        pass


_PLOT_RUNTIME = None


def _plot_runtime():
    global _PLOT_RUNTIME
    if _PLOT_RUNTIME is not None:
        return _PLOT_RUNTIME
    if _plot_create_runtime is None:
        return None
    _PLOT_RUNTIME = _plot_create_runtime(
        lambda payload: _myipy_emit("plot_server", payload)
    )
    return _PLOT_RUNTIME


def _myipy_plot_autocapture(reason=None):
    runtime = _plot_runtime()
    if runtime is None:
        return
    try:
        label = reason or "debug.flush"
        runtime.capture(label)
    except Exception as exc:
        _ipy_log_debug(f"plot autocapture failed: {exc}")


def __mi_plot_enable(options=None):
    runtime = _plot_runtime()
    if runtime is None:
        result = {"status": "stopped", "error": "plot runtime unavailable"}
    else:
        result = runtime.enable(options or {})
    print(json.dumps(result, ensure_ascii=False))
    _myipy_purge_last_history()
    return result


def __mi_plot_disable():
    runtime = _plot_runtime()
    if runtime is None:
        return {"ok": False, "error": "plot runtime unavailable"}

    result = runtime.disable()
    return {"ok": True, "data": result}


def __mi_plot_command(action, payload=None):
    runtime = _plot_runtime()
    if runtime is None:
        result = {"ok": False, "error": "plot runtime unavailable"}
    else:
        result = runtime.handle_command(action, payload or {})
    print(json.dumps(result, ensure_ascii=False))
    _myipy_purge_last_history()
    return result


def _myipy_write_json(path, obj):
    try:
        with io.open(path, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, ensure_ascii=False)
    except Exception as exc:
        _myipy_emit(
            "preview",
            {
                "name": obj.get("name") if isinstance(obj, dict) else None,
                "error": str(exc),
            },
        )


_DEBUG_PREVIEW = _DebugPreviewServer(_DebugPreviewContext())

MODULE_B64 = "__MODULE_B64__"


def _myipy_bootstrap_module():
    """Ensure ipybridge_ns is loaded into the kernel."""
    src = base64.b64decode(MODULE_B64).decode("utf-8")
    mod = sys.modules.get("ipybridge_ns")
    if mod is None:
        mod = types.ModuleType("ipybridge_ns")
        exec(compile(src, "<ipybridge_ns>", "exec"), mod.__dict__)
        sys.modules["ipybridge_ns"] = mod
    return mod


_ipy_mod = _myipy_bootstrap_module()

_OSC_PREFIX = "\x1b]5379;ipybridge:"
_OSC_SUFFIX = "\x07"


def _myipy_set_debug_logging(enabled):
    try:
        _ipy_set_debug_logging(bool(enabled))
    except Exception as exc:  # pragma: no cover - best effort logging
        _ipy_log_debug(f"set_debug_logging failed: {exc}")


def _myipy_sync_var_filters(names=None, types=None, max_repr=None):
    try:
        _ipy_set_var_filters(names, types, max_repr)
    except Exception as exc:
        _ipy_log_debug(f"sync filters error: {exc}")


def _myipy_emit(tag, payload):
    try:
        body = json.dumps(payload, ensure_ascii=False)
    except Exception as exc:
        body = json.dumps({"error": str(exc)}, ensure_ascii=False)
    try:
        sys.stdout.write(f"{_OSC_PREFIX}{tag}:{body}{_OSC_SUFFIX}")
        sys.stdout.flush()
    except Exception:  # pragma: no cover - terminal write safeguard
        pass


def _myipy_write_json(path, obj):
    try:
        with io.open(path, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, ensure_ascii=False)
    except Exception as exc:
        _myipy_emit(
            "preview",
            {
                "name": obj.get("name") if isinstance(obj, dict) else None,
                "error": str(exc),
            },
        )


def _myipy_get_conn_file(__path=None):
    try:
        ip = get_ipython()
        conn = getattr(ip.kernel, "connection_file", None)
    except Exception:
        conn = None
    data = {"connection_file": conn}
    if __path:
        _myipy_write_json(__path, data)
    else:
        _myipy_emit("conn", data)


def _myipy_purge_last_history():
    try:
        ip = get_ipython()
        hm = ip.history_manager
        cursor = hm.db.cursor() if hasattr(hm, "db") else hm.get_db_cursor()
        session = hm.session_number
        cursor.execute("SELECT max(line) FROM input WHERE session=?", (session,))
        row = cursor.fetchone()
        maxline = row[0] if row else None
        if maxline is not None:
            cursor.execute(
                "DELETE FROM input WHERE session=? AND line=?", (session, maxline)
            )
            try:
                hm.db.commit()
            except Exception:
                pass
        if getattr(hm, "input_hist_parsed", None):
            try:
                hm.input_hist_parsed.pop()
            except Exception:
                pass
        if getattr(hm, "input_hist_raw", None):
            try:
                hm.input_hist_raw.pop()
            except Exception:
                pass
    except Exception:
        pass


def _myipy_current_namespace(frame=None):
    if frame is not None:
        glb = getattr(frame, "f_globals", globals())
        loc = getattr(frame, "f_locals", None)
        return _ipy_collect_namespace(glb, loc)
    return _ipy_collect_namespace(globals())


def _myipy_list_vars(max_repr=120, __path=None):
    filters = _ipy_get_var_filters()
    namespace = _myipy_current_namespace()
    data = _ipy_list_variables(
        namespace=namespace,
        max_repr=filters.get("max_repr") or max_repr or 120,
        hide_names=filters.get("names"),
        hide_types=filters.get("types"),
    )
    if __path:
        _myipy_write_json(__path, data)
    else:
        _myipy_emit("vars", data)
    _myipy_purge_last_history()


def _myipy_preview(name, max_rows=50, max_cols=20, __path=None):
    namespace = _myipy_current_namespace()
    data = _ipy_preview_data(
        name, namespace=namespace, max_rows=max_rows, max_cols=max_cols
    )
    if __path:
        _myipy_write_json(__path, data)
    else:
        _myipy_emit("preview", data)
    _myipy_purge_last_history()


def _myipy_emit_debug_vars(frame=None):
    try:
        filters = _ipy_get_var_filters()
        namespace = _myipy_current_namespace(frame)
        globals_ns = None
        locals_ns = None
        locals_data = {}
        globals_data = {}
        max_repr = filters.get("max_repr") or 120
        hide_names = filters.get("names")
        hide_types = filters.get("types")
        frame_locals = None
        frame_globals = None
        if frame is not None:
            try:
                frame_locals = getattr(frame, "f_locals", None)
            except Exception:
                frame_locals = None
            try:
                frame_globals = getattr(frame, "f_globals", None)
            except Exception:
                frame_globals = None
        if frame_locals:
            try:
                frame_locals = dict(frame_locals)
            except Exception:
                pass
            locals_ns = _ipy_collect_namespace(None, frame_locals)
            locals_ns = _filter_debug_baseline(locals_ns)
            locals_data = _ipy_list_variables(
                namespace=locals_ns,
                max_repr=max_repr,
                hide_names=hide_names,
                hide_types=hide_types,
            )
        _ipy_log_debug(
            "debug locals size=%d globals size=%d frame=%s"
            % (
                len(locals_data),
                len(globals_data),
                "yes" if frame is not None else "no",
            )
        )
        globals_ns = _ipy_collect_namespace(
            (frame_globals and dict(frame_globals)) or globals()
        )
        globals_ns = _filter_debug_baseline(globals_ns)
        globals_data = _ipy_list_variables(
            namespace=globals_ns,
            max_repr=max_repr,
            hide_names=hide_names,
            hide_types=hide_types,
        )
        if frame is not None:
            globals_data = {}
        rows = int(_PREVIEW_LIMITS.get("rows") or 30)
        cols = int(_PREVIEW_LIMITS.get("cols") or 20)
        previewable = 0

        def count_previewable(scope_map):
            nonlocal previewable
            for entry in scope_map.values():
                if isinstance(entry, dict) and entry.get("previewable"):
                    previewable += 1

        count_previewable(locals_data)
        count_previewable(globals_data)
        if isinstance(namespace, dict):
            context_ns = namespace
        else:
            context_ns = None
        _DEBUG_PREVIEW.context.capture(frame, context_ns, rows, cols)
        snapshot = {
            "__locals__": locals_data,
            "__globals__": globals_data,
            "__scoped__": bool(frame is not None),
        }
        _ipy_log_debug(
            f"debug vars snapshot count={len(locals_data) + len(globals_data)} previewable={previewable}"
        )
        _myipy_emit("vars", snapshot)
    except Exception as exc:
        _ipy_log_debug(f"emit debug vars failed: {exc}")


def _mi_completion_result(matches, cursor_start, cursor_end, sources=None):
    cursor_start = _coerce_int(cursor_start, cursor_end)
    cursor_end = _coerce_int(cursor_end, cursor_start)
    ordered = []
    if isinstance(matches, (list, tuple)):
        for entry in matches:
            if isinstance(entry, str):
                ordered.append(entry)
    source_map = {}
    if isinstance(sources, dict):
        for key, value in sources.items():
            if isinstance(key, str):
                source_map[key] = value
    items = []
    for match in ordered:
        items.append(
            {
                "text": match,
                "source": source_map.get(match),
            }
        )
    metadata = {}
    if source_map:
        counts = {}
        for match in ordered:
            src = source_map.get(match)
            if not src:
                continue
            counts[src] = counts.get(src, 0) + 1
        if counts:
            metadata["source_counts"] = counts
    return {
        "matches": ordered,
        "cursor_start": cursor_start,
        "cursor_end": cursor_end,
        "metadata": metadata,
        "status": "ok",
        "items": items,
    }


def _mi_pairs_to_result(pairs, cursor_start, cursor_end):
    seen = set()
    ordered = []
    sources = {}
    if isinstance(pairs, (list, tuple)):
        for entry in pairs:
            if not isinstance(entry, tuple) or len(entry) != 2:
                continue
            match, src = entry
            if not isinstance(match, str):
                continue
            if match in seen:
                continue
            seen.add(match)
            ordered.append(match)
            if src:
                sources[match] = src
    return _mi_completion_result(ordered, cursor_start, cursor_end, sources)


def _mi_is_name_or_composed(text):
    if not text or text[0] == ".":
        return False
    try:
        return text.replace(".", "").isidentifier()
    except Exception:
        return False


def _mi_trim_completion_token(text, begidx):
    if not isinstance(text, str):
        return "", begidx
    while text and not _mi_is_name_or_composed(text):
        text = text[1:]
        begidx += 1
    return text, begidx


def _mi_active_shell(dbg=None):
    shell = None
    if dbg is not None:
        shell = getattr(dbg, "shell", None)
    if shell is not None:
        return shell
    try:
        return get_ipython()
    except Exception:
        return None


def _mi_line_at_cursor(code, cursor_pos):
    if not isinstance(code, str):
        code = str(code or "")
    try:
        cursor = int(cursor_pos)
    except Exception:
        cursor = len(code)
    if cursor < 0:
        cursor = 0
    if cursor > len(code):
        cursor = len(code)
    if not code:
        return "", 0
    start = code.rfind("\n", 0, cursor)
    if start == -1:
        start = 0
    else:
        start += 1
    end = code.find("\n", cursor)
    if end == -1:
        end = len(code)
    return code[start:end], start


def _mi_ipython_complete(code, cursor_pos, dbg=None):
    shell = _mi_active_shell(dbg)
    if shell is None:
        return None
    if not isinstance(code, str):
        code = str(code or "")
    cursor_pos = _coerce_int(cursor_pos, len(code))
    set_frame = getattr(shell, "set_completer_frame", None)
    frame_payload = None
    if dbg is not None and callable(set_frame):
        frame = getattr(dbg, "curframe", None)
        frame_locals = getattr(dbg, "curframe_locals", None)
        if frame is not None:
            try:
                if frame_locals:
                    Frame = namedtuple("Frame", ["f_locals", "f_globals"])
                    frame_payload = Frame(frame_locals, getattr(frame, "f_globals", {}))
                else:
                    frame_payload = frame
            except Exception:
                frame_payload = frame

    def _complete_with_jedi():
        completer = getattr(shell, "Completer", None)
        completions_fn = getattr(completer, "completions", None)
        if completer is None or not callable(completions_fn):
            return None
        matches = []
        sources = {}
        seen = set()
        min_start = None
        max_end = None
        try:
            with ExitStack() as stack:
                builtin_trap = getattr(shell, "builtin_trap", None)
                if builtin_trap is not None:
                    try:
                        stack.enter_context(builtin_trap)
                    except Exception:
                        pass
                if provisionalcompleter is not None:
                    try:
                        stack.enter_context(provisionalcompleter())
                    except Exception as exc:
                        if not getattr(
                            _complete_with_jedi, "_provisional_failed", False
                        ):
                            _ipy_log_debug(f"provisional completer unavailable: {exc}")
                            _complete_with_jedi._provisional_failed = True
                with warnings.catch_warnings():
                    if ProvisionalCompleterWarning is not None:
                        warnings.simplefilter("ignore", ProvisionalCompleterWarning)
                    for entry in completions_fn(code, cursor_pos):
                        text = getattr(entry, "text", None)
                        if not isinstance(text, str) or text == "":
                            continue
                        origin = getattr(entry, "_origin", None)
                        if isinstance(origin, str) and origin:
                            sources[text] = origin
                        elif text not in sources:
                            sources[text] = "python"
                        if text in seen:
                            continue
                        seen.add(text)
                        matches.append(text)
                        start = getattr(entry, "start", None)
                        end = getattr(entry, "end", None)
                        if isinstance(start, int):
                            if min_start is None or start < min_start:
                                min_start = start
                        if isinstance(end, int):
                            if max_end is None or end > max_end:
                                max_end = end
        except Exception as exc:
            _ipy_log_debug(f"ipython jedi complete failed: {exc}")
            return None
        if not matches:
            return None
        if min_start is None:
            min_start = cursor_pos
        if max_end is None:
            max_end = cursor_pos
        if min_start < 0:
            min_start = 0
        if max_end < min_start:
            max_end = min_start
        result = _mi_completion_result(matches, min_start, max_end, sources)
        result["sources"] = dict(sources)
        return result

    def _complete_legacy():
        try:
            line, offset = _mi_line_at_cursor(code, cursor_pos)
            line_cursor = cursor_pos - offset
            txt, matches = shell.complete("", line, line_cursor)
            txt = txt or ""
            matches = matches or []
            sources = {}
            for match in matches:
                if isinstance(match, str):
                    sources[match] = "python"
            return {
                "matches": matches,
                "cursor_start": cursor_pos - len(txt),
                "cursor_end": cursor_pos,
                "sources": sources,
            }
        except Exception as exc:
            _ipy_log_debug(f"ipython complete failed: {exc}")
            return None

    modern = None
    try:
        if callable(set_frame):
            set_frame(frame_payload)
        modern = _complete_with_jedi()
    finally:
        if callable(set_frame):
            try:
                set_frame()
            except Exception:
                pass
    if modern is not None:
        return modern
    try:
        if callable(set_frame):
            set_frame(frame_payload)
        return _complete_legacy()
    finally:
        if callable(set_frame):
            try:
                set_frame()
            except Exception:
                pass


def _mi_pdb_complete_default(dbg, code, cursor_pos):
    cursor_pos = _coerce_int(cursor_pos, len(code))
    if not isinstance(code, str):
        code = str(code or "")
    text = code[:cursor_pos].split(" ")[-1]
    origline = code
    line = origline.lstrip()
    if not line:
        return _mi_pairs_to_result([], cursor_pos, cursor_pos)
    stripped = len(origline) - len(line)
    begidx = cursor_pos - len(text) - stripped
    endidx = cursor_pos - stripped
    compfunc = None
    ipython_do_complete = True
    if begidx > 0:
        try:
            cmd, _, _ = dbg.parseline(line)
        except Exception:
            cmd = ""
        if cmd:
            compfunc = getattr(dbg, f"complete_{cmd}", None)
            if compfunc is not None:
                ipython_do_complete = False
    elif line and line[0] != "!":
        compfunc = getattr(dbg, "completenames", None)
    text, begidx = _mi_trim_completion_token(text, begidx)
    pairs = []
    if callable(compfunc):
        try:
            comp_matches = compfunc(text, line, begidx, endidx) or []
        except Exception as exc:
            _ipy_log_debug(f"pdb completion failed: {exc}")
            comp_matches = []
        for match in comp_matches:
            if isinstance(match, str):
                pairs.append((match, "pdb"))
    cursor_start = cursor_pos - len(text)
    if ipython_do_complete:
        ipy_payload = _mi_ipython_complete(code, cursor_pos, dbg)
        if ipy_payload is not None:
            ipy_matches = ipy_payload.get("matches") or []
            ipy_start = ipy_payload.get("cursor_start", cursor_start)
            ipy_sources = ipy_payload.get("sources") or {}
            if not callable(compfunc):
                pairs = []
                for match in ipy_matches:
                    if isinstance(match, str):
                        pairs.append((match, ipy_sources.get(match, "python")))
                return _mi_pairs_to_result(pairs, ipy_start, cursor_pos)
            if cursor_start < ipy_start:
                missing_txt = code[cursor_start:ipy_start]
                ipy_matches = [missing_txt + m for m in ipy_matches]
            elif ipy_start < cursor_start:
                missing_txt = code[ipy_start:cursor_start]
                pairs = [(missing_txt + m, src) for (m, src) in pairs]
                cursor_start = ipy_start
            for match in ipy_matches:
                if not isinstance(match, str):
                    continue
                src = ipy_sources.get(match, "python")
                pairs.append((match, src))
    return _mi_pairs_to_result(pairs, cursor_start, cursor_pos)


def _mi_pdb_complete_exclamation(dbg, code, cursor_pos):
    cursor_pos = _coerce_int(cursor_pos, len(code))
    if not isinstance(code, str):
        code = str(code or "")
    text = code[:cursor_pos].split(" ")[-1]
    origline = code
    line = origline.lstrip()
    if not line:
        return _mi_pairs_to_result([], cursor_pos, cursor_pos)
    is_pdb_command = line[0] == "!"
    stripped = len(origline) - len(line)
    begidx = cursor_pos - len(text) - stripped
    endidx = cursor_pos - stripped
    compfunc = None
    line_body = line
    if is_pdb_command:
        line_body = line[1:]
        begidx -= 1
        endidx -= 1
        if begidx == -1:
            text = text[1:]
            begidx += 1
            compfunc = getattr(dbg, "completenames", None)
        else:
            try:
                cmd, _, _ = dbg.parseline(line_body)
            except Exception:
                cmd = ""
            if not cmd:
                return _mi_pairs_to_result([], cursor_pos, cursor_pos)
            compfunc = getattr(dbg, f"complete_{cmd}", None)
            if compfunc is None:
                return _mi_pairs_to_result([], cursor_pos, cursor_pos)
    text, begidx = _mi_trim_completion_token(text, begidx)
    cursor_start = cursor_pos - len(text)
    if is_pdb_command and callable(compfunc):
        try:
            comp_matches = compfunc(text, line_body, begidx, endidx) or []
        except Exception as exc:
            _ipy_log_debug(f"pdb bang completion failed: {exc}")
            comp_matches = []
        pairs = []
        for match in comp_matches:
            if isinstance(match, str):
                pairs.append((match, "pdb"))
        return _mi_pairs_to_result(pairs, cursor_start, cursor_pos)
    ipy_payload = _mi_ipython_complete(code, cursor_pos, dbg)
    if ipy_payload is None:
        return _mi_pairs_to_result([], cursor_start, cursor_pos)
    matches = ipy_payload.get("matches") or []
    ipy_start = ipy_payload.get("cursor_start", cursor_start)
    ipy_sources = ipy_payload.get("sources") or {}
    if cursor_start < ipy_start:
        missing_txt = code[cursor_start:ipy_start]
        matches = [missing_txt + m for m in matches]
    elif ipy_start < cursor_start:
        missing_txt = code[ipy_start:cursor_start]
        matches = [missing_txt + m for m in matches]
        cursor_start = ipy_start
    pairs = []
    for match in matches:
        if isinstance(match, str):
            pairs.append((match, ipy_sources.get(match, "python")))
    return _mi_pairs_to_result(pairs, cursor_start, cursor_pos)


def _mi_ipython_only_complete(code, cursor_pos, dbg=None):
    payload = _mi_ipython_complete(code, cursor_pos, dbg)
    if payload is None:
        cursor = _coerce_int(cursor_pos, len(code))
        return _mi_pairs_to_result([], cursor, cursor)
    matches = payload.get("matches") or []
    cursor_start = payload.get("cursor_start", cursor_pos)
    cursor_end = payload.get("cursor_end", cursor_pos)
    sources = payload.get("sources") or {}
    return _mi_completion_result(matches, cursor_start, cursor_end, sources)


def _mi_debug_complete_payload(code, cursor_pos=None, debug=True):
    """Return the raw completion payload without sending it to stdout."""
    if not isinstance(code, str):
        code = str(code or "")
    cursor_pos = _coerce_int(cursor_pos, len(code))
    result = None
    dbg = globals().get("_mi_active_debugger") if debug else None
    if dbg is not None:
        try:
            use_bang = bool(getattr(dbg, "pdb_use_exclamation_mark", False))
        except Exception:
            use_bang = False
        try:
            if use_bang:
                result = _mi_pdb_complete_exclamation(dbg, code, cursor_pos)
            else:
                result = _mi_pdb_complete_default(dbg, code, cursor_pos)
        except Exception as exc:
            _ipy_log_debug(f"debug completion failed: {exc}")
            result = None
    if result is None:
        result = _mi_ipython_only_complete(code, cursor_pos, dbg)
    return result


def __mi_debug_complete(code, cursor_pos=None, debug=True):
    result = _mi_debug_complete_payload(code, cursor_pos, debug)
    print(json.dumps(result, ensure_ascii=False))
    _myipy_purge_last_history()


def __mi_debug_preview(name, max_rows=50, max_cols=20, row_offset=0, col_offset=0):
    rows = _coerce_int(max_rows, _PREVIEW_LIMITS.get("rows") or 30)
    cols = _coerce_int(max_cols, _PREVIEW_LIMITS.get("cols") or 20)
    _PREVIEW_LIMITS["rows"] = rows
    _PREVIEW_LIMITS["cols"] = cols
    row_off = _coerce_int(row_offset, 0)
    col_off = _coerce_int(col_offset, 0)
    if row_off < 0:
        row_off = 0
    if col_off < 0:
        col_off = 0
    data = _DEBUG_PREVIEW.compute(name, rows, cols, row_off, col_off)
    print(json.dumps(data, ensure_ascii=False))
    _myipy_purge_last_history()


def __mi_debug_server_info():
    port = _DEBUG_PREVIEW.ensure_running()
    payload = {"port": int(port) if port else None}
    print(json.dumps(payload, ensure_ascii=False))
    _myipy_purge_last_history()


def __mi_set_filters(names=None, types=None, max_repr=None):
    _myipy_sync_var_filters(names, types, max_repr)


def __mi_list_vars(max_repr=120, hide_names=None, hide_types=None):
    __mi_set_filters(hide_names, hide_types, max_repr)
    filters = _ipy_get_var_filters()
    namespace = _myipy_current_namespace()
    data = _ipy_list_variables(
        namespace=namespace,
        max_repr=filters.get("max_repr") or max_repr or 120,
        hide_names=filters.get("names"),
        hide_types=filters.get("types"),
    )
    print(json.dumps(data, ensure_ascii=False))
    _myipy_purge_last_history()


def __mi_preview(name, max_rows=50, max_cols=20, row_offset=0, col_offset=0):
    rows = _coerce_int(max_rows, _PREVIEW_LIMITS.get("rows") or 30)
    cols = _coerce_int(max_cols, _PREVIEW_LIMITS.get("cols") or 20)
    _PREVIEW_LIMITS["rows"] = rows
    _PREVIEW_LIMITS["cols"] = cols
    row_off = _coerce_int(row_offset, 0)
    col_off = _coerce_int(col_offset, 0)
    if row_off < 0:
        row_off = 0
    if col_off < 0:
        col_off = 0
    namespace = _myipy_current_namespace()
    data = _ipy_preview_data(
        name,
        namespace=namespace,
        max_rows=rows,
        max_cols=cols,
        row_offset=row_off,
        col_offset=col_off,
    )
    print(json.dumps(data, ensure_ascii=False))
    _myipy_purge_last_history()


env_bp_path = os.environ.get(_BREAKPOINT_FILE_ENV)
if env_bp_path:
    _myipy_register_breakpoints_file(env_bp_path)
else:
    _myipy_start_breakpoint_watcher()
_myipy_register_control_comm()
_DEBUG_PREVIEW.ensure_running()
