#!/usr/bin/env python3
"""Backend process used by ipybridge.nvim to query kernel state via ZMQ."""

import argparse
import base64
import ast
import json
from typing import Optional
import contextlib
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conn-file", required=True)
    parser.add_argument("--debug", action="store_true")
    opts = parser.parse_args()

    try:
        from jupyter_client import BlockingKernelClient
    except Exception:
        sys.stdout.write(json.dumps({"id": "0", "ok": False, "error": "jupyter_client missing"}) + "\n")
        sys.stdout.flush()
        return 1

    module_path = Path(__file__).with_name("ipybridge_ns.py")
    module_src = module_path.read_text(encoding="utf-8")
    module_b64 = base64.b64encode(module_src.encode("utf-8")).decode("ascii")
    bootstrap_template = Path(__file__).with_name("bootstrap_helpers.py").read_text(encoding="utf-8")

    client = BlockingKernelClient()
    client.load_connection_file(opts.conn_file)
    client.start_channels()

    def dbg(message: str) -> None:
        if not opts.debug:
            return
        try:
            sys.stderr.write(f"[myipy.zmq] {message}\n")
            sys.stderr.flush()
        except Exception:
            pass

    dbg("channels started")

    seq_counter = 1

    def next_seq() -> int:
        nonlocal seq_counter
        current = seq_counter
        seq_counter += 1
        return current

    prelude = bootstrap_template.replace("__MODULE_B64__", module_b64)
    prelude += "\n_myipy_set_debug_logging({flag})\n".format(flag="True" if opts.debug else "False")

    msg_id = client.execute(prelude, store_history=False, allow_stdin=False, stop_on_error=False)
    try:
        client.get_shell_msg(timeout=5)
    except Exception:
        pass
    while True:
        try:
            io_msg = client.get_iopub_msg(timeout=0.2)
            if io_msg['msg_type'] == 'status' and io_msg['content'].get('execution_state') == 'idle':
                break
        except Exception:
            break
    dbg("prelude ready")

    def _shorten(src: str, limit: int = 80) -> str:
        src = src.replace('\n', ' ')
        if len(src) <= limit:
            return src
        return src[:limit] + '…'

    def run_and_collect(code: str, *, user_expression: Optional[str] = None):
        dbg(f"exec len={len(code)} expr? {bool(user_expression)} payload={_shorten(code)}")
        exec_id = client.execute(
            code,
            store_history=False,
            allow_stdin=False,
            stop_on_error=True,
            user_expressions={'_': user_expression} if user_expression else None,
            silent=bool(user_expression and not code.strip()),
        )
        stdout_chunks = ''
        success = True
        error_text = None
        idle = False
        start = time.time()

        try:
            while not idle and (time.time() - start) < 5.0:
                msg = client.get_iopub_msg(timeout=0.5)
                if msg.get('parent_header', {}).get('msg_id') != exec_id:
                    continue
                msg_type = msg['msg_type']
                dbg(f'iopub msg type={msg_type} keys={list(msg.keys())}')
                if msg_type == 'stream' and msg['content'].get('name') == 'stdout':
                    stdout_chunks += msg['content'].get('text', '')
                elif msg_type == 'error':
                    success = False
                    error_text = '\n'.join(msg['content'].get('traceback', []))
                elif msg_type == 'status' and msg['content'].get('execution_state') == 'idle':
                    idle = True
                elif msg_type == 'debug_reply':
                    dbg(f'debug reply content keys={list(msg.get("content", {}).keys())}')
                    idle = True
        except Exception as exc:
            dbg(f'iopub loop error: {exc}')

        dbg(f'stdout bytes={len(stdout_chunks)} idle={idle}')
        if not success:
            dbg(f'kernel error: {error_text.splitlines()[-1] if error_text else "?"}')
            return False, None, error_text
        dbg(f'stdout bytes={len(stdout_chunks)} idle={idle} stop_on_timeout={success and bool(stdout_chunks)}')
        try:
            reply = client.get_shell_msg(timeout=5)
        except Exception as exc:
            dbg(('shell reply timeout (expr)' if user_expression else 'shell reply timeout') + f': {exc}')
            if success and stdout_chunks:
                dbg('using stdout payload despite shell timeout')
                try:
                    data = json.loads(stdout_chunks.strip())
                    return True, data, None
                except Exception as parse_exc:
                    dbg(f'stdout parse error after timeout: {parse_exc}')
            return False, None, f'shell timeout: {exc}'

        content = reply.get('content') or {}
        status = content.get('status') or 'ok'
        dbg(f'shell reply status={status} keys={list(content.keys())}')
        if status != 'ok':
            err = 'error'
            if 'ename' in content and 'evalue' in content:
                err = f"{content['ename']}: {content['evalue']}"
            return False, None, err

        if user_expression:
            expr_payload = (content.get('user_expressions') or {}).get('_') or {}
            dbg(f'user expr payload status={expr_payload.get("status")} keys={list(expr_payload.keys())}')
            if expr_payload.get('status') != 'ok':
                err = expr_payload.get('ename') or expr_payload.get('status') or 'error'
                return False, None, err
            data_field = expr_payload.get('data') or {}
            if not data_field:
                dbg('user expr data field empty')
                return False, None, 'empty payload'
            json_text = data_field.get('application/json')
            if json_text is None and 'text/plain' in data_field:
                text_value = data_field['text/plain']
                dbg(f'user expr text/plain={_shorten(str(text_value))}')
                try:
                    json_text = ast.literal_eval(text_value) if isinstance(text_value, str) else text_value
                except Exception:
                    dbg(f'user expr literal_eval failed; using raw text')
                    json_text = text_value
            if json_text is None:
                return False, None, 'empty payload'
            try:
                data = json.loads(json_text)
                return True, data, None
            except Exception as exc:
                dbg(f'user expr parse error: {exc}; payload={json_text!r}')
                return False, None, f'parse error: {exc}'

        payload = stdout_chunks.strip()
        if not payload:
            dbg('empty payload from kernel')
            return False, None, 'empty payload'
        dbg(f'parsing payload from stdout len={len(payload)}')
        try:
            data = json.loads(payload)
            return True, data, None
        except Exception as exc:
            dbg(f'parse error: {exc}; payload={stdout_chunks[:120]!r}')
            return False, None, f'parse error: {exc}'

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except Exception:
            continue
        req_id = request.get('id')
        op = request.get('op')
        args = request.get('args') or {}
        if op == 'ping':
            sys.stdout.write(json.dumps({'id': req_id, 'ok': True, 'tag': 'pong'}) + "\n")
            sys.stdout.flush()
            continue
        if op == 'vars':
            max_repr = int(args.get('max_repr', 120))
            hide_names = args.get('hide_names') or []
            hide_types = args.get('hide_types') or []
            hn_expr = json.dumps(hide_names, ensure_ascii=False)
            ht_expr = json.dumps(hide_types, ensure_ascii=False)
            code = f"__mi_list_vars(max_repr={max_repr}, hide_names={hn_expr}, hide_types={ht_expr})"
            ok, data, err = run_and_collect(code)
            dbg(f'vars ok={ok} size={0 if not data else len(data)}')
            response = {'id': req_id, 'ok': ok, 'tag': 'vars'}
            if ok:
                response['data'] = data
            else:
                response['error'] = err or 'error'
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        elif op == 'preview':
            name = args.get('name') or ''
            max_rows = int(args.get('max_rows', 30))
            max_cols = int(args.get('max_cols', 20))
            name_esc = str(name).replace("'", "\\'")
            code = f"__mi_preview('{name_esc}', max_rows={max_rows}, max_cols={max_cols})"
            dbg(f'preview exec code={_shorten(code)}')
            ok, data, err = run_and_collect(code)
            dbg(f'preview name={name!r} ok={ok} err={bool(err)} data_none={data is None}')
            if data is not None:
                dbg(f'preview data keys={list(data.keys())}')
            response = {'id': req_id, 'ok': ok, 'tag': 'preview'}
            if ok:
                response['data'] = data
            else:
                response['error'] = err or 'error'
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        else:
            sys.stdout.write(json.dumps({'id': req_id, 'ok': False, 'error': 'unknown op'}) + "\n")
            sys.stdout.flush()

    return None


if __name__ == "__main__":
    sys.exit(main() or 0)
