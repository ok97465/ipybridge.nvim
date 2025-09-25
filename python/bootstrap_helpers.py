"""Bootstrap helpers executed inside the target IPython kernel."""

import base64
import io
import json
import os
import sys
import types
from IPython import get_ipython


_PREVIEW_LIMITS = {"rows": 30, "cols": 20}

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


def _child_preview_paths(name, preview):
    if not isinstance(preview, dict):
        return []
    base = name
    out = []
    kind = preview.get("kind")
    if kind == "ctypes":
        for field in preview.get("fields") or []:
            fname = field.get("name")
            if isinstance(fname, str) and fname:
                out.append(f"{base}.{fname}")
    elif kind == "dataclass":
        for field in preview.get("fields") or []:
            fname = field.get("name")
            if isinstance(fname, str) and fname:
                out.append(f"{base}.{fname}")
    elif kind == "dataframe":
        for col in preview.get("columns") or []:
            if isinstance(col, str) and col:
                out.append(f"{base}['{col}']")
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
        data = _ipy_list_variables(
            namespace=namespace,
            max_repr=filters.get("max_repr") or 120,
            hide_names=filters.get("names"),
            hide_types=filters.get("types"),
        )
        rows = int(_PREVIEW_LIMITS.get("rows") or 30)
        cols = int(_PREVIEW_LIMITS.get("cols") or 20)
        previewable = 0
        visited = set()
        cache = {}
        for name, entry in list(data.items()):
            preview = _cache_preview(name, namespace, rows, cols, visited, cache)
            if preview is None:
                continue
            entry["_preview_cache"] = preview
            if isinstance(preview, dict) and not preview.get("error"):
                previewable += 1
            child_map = {}
            queue = list(_child_preview_paths(name, preview))
            while queue:
                child = queue.pop(0)
                child_preview = _cache_preview(child, namespace, rows, cols, visited, cache)
                if child_preview is None:
                    continue
                child_map[child] = child_preview
                for grand in _child_preview_paths(child, child_preview):
                    if grand not in visited:
                        queue.append(grand)
            if child_map:
                entry["_preview_children"] = child_map
        _ipy_log_debug(
            f"debug vars snapshot count={len(data)} previewable={previewable}"
        )
        _myipy_emit("vars", data)
    except Exception as exc:
        _ipy_log_debug(f"emit debug vars failed: {exc}")


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
