"""Shared variable explorer helpers for ipybridge.nvim."""

from __future__ import annotations

import dataclasses
import sys
import types
from typing import Any, Dict, Iterable, Mapping, Optional, Tuple

__all__ = [
    "collect_namespace",
    "get_var_filters",
    "list_variables",
    "log_debug",
    "preview_data",
    "resolve_path",
    "set_debug_logging",
    "set_var_filters",
]

_EXCLUDED_NAMES = {"In", "Out", "exit", "quit", "get_ipython"}

_SENTINEL = object()
_NUMPY: Any = _SENTINEL
_PANDAS: Any = _SENTINEL
_CTYPES: Any = _SENTINEL
_DEBUG_LOG = False
_FILTERS = {"names": None, "types": None, "max_repr": 120}


def _lazy_import(holder: str):
    global _NUMPY, _PANDAS, _CTYPES
    if holder == "numpy":
        if _NUMPY is _SENTINEL:
            try:
                import numpy as np  # type: ignore

                _NUMPY = np
            except Exception:
                _NUMPY = None
        return _NUMPY
    if holder == "pandas":
        if _PANDAS is _SENTINEL:
            try:
                import pandas as pd  # type: ignore

                _PANDAS = pd
            except Exception:
                _PANDAS = None
        return _PANDAS
    if holder == "ctypes":
        if _CTYPES is _SENTINEL:
            try:
                import ctypes  # type: ignore

                _CTYPES = ctypes
            except Exception:
                _CTYPES = None
        return _CTYPES
    return None


def set_debug_logging(enabled: bool) -> None:
    """Enable or disable stderr debug logging."""
    global _DEBUG_LOG
    _DEBUG_LOG = bool(enabled)
    if _DEBUG_LOG:
        log_debug("debug logging enabled")


def log_debug(message: str) -> None:
    """Emit a small debug message when logging is enabled."""
    if not _DEBUG_LOG:
        return
    try:
        sys.stderr.write(f"[ipybridge.ns] {message}\n")
        sys.stderr.flush()
    except Exception:
        pass


def set_var_filters(names: Optional[Iterable[str]] = None,
                    types_: Optional[Iterable[str]] = None,
                    max_repr: Optional[int] = None) -> None:
    """Update variable filtering preferences used by list/preview helpers."""
    if names is not None:
        _FILTERS["names"] = list(names)
    if types_ is not None:
        _FILTERS["types"] = list(types_)
    if max_repr is not None and max_repr > 0:
        _FILTERS["max_repr"] = int(max_repr)
    name_count = len(_FILTERS["names"]) if _FILTERS["names"] else 0
    type_count = len(_FILTERS["types"]) if _FILTERS["types"] else 0
    log_debug(
        f"filters updated names={name_count} types={type_count} max_repr={_FILTERS['max_repr']}"
    )


def get_var_filters() -> Dict[str, Any]:
    """Return a shallow copy of the current filters."""
    return {
        "names": list(_FILTERS["names"]) if _FILTERS["names"] else None,
        "types": list(_FILTERS["types"]) if _FILTERS["types"] else None,
        "max_repr": _FILTERS["max_repr"],
    }


