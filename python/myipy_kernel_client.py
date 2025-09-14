#!/usr/bin/env python3
import sys, json, argparse, time

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--conn-file', required=True)
    p.add_argument('--debug', action='store_true')
    opts = p.parse_args()

    try:
        from jupyter_client import BlockingKernelClient
    except Exception as e:
        sys.stdout.write(json.dumps({"id":"0","ok":False,"error":"jupyter_client missing"})+"\n")
        sys.stdout.flush()
        return 1

    kc = BlockingKernelClient()
    kc.load_connection_file(opts.conn_file)
    kc.start_channels()
    
    def dbg(msg):
        if opts.debug:
            try:
                sys.stderr.write(f"[myipy.zmq] {msg}\n")
                sys.stderr.flush()
            except Exception:
                pass
    dbg('channels started')

    PRELUDE = r'''
import json, types
# Optional scientific libs
try:
    import numpy as _np
except Exception:
    _np = None
try:
    import pandas as _pd
except Exception:
    _pd = None
# Optional ctypes for struct/array preview
try:
    import ctypes as _ct
except Exception:
    _ct = None

def __mi_srepr(x, n=120):
    try:
        r = repr(x)
        if len(r) > n:
            r = r[:n] + '...'
        return r
    except Exception:
        return '<unrepr>'

def __mi_shape(x):
    try:
        if _np is not None and isinstance(x, _np.ndarray):
            return list(getattr(x, 'shape', []))
        if _pd is not None and isinstance(x, _pd.DataFrame):
            return [int(x.shape[0]), int(x.shape[1])]
        if hasattr(x, '__len__') and not isinstance(x, (str, bytes, dict)):
            return [len(x)]
    except Exception:
        pass
    return None

def __mi_list_vars(max_repr=120, hide_names=None, hide_types=None):
    def _match(name, patterns):
        if not patterns:
            return False
        try:
            for p in patterns:
                if not isinstance(p, str):
                    continue
                if p.endswith('*'):
                    if name.startswith(p[:-1]):
                        return True
                else:
                    if name == p:
                        return True
        except Exception:
            return False
        return False
    import types
    g = globals()
    out = {}
    for k, v in g.items():
        if not isinstance(k, str):
            continue
        if k.startswith('_'):
            continue
        if k in ('In','Out','exit','quit','get_ipython'):
            continue
        if _match(k, hide_names):
            continue
        if isinstance(v, (types.ModuleType, types.FunctionType, type)) or callable(v):
            continue
        t = type(v).__name__
        if _match(t, hide_types):
            continue
        shp = __mi_shape(v)
        br = __mi_srepr(v, max_repr)
        try:
            dtype = None
            if _np is not None and isinstance(v, _np.ndarray):
                dtype = str(v.dtype)
            elif _pd is not None and isinstance(v, _pd.DataFrame):
                dtype = str(v.dtypes.to_dict())
        except Exception:
            dtype = None
        out[k] = {"type": t, "shape": shp, "dtype": dtype, "repr": br}
    print(json.dumps(out, ensure_ascii=False))

def __mi_preview(name, max_rows=50, max_cols=20):
    g = globals()
    if name not in g:
        print(json.dumps({"name": name, "error": "Name not found"})); return
    obj = g[name]
    # Preview for pandas.DataFrame
    try:
        if _pd is not None and isinstance(obj, _pd.DataFrame):
            df = obj.iloc[:max_rows, :max_cols]
            data = {
                "name": name,
                "kind": "dataframe",
                "shape": [int(df.shape[0]), int(df.shape[1])],
                "columns": [str(c) for c in df.columns.to_list()],
                "rows": [ [ None if _pd.isna(v) else (str(v) if not isinstance(v, (int,float,bool)) else v) for v in row ] for row in df.itertuples(index=False, name=None) ]
            }
            print(json.dumps(data, ensure_ascii=False)); return
    except Exception as e:
        print(json.dumps({"name": name, "error": str(e)})); return
    # Preview for numpy.ndarray
    try:
        if _np is not None and isinstance(obj, _np.ndarray):
            arr = obj
            info = {"name": name, "kind": "ndarray", "dtype": str(arr.dtype), "shape": list(arr.shape)}
            if getattr(arr, 'ndim', 0) == 1:
                info["values1d"] = arr[:max_rows].tolist()
            elif getattr(arr, 'ndim', 0) == 2:
                info["rows"] = arr[:max_rows, :max_cols].tolist()
            else:
                info["repr"] = __mi_srepr(arr, 300)
            print(json.dumps(info, ensure_ascii=False)); return
    except Exception as e:
        print(json.dumps({"name": name, "error": str(e)})); return
    # Preview for ctypes.Structure and ctypes.Array
    try:
        if _ct is not None and isinstance(obj, _ct.Structure):
            # Helper: stringify a ctypes type nicely
            def _ctype_name(t):
                try:
                    return getattr(t, '__name__', str(t))
                except Exception:
                    return str(t)
            # Helper: extract array element type if possible
            def _array_elt_type(a_type):
                try:
                    return getattr(a_type, '_type_', None)
                except Exception:
                    return None
            # Helper: convert ctypes value/array/struct into Python-native preview
            def _unbox(x, depth=0, max_elems= max_cols if isinstance(max_cols, int) else 20):
                # Limit recursion depth to avoid cycles
                if depth > 5:
                    return '<depth limit>'
                try:
                    if _ct is not None and isinstance(x, _ct.Array):
                        n = len(x)
                        out = []
                        m = int(max_elems) if isinstance(max_elems, int) else 20
                        for i in range(min(n, m)):
                            out.append(_unbox(x[i], depth+1, max_elems))
                        if n > m:
                            out.append(f'...(+{n-m} more)')
                        return out
                    if _ct is not None and isinstance(x, _ct.Structure):
                        d = {}
                        for fname, ftype in getattr(x, '_fields_', []) or []:
                            try:
                                fv = getattr(x, fname)
                            except Exception:
                                fv = '<unreadable>'
                            d[str(fname)] = _unbox(fv, depth+1, max_elems)
                        return d
                    # Try .value for simple ctypes scalars
                    try:
                        return getattr(x, 'value')
                    except Exception:
                        pass
                    # Fallback: return as-is if JSON can handle, else repr
                    if isinstance(x, (str, int, float, bool)) or x is None:
                        return x
                    return __mi_srepr(x, 120)
                except Exception:
                    return '<error>'
            # Build field list for Structure
            items = []
            try:
                for fname, ftype in getattr(obj, '_fields_', []) or []:
                    try:
                        raw = getattr(obj, fname)
                    except Exception as e:
                        raw = '<unreadable>'
                    entry = {
                        'name': str(fname),
                        'ctype': _ctype_name(ftype),
                    }
                    try:
                        if _ct is not None and isinstance(raw, _ct.Array):
                            # Array preview
                            elt_t = _array_elt_type(ftype)
                            entry['kind'] = 'array'
                            entry['elem_ctype'] = _ctype_name(elt_t) if elt_t else None
                            n = len(raw)
                            entry['length'] = int(n)
                            m = int(max_cols) if isinstance(max_cols, int) else 20
                            entry['values'] = _unbox(raw, 0, m)
                        elif _ct is not None and isinstance(raw, _ct.Structure):
                            entry['kind'] = 'struct'
                            entry['value'] = _unbox(raw, 0, max_cols)
                        else:
                            entry['kind'] = 'scalar'
                            entry['value'] = _unbox(raw, 0, max_cols)
                    except Exception:
                        entry['kind'] = 'unknown'
                        entry['value'] = '<error>'
                    items.append(entry)
            except Exception as e:
                print(json.dumps({"name": name, "error": f"ctypes inspect error: {e}"})); return
            data = {
                'name': name,
                'kind': 'ctypes',
                'struct_name': type(obj).__name__,
                'fields': items,
            }
            print(json.dumps(data, ensure_ascii=False)); return
        # Standalone ctypes arrays (not within a Structure)
        if _ct is not None and isinstance(obj, _ct.Array):
            def _unbox_arr(a, max_elems= max_rows if isinstance(max_rows, int) else 50):
                try:
                    n = len(a)
                    m = int(max_elems)
                    out = []
                    for i in range(min(n, m)):
                        x = a[i]
                        try:
                            v = getattr(x, 'value')
                        except Exception:
                            v = x
                        out.append(v)
                    if n > m:
                        out.append(f'...(+{n-m} more)')
                    return out
                except Exception:
                    return __mi_srepr(a, 200)
            data = {
                'name': name,
                'kind': 'ctypes_array',
                'ctype': getattr(type(obj), '__name__', str(type(obj))),
                'length': int(len(obj)),
                'values': _unbox_arr(obj),
            }
            print(json.dumps(data, ensure_ascii=False)); return
    except Exception as e:
        print(json.dumps({"name": name, "error": f"ctypes error: {e}"})); return
    print(json.dumps({"name": name, "kind": "object", "repr": __mi_srepr(obj, 300)}, ensure_ascii=False))
'''

    # Seed helpers in the kernel (no history)
    msg_id = kc.execute(PRELUDE, store_history=False, allow_stdin=False, stop_on_error=False)
    # Drain shell reply
    try:
        kc.get_shell_msg(timeout=5)
    except Exception:
        pass
    # Drain until idle
    while True:
        try:
            io = kc.get_iopub_msg(timeout=0.2)
            if io['msg_type'] == 'status' and io['content'].get('execution_state') == 'idle':
                break
        except Exception:
            break
    dbg('prelude ready')

    def run_and_collect(code):
        dbg(f'exec len={len(code)}')
        mid = kc.execute(code, store_history=False, allow_stdin=False, stop_on_error=True)
        acc = ''
        ok = True
        err = None
        idle = False
        t0 = time.time()
        while not idle and (time.time() - t0) < 5.0:
            try:
                msg = kc.get_iopub_msg(timeout=0.5)
            except Exception:
                continue
            if msg.get('parent_header', {}).get('msg_id') != mid:
                continue
            mtype = msg['msg_type']
            if mtype == 'stream' and msg['content'].get('name') == 'stdout':
                acc += msg['content'].get('text','')
            elif mtype == 'error':
                ok = False
                err = '\n'.join(msg['content'].get('traceback', []))
            elif mtype == 'status' and msg['content'].get('execution_state') == 'idle':
                idle = True
        # Debug: show how many bytes we captured on stdout for this exec
        try:
            dbg(f'stdout bytes={len(acc)} idle={idle}')
        except Exception:
            pass
        if not ok:
            dbg(f'kernel error: {err.splitlines()[-1] if err else "?"}')
            return ok, None, err
        try:
            data = json.loads(acc.strip()) if acc.strip() else None
            return True, data, None
        except Exception as e:
            dbg(f'parse error: {e}; payload={acc[:120]!r}')
            return False, None, f'parse error: {e}'

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            continue
        rid = req.get('id')
        op = req.get('op')
        op_args = req.get('args') or {}
        if op == 'ping':
            sys.stdout.write(json.dumps({ 'id': rid, 'ok': True, 'tag': 'pong' }) + "\n"); sys.stdout.flush()
            continue
        if op == 'vars':
            max_repr = int(op_args.get('max_repr', 120))
            hn = op_args.get('hide_names') or []
            ht = op_args.get('hide_types') or []
            # Build a Python expression with JSON-literal lists
            import json as __json
            hn_expr = __json.dumps(hn, ensure_ascii=False)
            ht_expr = __json.dumps(ht, ensure_ascii=False)
            ok, data, err = run_and_collect(f"__mi_list_vars(max_repr={max_repr}, hide_names={hn_expr}, hide_types={ht_expr})")
            dbg(f'vars ok={ok} size={0 if not data else len(data)}')
            resp = { 'id': rid, 'ok': ok, 'tag': 'vars' }
            if ok:
                resp['data'] = data
            else:
                resp['error'] = err or 'error'
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n"); sys.stdout.flush()
        elif op == 'preview':
            name = op_args.get('name') or ''
            mr = int(op_args.get('max_rows', 30))
            mc = int(op_args.get('max_cols', 20))
            # sanitize name for code injection
            name_esc = str(name).replace("'", "\\'")
            ok, data, err = run_and_collect(f"__mi_preview('{name_esc}', max_rows={mr}, max_cols={mc})")
            try:
                dbg(f'preview name={name!r} ok={ok} err={bool(err)} data_none={data is None}')
                if data is not None:
                    dbg(f'preview data keys={list(data.keys())}')
            except Exception:
                pass
            resp = { 'id': rid, 'ok': ok, 'tag': 'preview' }
            if ok:
                resp['data'] = data
            else:
                resp['error'] = err or 'error'
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n"); sys.stdout.flush()
        else:
            sys.stdout.write(json.dumps({ 'id': rid, 'ok': False, 'error': 'unknown op' }) + "\n"); sys.stdout.flush()

if __name__ == '__main__':
    sys.exit(main() or 0)
