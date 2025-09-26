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

# Stores the most recent debug namespace so previews can be served on demand.
_DEBUG_CONTEXT = {"namespace": None, "frame_id": None, "scoped": False, "rows": None, "cols": None}

# Lightweight TCP server used for on-demand debug previews when the kernel is paused.
_DEBUG_SERVER = {"port": None, "socket": None, "thread": None}

_MAX_CHILD_PREVIEWS = 40

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


def _debug_preview_compute(name, max_rows=None, max_cols=None):
    rows = int(max_rows) if max_rows else int(_PREVIEW_LIMITS.get("rows") or 30)
    cols = int(max_cols) if max_cols else int(_PREVIEW_LIMITS.get("cols") or 20)
    ctx = _DEBUG_CONTEXT if isinstance(_DEBUG_CONTEXT, dict) else {}
    namespace = ctx.get("namespace") if isinstance(ctx.get("namespace"), dict) else None
    frame_id = ctx.get("frame_id")
    if not namespace:
        payload = {"name": name, "error": "debug namespace unavailable"}
        _ipy_log_debug(
            f"debug preview compute skipped name={name} frame_id={frame_id} reason=no-context"
        )
        return payload
    try:
        data = _ipy_preview_data(name, namespace=namespace, max_rows=rows, max_cols=cols)
    except Exception as exc:
        data = {"name": name, "error": f"preview error: {exc}"}
    status = "error" if isinstance(data, dict) and data.get("error") else "ok"
    _ipy_log_debug(
        f"debug preview compute name={name} frame_id={frame_id} status={status} rows={rows} cols={cols}"
    )
    return data


def _debug_preview_loop(server):
    while True:
        try:
            conn, _ = server.accept()
        except Exception as exc:
            _ipy_log_debug(f"debug preview server accept failed: {exc}")
            break
        try:
            raw = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                raw += chunk
                if b"\n" in chunk:
                    break
            if not raw:
                continue
            try:
                request = json.loads(raw.decode("utf-8").strip())
            except Exception as exc:
                response = {"ok": False, "error": f"decode error: {exc}"}
            else:
                name = request.get("name")
                rows = request.get("max_rows")
                cols = request.get("max_cols")
                payload = _debug_preview_compute(name, rows, cols)
                response = {"ok": True, "data": payload}
            conn.sendall(json.dumps(response, ensure_ascii=False).encode("utf-8") + b"\n")
        except Exception as exc:
            _ipy_log_debug(f"debug preview server error: {exc}")
        finally:
            try:
                conn.close()
            except Exception:
                pass


def _ensure_debug_preview_server():
    global _DEBUG_SERVER
    if isinstance(_DEBUG_SERVER, dict) and _DEBUG_SERVER.get("port"):
        return _DEBUG_SERVER.get("port")
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(5)
    except Exception as exc:
        _ipy_log_debug(f"debug preview server start failed: {exc}")
        return None
    port = server.getsockname()[1]
    thread = threading.Thread(
        target=_debug_preview_loop,
        args=(server,),
        name="ipybridge-debug-preview",
        daemon=True,
    )
    thread.start()
    _DEBUG_SERVER = {"port": port, "socket": server, "thread": thread}
    _ipy_log_debug(f"debug preview server listening port={port}")
    return port


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
        global _DEBUG_CONTEXT
        if frame is not None and isinstance(namespace, dict):
            _DEBUG_CONTEXT = {
                "namespace": namespace,
                "frame_id": id(frame),
                "scoped": True,
                "rows": rows,
                "cols": cols,
            }
            ns_size = len(namespace)
            _ipy_log_debug(
                f"debug context stored frame_id={id(frame)} namespace_items={ns_size} cache_entries={len(cache)}"
            )
        else:
            _DEBUG_CONTEXT = {
                "namespace": namespace if isinstance(namespace, dict) else None,
                "frame_id": None,
                "scoped": False,
                "rows": rows,
                "cols": cols,
            }
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


def __mi_debug_preview(name, max_rows=50, max_cols=20):
    data = _debug_preview_compute(name, max_rows, max_cols)
    print(json.dumps(data, ensure_ascii=False))
    _myipy_purge_last_history()


def __mi_debug_server_info():
    port = _ensure_debug_preview_server()
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


def __mi_preview(name, max_rows=50, max_cols=20):
    try:
        _PREVIEW_LIMITS["rows"] = int(max_rows)
    except Exception:
        pass
    try:
        _PREVIEW_LIMITS["cols"] = int(max_cols)
    except Exception:
        pass
    namespace = _myipy_current_namespace()
    data = _ipy_preview_data(name, namespace=namespace, max_rows=max_rows, max_cols=max_cols)
    print(json.dumps(data, ensure_ascii=False))
    _myipy_purge_last_history()


_ensure_debug_preview_server()
