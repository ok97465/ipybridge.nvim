#!/usr/bin/env python3
"""Backend process used by ipybridge.nvim to query kernel state via ZMQ."""

from __future__ import annotations

import argparse
import ast
import base64
import json
import socket
import sys
import time
from pathlib import Path
from typing import IO, Callable, Optional, Tuple


class Logger:
    """Minimal stderr logger that honours the --debug flag."""

    def __init__(self, enabled: bool) -> None:
        self._enabled = enabled

    def log(self, message: str) -> None:
        if not self._enabled:
            return
        try:
            sys.stderr.write(f"[myipy.zmq] {message}\n")
            sys.stderr.flush()
        except Exception:
            pass


class BootstrapPayload:
    """Build the bootstrap script that loads helpers inside the kernel."""

    def __init__(self, module_path: Path, helpers_path: Path) -> None:
        module_src = module_path.read_text(encoding="utf-8")
        self._module_b64 = base64.b64encode(module_src.encode("utf-8")).decode("ascii")
        self._template = helpers_path.read_text(encoding="utf-8")

    def build(self, enable_debug: bool) -> str:
        prelude = self._template.replace("__MODULE_B64__", self._module_b64)
        flag = "True" if enable_debug else "False"
        prelude = (
            f"{prelude}\n"
            f"_myipy_set_debug_logging({flag})\n"
            "__IPYBRIDGE_DEBUG_PORT__ = _DEBUG_PREVIEW.ensure_running()\n"
            "print('__IPYBRIDGE_DEBUG_PORT__:' + str(__IPYBRIDGE_DEBUG_PORT__))\n"
        )
        return prelude


class KernelChannel:
    """Wrapper around BlockingKernelClient with high-level helpers."""

    def __init__(self, client_factory: Callable[[], object], logger: Logger) -> None:
        self._client_factory = client_factory
        self._logger = logger
        self._client = None
        self._debug_port: Optional[int] = None

    @property
    def client(self):  # type: ignore[override]
        if self._client is None:
            raise RuntimeError("kernel client is not initialised")
        return self._client

    @property
    def debug_port(self) -> Optional[int]:
        return self._debug_port

    def connect(self, conn_file: str, prelude: str) -> None:
        client = self._client_factory()
        client.load_connection_file(conn_file)
        client.start_channels()
        self._logger.log("channels started")
        self._client = client
        self._send_prelude(prelude)

    def _send_prelude(self, prelude: str) -> None:
        msg_id = self.client.execute(
            prelude,
            store_history=False,
            allow_stdin=False,
            stop_on_error=False,
        )
        stdout_chunks = ""
        try:
            self.client.get_shell_msg(timeout=5)
        except Exception:
            pass
        while True:
            try:
                io_msg = self.client.get_iopub_msg(timeout=0.2)
            except Exception:
                break
            if (
                io_msg.get("msg_type") == "status"
                and io_msg.get("content", {}).get("execution_state") == "idle"
            ):
                break
            if (
                io_msg.get("msg_type") == "stream"
                and io_msg.get("content", {}).get("name") == "stdout"
            ):
                stdout_chunks += io_msg.get("content", {}).get("text", "")
        if stdout_chunks:
            for line in stdout_chunks.splitlines():
                if line.startswith("__IPYBRIDGE_DEBUG_PORT__:"):
                    try:
                        self._debug_port = int(line.split(":", 1)[1])
                        self._logger.log(
                            f"debug preview port captured {self._debug_port}"
                        )
                    except Exception:
                        self._logger.log("failed to parse debug preview port from prelude")
        self._logger.log("prelude ready")

    @staticmethod
    def _shorten(src: str, limit: int = 80) -> str:
        src = src.replace("\n", " ")
        if len(src) <= limit:
            return src
        return src[:limit] + "…"

    def run_and_collect(
        self,
        code: str,
        *,
        user_expression: Optional[str] = None,
    ) -> Tuple[bool, Optional[dict], Optional[str]]:
        exec_id = self.client.execute(
            code,
            store_history=False,
            allow_stdin=False,
            stop_on_error=True,
            user_expressions={"_": user_expression} if user_expression else None,
            silent=bool(user_expression and not code.strip()),
        )
        stdout_chunks = ""
        success = True
        error_text = None
        idle = False
        start = time.time()

        self._logger.log(
            f"exec len={len(code)} expr? {bool(user_expression)} payload={self._shorten(code)}"
        )

        try:
            while not idle and (time.time() - start) < 5.0:
                msg = self.client.get_iopub_msg(timeout=0.5)
                if msg.get("parent_header", {}).get("msg_id") != exec_id:
                    continue
                msg_type = msg.get("msg_type")
                self._logger.log(
                    f"iopub msg type={msg_type} keys={list(msg.keys())}"
                )
                if msg_type == "stream" and msg.get("content", {}).get("name") == "stdout":
                    stdout_chunks += msg.get("content", {}).get("text", "")
                elif msg_type == "error":
                    success = False
                    error_text = "\n".join(msg.get("content", {}).get("traceback", []))
                elif msg_type == "status" and msg.get("content", {}).get("execution_state") == "idle":
                    idle = True
                elif msg_type == "debug_reply":
                    self._logger.log(
                        f"debug reply content keys={list(msg.get('content', {}).keys())}"
                    )
                    idle = True
        except Exception as exc:
            self._logger.log(f"iopub loop error: {exc}")

        self._logger.log(f"stdout bytes={len(stdout_chunks)} idle={idle}")
        if not success:
            tail = error_text.splitlines()[-1] if error_text else "?"
            self._logger.log(f"kernel error: {tail}")
            return False, None, error_text

        try:
            reply = self.client.get_shell_msg(timeout=5)
        except Exception as exc:
            context = "shell reply timeout (expr)" if user_expression else "shell reply timeout"
            self._logger.log(f"{context}: {exc}")
            if stdout_chunks:
                try:
                    data = json.loads(stdout_chunks.strip())
                    return True, data, None
                except Exception as parse_exc:
                    self._logger.log(f"stdout parse error after timeout: {parse_exc}")
            return False, None, f"shell timeout: {exc}"

        content = reply.get("content") or {}
        status = content.get("status") or "ok"
        self._logger.log(
            f"shell reply status={status} keys={list(content.keys())}"
        )
        if status != "ok":
            err = content.get("ename") and content.get("evalue")
            if err:
                err = f"{content['ename']}: {content['evalue']}"
            else:
                err = "error"
            return False, None, err

        if user_expression:
            expr_payload = (content.get("user_expressions") or {}).get("_") or {}
            self._logger.log(
                f"user expr payload status={expr_payload.get('status')} keys={list(expr_payload.keys())}"
            )
            if expr_payload.get("status") != "ok":
                err = expr_payload.get("ename") or expr_payload.get("status") or "error"
                return False, None, err
            data_field = expr_payload.get("data") or {}
            if not data_field:
                self._logger.log("user expr data field empty")
                return False, None, "empty payload"
            json_text = data_field.get("application/json")
            if json_text is None and "text/plain" in data_field:
                text_value = data_field["text/plain"]
                self._logger.log(
                    f"user expr text/plain={self._shorten(str(text_value))}"
                )
                try:
                    json_text = ast.literal_eval(text_value) if isinstance(text_value, str) else text_value
                except Exception:
                    self._logger.log("user expr literal_eval failed; using raw text")
                    json_text = text_value
            if json_text is None:
                return False, None, "empty payload"
            try:
                data = json.loads(json_text)
                return True, data, None
            except Exception as exc:
                self._logger.log(
                    f"user expr parse error: {exc}; payload={json_text!r}"
                )
                return False, None, f"parse error: {exc}"

        payload = stdout_chunks.strip()
        if not payload:
            self._logger.log("empty payload from kernel")
            return False, None, "empty payload"
        self._logger.log(f"parsing payload from stdout len={len(payload)}")
        try:
            data = json.loads(payload)
            return True, data, None
        except Exception as exc:
            snippet = stdout_chunks[:120]
            self._logger.log(f"parse error: {exc}; payload={snippet!r}")
            return False, None, f"parse error: {exc}"


