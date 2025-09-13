#!/usr/bin/env python3
import sys, json, argparse, time

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--conn-file', required=True)
    args = p.parse_args()

    try:
        from jupyter_client import BlockingKernelClient
    except Exception as e:
        sys.stdout.write(json.dumps({"id":"0","ok":False,"error":"jupyter_client missing"})+"\n")
        sys.stdout.flush()
        return 1

    kc = BlockingKernelClient()
    kc.load_connection_file(args.conn_file)
    kc.start_channels()

    PRELUDE = r'''
import json, types
try:
    import numpy as _np
except Exception:
    _np = None
try:
    import pandas as _pd
except Exception:
    _pd = None

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

def __mi_list_vars(max_repr=120):
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
        if isinstance(v, (types.ModuleType, types.FunctionType, type)) or callable(v):
            continue
        t = type(v).__name__
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

    def run_and_collect(code):
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
        if not ok:
            return ok, None, err
        try:
            data = json.loads(acc.strip()) if acc.strip() else None
            return True, data, None
        except Exception as e:
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
        args = req.get('args') or {}
        if op == 'ping':
            sys.stdout.write(json.dumps({ 'id': rid, 'ok': True, 'tag': 'pong' }) + "\n"); sys.stdout.flush()
            continue
        if op == 'vars':
            max_repr = int(args.get('max_repr', 120))
            ok, data, err = run_and_collect(f"__mi_list_vars(max_repr={max_repr})")
            resp = { 'id': rid, 'ok': ok, 'tag': 'vars' }
            if ok:
                resp['data'] = data
            else:
                resp['error'] = err or 'error'
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n"); sys.stdout.flush()
        elif op == 'preview':
            name = args.get('name') or ''
            mr = int(args.get('max_rows', 30))
            mc = int(args.get('max_cols', 20))
            # sanitize name for code injection
            name_esc = str(name).replace("'", "\\'")
            ok, data, err = run_and_collect(f"__mi_preview('{name_esc}', max_rows={mr}, max_cols={mc})")
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
