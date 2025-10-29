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
_PREVIEWABLE_KINDS = {
    "ndarray",
    "dataframe",
    "dataclass",
    "ctypes",
    "ctypes_array",
    "list",
    "tuple",
    "set",
    "dict",
}
_SEQUENCE_SAMPLE_LIMIT = 5
_MAPPING_SAMPLE_LIMIT = 5


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


def _sequence_materialize(seq: Any, kind: str) -> Tuple[Optional[list], bool]:
    allow_index = kind in {"list", "tuple"}
    try:
        if kind == "list":
            return list(seq), allow_index
        if kind == "tuple":
            return list(seq), allow_index
        if kind == "set":
            values = list(seq)
            try:
                values.sort(key=lambda item: _safe_repr(item, 60))
            except Exception:
                pass
            return values, False
    except Exception:
        return None, allow_index
    return None, allow_index


def _sequence_overview(seq: Any, max_repr: int, kind: str) -> Optional[Dict[str, Any]]:
    materialized, allow_index = _sequence_materialize(seq, kind)
    if materialized is None:
        return None
    try:
        length = len(materialized)
    except Exception:
        return None
    items = []
    previewable_count = 0
    limit = min(length, _SEQUENCE_SAMPLE_LIMIT)
    repr_limit = max(20, min(max_repr, 80))
    for idx in range(limit):
        try:
            value = materialized[idx]
        except Exception:
            items.append({
                "index": idx,
                "type": "?",
                "kind": None,
                "repr": "<unreadable>",
                "previewable": False,
                "path_index": idx if allow_index else None,
            })
            continue
        item_kind, _ = _value_kind(value)
        item_type = type(value).__name__
        item_repr = _safe_repr(value, repr_limit)
        previewable = False
        if allow_index and item_kind in _PREVIEWABLE_KINDS:
            previewable = True
        elif allow_index and item_repr.endswith("..."):
            previewable = True
        entry: Dict[str, Any] = {
            "index": idx,
            "type": item_type,
            "kind": item_kind,
            "repr": item_repr,
            "previewable": previewable if allow_index else False,
            "path_index": idx if allow_index else None,
        }
        try:
            if hasattr(value, "__len__") and not isinstance(value, (str, bytes, dict)):
                entry["length"] = len(value)
        except Exception:
            pass
        items.append(entry)
        if entry["previewable"]:
            previewable_count += 1
    remaining = length - limit
    if remaining > 0:
        items.append({
            "placeholder": True,
            "more": remaining,
        })
    return {
        "length": length,
        "items": items,
        "previewable_count": previewable_count,
        "allow_index": allow_index,
    }