class DebugPreviewClient:
    """Handle debug preview requests with socket fallback."""

    def __init__(self, channel: KernelChannel, logger: Logger) -> None:
        self._channel = channel
        self._logger = logger
        self._port: Optional[int] = None

    def ensure_port(self) -> Optional[int]:
        if self._port:
            return self._port
        channel_port = getattr(self._channel, "debug_port", None)
        if isinstance(channel_port, int) and channel_port > 0:
            self._port = channel_port
            return self._port
        ok, data, err = self._channel.run_and_collect("__mi_debug_server_info()")
        if not ok or not isinstance(data, dict):
            self._logger.log(f"debug server info failed: {err}")
            return None
        port = data.get("port")
        if isinstance(port, int) and port > 0:
            self._port = port
            self._logger.log(f"debug preview port set to {port}")
            return port
        self._logger.log("debug preview port unavailable")
        return None

    def request(self, name: str, rows: int, cols: int, row_offset: int, col_offset: int) -> Tuple[bool, Optional[dict], Optional[str]]:
        port = self.ensure_port()
        if not port:
            return False, None, "debug preview server unavailable"
        payload = json.dumps(
            {
                "name": name,
                "max_rows": rows,
                "max_cols": cols,
                "row_offset": row_offset,
                "col_offset": col_offset,
            },
            ensure_ascii=False,
        ).encode("utf-8") + b"\n"
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
                sock.sendall(payload)
                sock.shutdown(socket.SHUT_WR)
                chunks = b""
                sock.settimeout(2.0)
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    chunks += chunk
                    if b"\n" in chunk:
                        break
        except Exception as exc:
            self._logger.log(f"debug preview socket error: {exc}")
            return False, None, f"socket error: {exc}"
        if not chunks:
            return False, None, "empty response"
        try:
            response = json.loads(chunks.decode("utf-8").strip())
        except Exception as exc:
            return False, None, f"decode error: {exc}"
        ok = bool(response.get("ok"))
        data = response.get("data")
        err = response.get("error")
        return ok, data, err


