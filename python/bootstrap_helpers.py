"""Bootstrap helpers executed inside the target IPython kernel."""

import base64
import io
import json
import os
import socket
import sys
import threading
import types
from IPython import get_ipython


_PREVIEW_LIMITS = {"rows": 30, "cols": 20}

# Number of nested previews to pre-cache per variable; keeps snapshots bounded.
_MAX_CHILD_PREVIEWS = 40


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
            "debug context stored frame_id=%s namespace_items=%s" % (
                self.frame_id if self.frame_id is not None else "none",
                len(self.namespace) if isinstance(self.namespace, dict) else 0,
            )
        )

    def compute(self, name, rows=None, cols=None, row_offset=None, col_offset=None):
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


class _DebugPreviewServer:
    """Accept socket requests and serve debug previews on demand."""

    def __init__(self, context):
        self._context = context
        self._socket = None
        self._thread = None
        self._port = None

    @property
    def context(self):
        return self._context

    def ensure_running(self):
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
            name = request.get("name")
            rows = request.get("max_rows")
            cols = request.get("max_cols")
            row_offset = request.get("row_offset")
            col_offset = request.get("col_offset")
            data = self._context.compute(name, rows, cols, row_offset, col_offset)
            result = {"ok": True, "data": data}
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

_OSC_PREFIX = "\x1b]5379;ipybridge:"
_OSC_SUFFIX = "\x07"


def _cache_preview(name, namespace, rows, cols, visited, cache):
    if not isinstance(name, str) or name == "":
        return None
    if name in cache:
        return cache[name]
    if name in visited:
        return cache.get(name)
    visited.add(name)
    ok, obj, err = _ipy_resolve_path(name, namespace)
    if not ok:
        preview = {"name": name, "error": err or "Name not found"}
    else:
        try:
            preview = _ipy_preview_data(
                name,
                namespace=namespace,
                max_rows=rows,
                max_cols=cols,
            )
        except Exception as exc:
            preview = {"name": name, "error": f"preview error: {exc}"}
    cache[name] = preview
    return preview


def _child_preview_paths(name, preview, remaining):
    if remaining <= 0 or not isinstance(preview, dict):
        return []
    base = name
    out = []
    kind = preview.get("kind")
    if kind in {"ctypes", "dataclass"}:
        for field in preview.get("fields") or []:
            fname = field.get("name")
            if isinstance(fname, str) and fname:
                out.append(f"{base}.{fname}")
                if len(out) >= remaining:
                    break
    elif kind == "dataframe":
        cols = preview.get("columns") or []
        for col in cols:
            if not isinstance(col, str) or not col:
                continue
            out.append(f"{base}['{col}']")
            if len(out) >= remaining:
                break
    return out


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
        _myipy_emit("preview", {"name": obj.get("name") if isinstance(obj, dict) else None, "error": str(exc)})


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

_OSC_PREFIX = "\x1b]5379;ipybridge:"
_OSC_SUFFIX = "\x07"


def _cache_preview(name, namespace, rows, cols, visited, cache):
    if not isinstance(name, str) or name == "":
        return None
    if name in cache:
        return cache[name]
    if name in visited:
        return cache.get(name)
    visited.add(name)
    ok, obj, err = _ipy_resolve_path(name, namespace)
    if not ok:
        preview = {"name": name, "error": err or "Name not found"}
    else:
        try:
            preview = _ipy_preview_data(
                name,
                namespace=namespace,
                max_rows=rows,
                max_cols=cols,
            )
        except Exception as exc:
            preview = {"name": name, "error": f"preview error: {exc}"}
    cache[name] = preview
    return preview


def _child_preview_paths(name, preview, remaining):
    if remaining <= 0 or not isinstance(preview, dict):
        return []
    base = name
    out = []
    kind = preview.get("kind")
    if kind in {"ctypes", "dataclass"}:
        for field in preview.get("fields") or []:
            fname = field.get("name")
            if isinstance(fname, str) and fname:
                out.append(f"{base}.{fname}")
                if len(out) >= remaining:
                    break
    elif kind == "dataframe":
        cols = preview.get("columns") or []
        for col in cols:
            if not isinstance(col, str) or not col:
                continue
            out.append(f"{base}['{col}']")
            if len(out) >= remaining:
                break
    return out


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
        _myipy_emit("preview", {"name": obj.get("name") if isinstance(obj, dict) else None, "error": str(exc)})


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
            cursor.execute("DELETE FROM input WHERE session=? AND line=?", (session, maxline))
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
    data = _ipy_preview_data(name, namespace=namespace, max_rows=max_rows, max_cols=max_cols)
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
            locals_data = _ipy_list_variables(
                namespace=locals_ns,
                max_repr=max_repr,
                hide_names=hide_names,
                hide_types=hide_types,
            )
        _ipy_log_debug(
            "debug locals size=%d globals size=%d frame=%s" % (
                len(locals_data),
                len(globals_data),
                'yes' if frame is not None else 'no',
            )
        )
        globals_ns = _ipy_collect_namespace((frame_globals and dict(frame_globals)) or globals())
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
        visited = set()
        cache = {}

        def enrich(scope_map):
            nonlocal previewable
            for name, entry in list(scope_map.items()):
                preview = _cache_preview(name, namespace, rows, cols, visited, cache)
                if preview is None:
                    continue
                entry["_preview_cache"] = preview
                if isinstance(preview, dict) and not preview.get("error"):
                    previewable += 1
                remaining = _MAX_CHILD_PREVIEWS
                child_map = {}
                # Breadth-first drill-down collects a bounded set of nested previews.
                queue = list(_child_preview_paths(name, preview, remaining))
                while queue and remaining > 0:
                    child = queue.pop(0)
                    child_preview = _cache_preview(child, namespace, rows, cols, visited, cache)
                    if child_preview is None:
                        continue
                    child_map[child] = child_preview
                    remaining -= 1
                    extra = _child_preview_paths(child, child_preview, remaining)
                    for grand in extra:
                        if grand not in visited and grand not in queue:
                            queue.append(grand)
                if child_map:
                    entry["_preview_children"] = child_map

        enrich(locals_data)
        enrich(globals_data)
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


_DEBUG_PREVIEW.ensure_running()