def _sequence_preview_payload(name: str,
                              seq: Any,
                              kind: str,
                              rows_limit: int,
                              row_offset: int,
                              max_cols: int) -> Dict[str, Any]:
    materialized, allow_index = _sequence_materialize(seq, kind)
    if materialized is None:
        return {
            "name": name,
            "kind": "object",
            "sequence_kind": kind,
            "items": [],
            "row_offset": 0,
            "col_offset": 0,
            "max_rows": rows_limit,
            "max_cols": max_cols,
            "previewable_count": 0,
            "repr": _safe_repr(seq, 300),
        }
    try:
        length = len(materialized)
    except Exception:
        length = None
    if length is None:
        return {
            "name": name,
            "kind": "object",
            "sequence_kind": kind,
            "items": [],
            "row_offset": 0,
            "col_offset": 0,
            "max_rows": rows_limit,
            "max_cols": max_cols,
            "previewable_count": 0,
            "repr": _safe_repr(seq, 300),
        }
    row_base = row_offset
    if length > 0 and row_base >= length:
        row_base = max(length - rows_limit, 0)
    if row_base < 0:
        row_base = 0
    end = row_base + rows_limit if rows_limit > 0 else length
    if end > length:
        end = length
    items: list = []
    previewable_count = 0
    repr_limit = max(20, min(120, rows_limit * 8))
    for idx in range(row_base, end):
        try:
            if allow_index:
                value = seq[idx]  # type: ignore[index]
            else:
                value = materialized[idx]
        except Exception:
            items.append({
                "index": idx,
                "type": "?",
                "kind": None,
                "repr": "<unreadable>",
                "previewable": False,
                "path_index": None,
            })
            continue
        item_kind, _ = _value_kind(value)
        item_type = type(value).__name__
        item_repr = _safe_repr(value, repr_limit)
        previewable = False
        if allow_index and item_kind in _PREVIEWABLE_KINDS:
            previewable = True
        elif allow_index and item_repr.endswith("..."):
            previewable = True
        entry = {
            "index": idx,
            "type": item_type,
            "kind": item_kind,
            "repr": item_repr,
            "previewable": previewable if allow_index else False,
            "path_index": idx if allow_index else None,
        }
        items.append(entry)
        if entry["previewable"]:
            previewable_count += 1
    if end < length:
        items.append({
            "placeholder": True,
            "more": length - end,
        })
    payload: Dict[str, Any] = {
        "name": name,
        "kind": "object",
        "sequence_kind": kind,
        "length": length,
        "items": items,
        "row_offset": row_base,
        "col_offset": 0,
        "max_rows": rows_limit,
        "max_cols": max_cols,
        "previewable_count": previewable_count,
        "total_shape": [length],
        "index_paths": allow_index,
        "repr": _safe_repr(seq, 300),
    }
    return payload


def _safe_key_repr(key: Any, limit: int = 60) -> str:
    try:
        rep = repr(key)
    except Exception:
        return "<unrepr>"
    if len(rep) > limit:
        return rep[:limit] + "..."
    return rep


def _format_dict_accessor(key: Any) -> Optional[str]:
    if isinstance(key, str):
        escaped = key.replace("\\", "\\\\").replace("'", "\\'")
        return f"['{escaped}']"
    if isinstance(key, (int, float, bool)):
        return f"[{repr(key)}]"
    return None


def _sorted_mapping_items(mapping: Any) -> Optional[list]:
    try:
        items = list(mapping.items())
    except Exception:
        return None
    decorated = []
    for idx, (key, value) in enumerate(items):
        key_repr = _safe_key_repr(key)
        decorated.append(((key_repr, type(key).__name__, idx), (key, value)))
    decorated.sort(key=lambda item: item[0])
    return [pair for _, pair in decorated]


def _mapping_overview(mapping: Any, max_repr: int) -> Optional[Dict[str, Any]]:
    if not isinstance(mapping, dict):
        return None
    sorted_items = _sorted_mapping_items(mapping)
    if sorted_items is None:
        return None
    length = len(sorted_items)
    preview: list = []
    allow_paths = False
    previewable_count = 0
    limit = min(length, _MAPPING_SAMPLE_LIMIT)
    repr_limit = max(20, min(max_repr, 80))
    for idx in range(limit):
        key, value = sorted_items[idx]
        item_kind, _ = _value_kind(value)
        value_type = type(value).__name__
        value_repr = _safe_repr(value, repr_limit)
        accessor = _format_dict_accessor(key)
        if accessor:
            allow_paths = True
        previewable = bool(accessor) and (
            (item_kind in _PREVIEWABLE_KINDS) or value_repr.endswith("...")
        )
        entry: Dict[str, Any] = {
            "index": idx,
            "key": _safe_key_repr(key),
            "key_type": type(key).__name__,
            "type": value_type,
            "kind": item_kind,
            "repr": value_repr,
            "previewable": previewable,
            "path_accessor": accessor,
        }
        preview.append(entry)
        if previewable:
            previewable_count += 1
    remaining = length - limit
    if remaining > 0:
        preview.append({
            "placeholder": True,
            "more": remaining,
        })
    return {
        "length": length,
        "items": preview,
        "previewable_count": previewable_count,
        "allow_paths": allow_paths,
    }