class RequestProcessor:
    """Route frontend JSON requests to kernel helpers."""

    def __init__(self, channel: KernelChannel, preview_client: DebugPreviewClient, logger: Logger) -> None:
        self._channel = channel
        self._preview = preview_client
        self._logger = logger

    def process_stream(self, stream: IO[str], output: IO[str]) -> None:
        for raw in stream:
            line = raw.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except Exception:
                continue
            response = self._handle_request(request)
            if response is None:
                continue
            output.write(json.dumps(response, ensure_ascii=False) + "\n")
            output.flush()

    def _handle_request(self, request: dict) -> Optional[dict]:
        req_id = request.get("id")
        op = request.get("op")
        args = request.get("args") or {}
        if op == "ping":
            return {"id": req_id, "ok": True, "tag": "pong"}
        if op == "vars":
            return self._handle_vars(req_id, args)
        if op == "preview":
            return self._handle_preview(req_id, args)
        return {"id": req_id, "ok": False, "error": "unknown op"}

    def _handle_vars(self, req_id, args: dict) -> dict:
        max_repr = int(args.get("max_repr", 120))
        hide_names = args.get("hide_names") or []
        hide_types = args.get("hide_types") or []
        hn_expr = json.dumps(hide_names, ensure_ascii=False)
        ht_expr = json.dumps(hide_types, ensure_ascii=False)
        code = (
            f"__mi_list_vars(max_repr={max_repr}, hide_names={hn_expr}, "
            f"hide_types={ht_expr})"
        )
        ok, data, err = self._channel.run_and_collect(code)
        self._logger.log(f"vars ok={ok} size={0 if not data else len(data)}")
        response = {"id": req_id, "ok": ok, "tag": "vars"}
        if ok:
            response["data"] = data
        else:
            response["error"] = err or "error"
        return response

    def _handle_preview(self, req_id, args: dict) -> dict:
        name = args.get("name") or ""
        debug_mode = bool(args.get("debug"))
        def _int(value, default=0):
            try:
                if value is None:
                    return default
                return int(value)
            except Exception:
                return default

        max_rows = _int(args.get("max_rows"), 30)
        max_cols = _int(args.get("max_cols"), 20)
        row_offset = _int(args.get("row_offset"), 0)
        col_offset = _int(args.get("col_offset"), 0)
        if row_offset < 0:
            row_offset = 0
        if col_offset < 0:
            col_offset = 0
        name_esc = str(name).replace("'", "\\'")
        if debug_mode:
            ok, data, err = self._preview.request(name, max_rows, max_cols, row_offset, col_offset)
            if not ok:
                self._logger.log(f"debug preview socket fallback err={err}")
                code = (
                    f"__mi_debug_preview('{name_esc}', max_rows={max_rows}, "
                    f"max_cols={max_cols}, row_offset={row_offset}, col_offset={col_offset})"
                )
                ok, data, err = self._channel.run_and_collect(code)
            response = {"id": req_id, "ok": bool(ok), "tag": "preview"}
            if ok and data is not None:
                response["data"] = data
            else:
                response["error"] = err or "debug preview failed"
            return response

        code = (
            f"__mi_preview('{name_esc}', max_rows={max_rows}, max_cols={max_cols}, row_offset={row_offset}, col_offset={col_offset})"
        )
        self._logger.log(
            f"preview exec code={KernelChannel._shorten(code)} debug={debug_mode}"
        )
        ok, data, err = self._channel.run_and_collect(code)
        self._logger.log(
            f"preview name={name!r} ok={ok} err={bool(err)} data_none={data is None}"
        )
        if data is not None:
            self._logger.log(f"preview data keys={list(data.keys())}")
        response = {"id": req_id, "ok": ok, "tag": "preview"}
        if ok:
            response["data"] = data
        else:
            response["error"] = err or "error"
        return response


def parse_args(argv: Optional[list] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conn-file", required=True)
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args(argv)


def main() -> int:
    opts = parse_args()
    logger = Logger(opts.debug)

    try:
        from jupyter_client import BlockingKernelClient
    except Exception:
        sys.stdout.write(
            json.dumps({"id": "0", "ok": False, "error": "jupyter_client missing"})
            + "\n"
        )
        sys.stdout.flush()
        return 1

    base_dir = Path(__file__).resolve().parent
    bootstrap = BootstrapPayload(
        base_dir / "ipybridge_ns.py",
        base_dir / "bootstrap_helpers.py",
    )
    channel = KernelChannel(BlockingKernelClient, logger)
    channel.connect(opts.conn_file, bootstrap.build(opts.debug))
    preview_client = DebugPreviewClient(channel, logger)
    processor = RequestProcessor(channel, preview_client, logger)
    processor.process_stream(sys.stdin, sys.stdout)
    return None


if __name__ == "__main__":
    sys.exit(main())