def collect_namespace(globals_dict: Optional[Mapping[str, Any]] = None,
                      locals_dict: Optional[Mapping[str, Any]] = None,
                      extra: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """Merge the provided mappings into a new namespace dictionary."""
    namespace: Dict[str, Any] = {}
    if globals_dict:
        namespace.update(globals_dict)
    if locals_dict:
        namespace.update(locals_dict)
    if extra:
        namespace.update(extra)
    return namespace


def _match(name: str, patterns: Optional[Iterable[str]]) -> bool:
    if not patterns:
        return False
    try:
        for pattern in patterns:
            if not isinstance(pattern, str):
                continue
            if pattern.endswith("*"):
                if name.startswith(pattern[:-1]):
                    return True
            elif name == pattern:
                return True
    except Exception:
        return False
    return False


def _safe_repr(value: Any, limit: int) -> str:
    try:
        rep = repr(value)
    except Exception:
        return "<unrepr>"
    if len(rep) > limit:
        return rep[:limit] + "..."
    return rep


def _shape(value: Any) -> Optional[list]:
    try:
        np_mod = _lazy_import("numpy")
        if np_mod is not None and isinstance(value, np_mod.ndarray):  # type: ignore[attr-defined]
            return list(getattr(value, "shape", []))
        pd_mod = _lazy_import("pandas")
        if pd_mod is not None and isinstance(value, pd_mod.DataFrame):  # type: ignore[attr-defined]
            return [int(value.shape[0]), int(value.shape[1])]
        if hasattr(value, "__len__") and not isinstance(value, (str, bytes, dict)):
            return [len(value)]
    except Exception:
        return None
    return None


def _value_kind(value: Any) -> Tuple[Optional[str], Optional[str]]:
    kind: Optional[str] = None
    dtype: Optional[str] = None
    try:
        np_mod = _lazy_import("numpy")
        if np_mod is not None and isinstance(value, np_mod.ndarray):  # type: ignore[attr-defined]
            kind = "ndarray"
            try:
                dtype = str(value.dtype)
            except Exception:
                dtype = None
            return kind, dtype
        pd_mod = _lazy_import("pandas")
        if pd_mod is not None and isinstance(value, pd_mod.DataFrame):  # type: ignore[attr-defined]
            kind = "dataframe"
            try:
                dtype = str(value.dtypes.to_dict())
            except Exception:
                dtype = None
            return kind, dtype
        if dataclasses.is_dataclass(value):
            return "dataclass", None
        ctypes_mod = _lazy_import("ctypes")
        if ctypes_mod is not None:
            if isinstance(value, ctypes_mod.Structure):  # type: ignore[attr-defined]
                return "ctypes", None
            if isinstance(value, ctypes_mod.Array):  # type: ignore[attr-defined]
                return "ctypes_array", None
    except Exception:
        return None, None
    return kind, dtype


def _should_skip_value(value: Any) -> bool:
    if isinstance(value, (types.ModuleType, types.FunctionType, type)):
        return True
    try:
        if callable(value):
            return True
    except Exception:
        return False
    return False


def _describe_value(value: Any, max_repr: int) -> Dict[str, Any]:
    value_type = type(value).__name__
    kind, dtype = _value_kind(value)
    description: Dict[str, Any] = {
        "type": value_type,
        "shape": _shape(value),
        "dtype": dtype,
        "repr": _safe_repr(value, max_repr),
    }
    if kind:
        description["kind"] = kind
    return description


def list_variables(namespace: Optional[Mapping[str, Any]] = None,
                   max_repr: Optional[int] = None,
                   hide_names: Optional[Iterable[str]] = None,
                   hide_types: Optional[Iterable[str]] = None) -> Dict[str, Dict[str, Any]]:
    """List user variables from the provided namespace."""
    max_repr_val = max_repr or _FILTERS["max_repr"]
    ns = namespace or {}
    hidden_names = hide_names if hide_names is not None else _FILTERS["names"]
    hidden_types = hide_types if hide_types is not None else _FILTERS["types"]
    out: Dict[str, Dict[str, Any]] = {}
    log_debug(f"listing variables from namespace size={len(ns)}")
    for name, value in ns.items():
        if not isinstance(name, str):
            continue
        if name.startswith("_") or name in _EXCLUDED_NAMES:
            continue
        if _match(name, hidden_names):
            continue
        if _should_skip_value(value):
            continue
        value_type = type(value).__name__
        if _match(value_type, hidden_types):
            continue
        out[name] = _describe_value(value, max_repr_val)
    log_debug(f"variables listed count={len(out)}")
    return out


def resolve_path(path: str,
                 namespace: Optional[Mapping[str, Any]] = None) -> Tuple[bool, Any, Optional[str]]:
    """Resolve a dotted/indexed path inside the given namespace."""
    ns = namespace or globals()
    if not isinstance(path, str):
        return False, None, "path is not a string"

    s = path.strip()
    length = len(s)
    idx = 0

    def _is_ident_char(ch: str) -> bool:
        return ch.isalnum() or ch == "_"

    def _read_ident(start: int) -> Tuple[Optional[str], int]:
        pos = start
        while pos < length and _is_ident_char(s[pos]):
            pos += 1
        if pos == start:
            return None, start
        return s[start:pos], pos

    name, idx = _read_ident(idx)
    if not name:
        return False, None, "invalid start"
    if name not in ns:
        return False, None, "Name not found"
    current = ns[name]

    while idx < length:
        ch = s[idx]
        if ch.isspace():
            idx += 1
            continue
        if ch == ".":
            idx += 1
            ident, idx = _read_ident(idx)
            if not ident:
                return False, None, "invalid attribute"
            try:
                current = getattr(current, ident)
            except Exception as exc:
                return False, None, str(exc)
            continue
        if ch == "[":
            idx += 1
            if idx >= length:
                return False, None, "missing ]"
            if s[idx] in "'\"":
                quote = s[idx]
                idx += 1
                buf = []
                while idx < length:
                    c = s[idx]
                    if c == "\\" and idx + 1 < length:
                        buf.append(s[idx + 1])
                        idx += 2
                        continue
                    if c == quote:
                        break
                    buf.append(c)
                    idx += 1
                if idx >= length or s[idx] != quote:
                    return False, None, "unterminated string key"
                key: Any = "".join(buf)
                idx += 1
            else:
                start = idx
                if s[start:start + 1] == "-":
                    start += 1
                while idx < length and s[idx].isdigit():
                    idx += 1
                if idx == start:
                    return False, None, "invalid index"
                key = int(s[start:idx])
            if idx >= length or s[idx] != "]":
                return False, None, "missing ]"
            idx += 1
            try:
                current = current[key]
            except Exception as exc:
                return False, None, str(exc)
            continue
        return False, None, "invalid character"
    return True, current, None


def _dataclass_preview(obj: Any, max_cols: int) -> Dict[str, Any]:
    items = []
    for field in dataclasses.fields(obj):
        entry: Dict[str, Any] = {"name": field.name, "type": getattr(field.type, "__name__", str(field.type))}
        try:
            value = getattr(obj, field.name)
        except Exception:
            entry["kind"] = "value"
            entry["repr"] = "<unreadable>"
            items.append(entry)
            continue
        kind, dtype = _value_kind(value)
        if kind == "ndarray":
            entry.update({
                "kind": kind,
                "shape": _shape(value),
                "dtype": dtype,
            })
        elif kind == "dataframe":
            entry.update({
                "kind": kind,
                "shape": _shape(value),
            })
        else:
            entry["kind"] = "value"
            entry["repr"] = _safe_repr(value, 120)
        items.append(entry)
    return {
        "kind": "dataclass",
        "class_name": type(obj).__name__,
        "fields": items,
    }


def _ctypes_structure_preview(obj: Any, max_cols: int) -> Dict[str, Any]:
    ctypes_mod = _lazy_import("ctypes")
    assert ctypes_mod is not None

    def _ctype_name(t: Any) -> str:
        try:
            return getattr(t, "__name__", str(t))
        except Exception:
            return str(t)

    def _array_elt_type(array_type: Any) -> Any:
        return getattr(array_type, "_type_", None)

    def _unbox(value: Any, depth: int = 0) -> Any:
        if depth > 5:
            return "<depth limit>"
        try:
            if isinstance(value, ctypes_mod.Array):  # type: ignore[attr-defined]
                result = []
                length = len(value)
                limit = max_cols
                for index in range(min(length, limit)):
                    result.append(_unbox(value[index], depth + 1))
                if length > limit:
                    result.append(f"...(+{length - limit} more)")
                return result
            if isinstance(value, ctypes_mod.Structure):  # type: ignore[attr-defined]
                out = {}
                for fname, _ in getattr(value, "_fields_", []) or []:
                    try:
                        field_value = getattr(value, fname)
                    except Exception:
                        field_value = "<unreadable>"
                    out[str(fname)] = _unbox(field_value, depth + 1)
                return out
            if hasattr(value, "value"):
                return getattr(value, "value")
            if isinstance(value, (str, int, float, bool)) or value is None:
                return value
            return _safe_repr(value, 120)
        except Exception:
            return "<error>"

    fields = []
    for fname, ftype in getattr(obj, "_fields_", []) or []:
        entry: Dict[str, Any] = {
            "name": str(fname),
            "ctype": _ctype_name(ftype),
        }
        try:
            raw_value = getattr(obj, fname)
        except Exception:
            entry["kind"] = "unknown"
            entry["value"] = "<unreadable>"
            fields.append(entry)
            continue
        if isinstance(raw_value, ctypes_mod.Array):  # type: ignore[attr-defined]
            entry["kind"] = "array"
            entry["length"] = int(len(raw_value))
            entry["values"] = _unbox(raw_value)
            entry["elem_ctype"] = _ctype_name(_array_elt_type(ftype))
        elif isinstance(raw_value, ctypes_mod.Structure):  # type: ignore[attr-defined]
            entry["kind"] = "struct"
            entry["value"] = _unbox(raw_value)
        else:
            entry["kind"] = "scalar"
            entry["value"] = _unbox(raw_value)
        fields.append(entry)
    return {
        "kind": "ctypes",
        "struct_name": type(obj).__name__,
        "fields": fields,
    }


def _ctypes_array_preview(obj: Any, max_rows: int) -> Dict[str, Any]:
    length = int(len(obj))
    values = []
    limit = max_rows
    for index in range(min(length, limit)):
        elem = obj[index]
        try:
            values.append(getattr(elem, "value"))
        except Exception:
            values.append(elem)
    if length > limit:
        values.append(f"...(+{length - limit} more)")
    return {
        "kind": "ctypes_array",
        "ctype": getattr(type(obj), "__name__", str(type(obj))),
        "length": length,
        "values": values,
    }


def preview_data(name: str,
                 namespace: Optional[Mapping[str, Any]] = None,
                 max_rows: int = 50,
                 max_cols: int = 20) -> Dict[str, Any]:
    """Build a preview payload for the given variable name."""
    ns = namespace or globals()
    ok, obj, err = resolve_path(name, ns)
    if not ok:
        log_debug(f"preview resolve failed name={name} error={err}")
        return {"name": name, "error": err or "Name not found"}

    log_debug(f"preview building name={name}")
    pd_mod = _lazy_import("pandas")
    if pd_mod is not None and isinstance(obj, pd_mod.DataFrame):  # type: ignore[attr-defined]
        try:
            frame = obj.iloc[:max_rows, :max_cols]
            rows = []
            for row in frame.itertuples(index=False, name=None):
                converted = []
                for value in row:
                    if pd_mod.isna(value):
                        converted.append(None)
                    elif isinstance(value, (int, float, bool)):
                        converted.append(value)
                    else:
                        converted.append(str(value))
                rows.append(converted)
            return {
                "name": name,
                "kind": "dataframe",
                "shape": [int(frame.shape[0]), int(frame.shape[1])],
                "columns": [str(c) for c in frame.columns.to_list()],
                "rows": rows,
            }
        except Exception as exc:
            return {"name": name, "error": str(exc)}

    np_mod = _lazy_import("numpy")
    if np_mod is not None and isinstance(obj, np_mod.ndarray):  # type: ignore[attr-defined]
        try:
            info: Dict[str, Any] = {
                "name": name,
                "kind": "ndarray",
                "dtype": str(obj.dtype),
                "shape": list(obj.shape),
            }
            if getattr(obj, "ndim", 0) == 1:
                info["values1d"] = obj[:max_rows].tolist()
            elif getattr(obj, "ndim", 0) == 2:
                info["rows"] = obj[:max_rows, :max_cols].tolist()
            else:
                info["repr"] = _safe_repr(obj, 300)
            return info
        except Exception as exc:
            return {"name": name, "error": str(exc)}

    if dataclasses.is_dataclass(obj):
        try:
            data = _dataclass_preview(obj, max_cols)
            data["name"] = name
            return data
        except Exception as exc:
            return {"name": name, "error": f"dataclass error: {exc}"}

    ctypes_mod = _lazy_import("ctypes")
    if ctypes_mod is not None:
        if isinstance(obj, ctypes_mod.Structure):  # type: ignore[attr-defined]
            try:
                data = _ctypes_structure_preview(obj, max_cols)
                data["name"] = name
                return data
            except Exception as exc:
                return {"name": name, "error": f"ctypes inspect error: {exc}"}
        if isinstance(obj, ctypes_mod.Array):  # type: ignore[attr-defined]
            try:
                data = _ctypes_array_preview(obj, max_rows)
                data["name"] = name
                return data
            except Exception as exc:
                return {"name": name, "error": f"ctypes error: {exc}"}

    return {
        "name": name,
        "kind": "object",
        "repr": _safe_repr(obj, 300),
    }


# Eagerly ensure filters dict is initialized
set_var_filters(None, None, _FILTERS["max_repr"])