def _mapping_preview_payload(name: str,
                             mapping: Any,
                             rows_limit: int,
                             row_offset: int,
                             max_cols: int) -> Dict[str, Any]:
    materialized = _sorted_mapping_items(mapping) or []
    length = len(materialized)
    row_base = row_offset
    if length > 0 and row_base >= length:
        row_base = max(length - rows_limit, 0)
    if row_base < 0:
        row_base = 0
    end = row_base + rows_limit if rows_limit > 0 else length
    if end > length:
        end = length
    items: list = []
    previewable_count = 0
    repr_limit = max(20, min(120, rows_limit * 8))
    allow_paths = False
    for idx in range(row_base, end):
        try:
            key, value = materialized[idx]
        except Exception:
            items.append({
                "index": idx,
                "key": "<error>",
                "key_type": "?",
                "type": "?",
                "kind": None,
                "repr": "<unreadable>",
                "previewable": False,
                "path_accessor": None,
            })
            continue
        item_kind, _ = _value_kind(value)
        value_type = type(value).__name__
        value_repr = _safe_repr(value, repr_limit)
        accessor = _format_dict_accessor(key)
        previewable = bool(accessor) and (
            (item_kind in _PREVIEWABLE_KINDS) or value_repr.endswith("...")
        )
        if accessor:
            allow_paths = True
        items.append({
            "index": idx,
            "key": _safe_key_repr(key),
            "key_type": type(key).__name__,
            "type": value_type,
            "kind": item_kind,
            "repr": value_repr,
            "previewable": previewable,
            "path_accessor": accessor,
        })
        if previewable:
            previewable_count += 1
    if end < length:
        items.append({
            "placeholder": True,
            "more": length - end,
        })
    return {
        "name": name,
        "kind": "dict",
        "length": length,
        "items": items,
        "row_offset": row_base,
        "col_offset": 0,
        "max_rows": rows_limit,
        "max_cols": max_cols,
        "previewable_count": previewable_count,
        "total_shape": [length],
        "allow_paths": allow_paths,
    }


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
        if isinstance(value, list):
            return "list", None
        if isinstance(value, tuple):
            return "tuple", None
        if isinstance(value, set):
            return "set", None
        if isinstance(value, dict):
            return "dict", None
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
    if kind in {"list", "tuple", "set"}:
        overview = _sequence_overview(value, max_repr, kind)
        if overview:
            description["length"] = overview.get("length")
            description["sequence_items"] = overview.get("items")
            description["sequence_previewable_count"] = overview.get("previewable_count")
            description["sequence_previewable"] = bool(overview.get("previewable_count"))
            description["sequence_index_paths"] = overview.get("allow_index")
            if kind == "list":
                description["list_items"] = overview.get("items")
                description["previewable_items"] = overview.get("previewable_count")
                description["list_previewable"] = bool(overview.get("previewable_count"))
    elif kind == "dict":
        overview = _mapping_overview(value, max_repr)
        if overview:
            description["length"] = overview.get("length")
            description["mapping_items"] = overview.get("items")
            description["mapping_previewable_count"] = overview.get("previewable_count")
            description["mapping_allow_paths"] = overview.get("allow_paths")
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
                 max_cols: int = 20,
                 row_offset: int = 0,
                 col_offset: int = 0) -> Dict[str, Any]:
    """Build a preview payload for the given variable name."""
    ns = namespace or globals()
    ok, obj, err = resolve_path(name, ns)
    if not ok:
        log_debug(f"preview resolve failed name={name} error={err}")
        return {"name": name, "error": err or "Name not found"}

    log_debug(f"preview building name={name}")
    try:
        rows_limit = int(max_rows)
    except Exception:
        rows_limit = 50
    try:
        cols_limit = int(max_cols)
    except Exception:
        cols_limit = 20
    if rows_limit <= 0:
        rows_limit = 50
    if cols_limit <= 0:
        cols_limit = 20
    try:
        row_offset = int(row_offset or 0)
    except Exception:
        row_offset = 0
    try:
        col_offset = int(col_offset or 0)
    except Exception:
        col_offset = 0
    if row_offset < 0:
        row_offset = 0
    if col_offset < 0:
        col_offset = 0

    pd_mod = _lazy_import("pandas")
    if pd_mod is not None and isinstance(obj, pd_mod.DataFrame):  # type: ignore[attr-defined]
        try:
            total_rows = int(obj.shape[0]) if getattr(obj, "shape", None) else None
            total_cols = int(obj.shape[1]) if getattr(obj, "shape", None) else None
            row_base = row_offset
            col_base = col_offset
            if total_rows is not None and total_rows > 0 and row_base >= total_rows:
                row_base = max(total_rows - rows_limit, 0)
            if total_cols is not None and total_cols > 0 and col_base >= total_cols:
                col_base = max(total_cols - cols_limit, 0)
            row_end = row_base + rows_limit if rows_limit > 0 else None
            col_end = col_base + cols_limit if cols_limit > 0 else None
            frame = obj.iloc[row_base:row_end, col_base:col_end]
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
            payload: Dict[str, Any] = {
                "name": name,
                "kind": "dataframe",
                "shape": [int(frame.shape[0]), int(frame.shape[1])],
                "columns": [str(c) for c in frame.columns.to_list()],
                "rows": rows,
                "row_offset": row_base,
                "col_offset": col_base,
                "max_rows": rows_limit,
                "max_cols": cols_limit,
            }
            if total_rows is not None and total_cols is not None:
                payload["total_shape"] = [total_rows, total_cols]
            return payload
        except Exception as exc:
            return {"name": name, "error": str(exc)}

    np_mod = _lazy_import("numpy")
    if np_mod is not None and isinstance(obj, np_mod.ndarray):  # type: ignore[attr-defined]
        try:
            ndim = int(getattr(obj, "ndim", 0))
            total_shape = list(getattr(obj, "shape", []))
            info: Dict[str, Any] = {
                "name": name,
                "kind": "ndarray",
                "dtype": str(obj.dtype),
                "shape": list(obj.shape),
                "row_offset": row_offset,
                "col_offset": col_offset,
                "max_rows": rows_limit,
                "max_cols": cols_limit,
            }
            if ndim == 1:
                row_base = row_offset
                total_rows = int(total_shape[0]) if total_shape else None
                if total_rows is not None and total_rows > 0 and row_base >= total_rows:
                    row_base = max(total_rows - rows_limit, 0)
                end = row_base + rows_limit if rows_limit > 0 else None
                info["row_offset"] = row_base
                info["values1d"] = obj[row_base:end].tolist()
                info["total_shape"] = total_shape
            elif ndim == 2:
                row_base = row_offset
                col_base = col_offset
                total_rows = int(total_shape[0]) if len(total_shape) >= 1 else None
                total_cols = int(total_shape[1]) if len(total_shape) >= 2 else None
                if total_rows is not None and total_rows > 0 and row_base >= total_rows:
                    row_base = max(total_rows - rows_limit, 0)
                if total_cols is not None and total_cols > 0 and col_base >= total_cols:
                    col_base = max(total_cols - cols_limit, 0)
                row_end = row_base + rows_limit if rows_limit > 0 else None
                col_end = col_base + cols_limit if cols_limit > 0 else None
                info["row_offset"] = row_base
                info["col_offset"] = col_base
                info["rows"] = obj[row_base:row_end, col_base:col_end].tolist()
                info["total_shape"] = total_shape
            else:
                info["repr"] = _safe_repr(obj, 300)
                if total_shape:
                    info["total_shape"] = total_shape
            return info
        except Exception as exc:
            return {"name": name, "error": str(exc)}

    if isinstance(obj, (list, tuple, set)):
        kind = "list"
        if isinstance(obj, tuple):
            kind = "tuple"
        elif isinstance(obj, set):
            kind = "set"
        try:
            return _sequence_preview_payload(name, obj, kind, rows_limit, row_offset, cols_limit)
        except Exception as exc:
            return {"name": name, "error": str(exc)}
    if isinstance(obj, dict):
        try:
            return _mapping_preview_payload(name, obj, rows_limit, row_offset, cols_limit)
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
