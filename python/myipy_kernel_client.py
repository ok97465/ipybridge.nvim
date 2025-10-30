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
import threading
import uuid
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
        self._control_comm_id: Optional[str] = None
        self._control_comm_ready = False
        self._control_comm_lock = threading.Lock()
        self._iopub_backlog = []

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
        self._setup_control_comm()

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
                io_msg = self._get_iopub_msg(timeout=0.2)
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

    def _get_iopub_msg(self, timeout: float):
        """Return the next IOPub message, considering the local backlog first."""
        if self._iopub_backlog:
            return self._iopub_backlog.pop(0)
        return self.client.get_iopub_msg(timeout=timeout)

    def _cache_iopub_msg(self, msg: dict) -> None:
        """Store an IOPub message so other consumers can process it later."""
        self._iopub_backlog.append(msg)
        if len(self._iopub_backlog) > 200:
            self._iopub_backlog.pop(0)

    def _consume_cached_iopub(self, extractor):
        """Remove the first cached message matching extractor(msg)."""
        for idx, msg in enumerate(self._iopub_backlog):
            try:
                result = extractor(msg)
            except Exception:
                result = None
            if result is not None:
                self._iopub_backlog.pop(idx)
                return result
        return None

    def _await_comm_reply(
        self,
        request_id: str,
        timeout: float,
    ) -> Tuple[bool, Optional[str], bool]:
        """Wait for a control comm reply matching the provided request id.

        Returns (ok, error, timed_out). timed_out is True only when no reply
        arrived before the timeout expired.
        """
        if not request_id:
            return False, "missing request id", False
        if self._client is None:
            return False, "kernel client unavailable", False

        def parse_reply(msg):
            if not isinstance(msg, dict):
                return None
            if msg.get("msg_type") != "comm_msg":
                return None
            content = msg.get("content") or {}
            if content.get("comm_id") != self._control_comm_id:
                return None
            data = content.get("data") or {}
            response = data.get("response") or {}
            if response.get("request_id") != request_id:
                return None
            ok = bool(response.get("ok", True))
            err = response.get("error")
            if not ok and err:
                self._logger.log(f"control comm reply error: {err}")
            return ok, err

        cached = self._consume_cached_iopub(parse_reply)
        if cached is not None:
            ok, err = cached
            return ok, err, False

        deadline = time.monotonic() + max(timeout, 0.0)
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            wait_for = remaining if remaining < 0.15 else 0.15
            if wait_for <= 0:
                wait_for = 0.01
            try:
                msg = self.client.get_iopub_msg(timeout=wait_for)
            except Exception:
                continue
            parsed = parse_reply(msg)
            if parsed is not None:
                ok, err = parsed
                return ok, err, False
            self._cache_iopub_msg(msg)
        return False, "timeout waiting for reply", True

    def _wait_for_comm_open(self, comm_id: str, timeout: float = 1.0) -> bool:
        """Wait until the kernel acknowledges a comm_open for comm_id."""
        if not comm_id:
            return False

        def is_comm_open(msg):
            if not isinstance(msg, dict):
                return None
            if msg.get("msg_type") != "comm_open":
                return None
            content = msg.get("content") or {}
            if content.get("comm_id") != comm_id:
                return None
            return True

        if self._consume_cached_iopub(is_comm_open):
            return True

        deadline = time.monotonic() + max(timeout, 0.0)
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            wait_for = remaining if remaining < 0.15 else 0.15
            if wait_for <= 0:
                wait_for = 0.01
            try:
                msg = self.client.get_iopub_msg(timeout=wait_for)
            except Exception:
                continue
            if is_comm_open(msg):
                return True
            self._cache_iopub_msg(msg)
        return False

    def _send_control_comm(
        self,
        data: dict,
        expect_reply: bool = False,
        timeout: float = 0.0,
        allow_timeout: bool = False,
    ) -> Tuple[bool, Optional[str]]:
        """Send a message over the control comm."""
        if self._client is None:
            return False, "kernel client unavailable"
        comm_id = self._control_comm_id
        if not comm_id:
            return False, "control comm unavailable"
        content = {"comm_id": comm_id, "data": data}
        try:
            self.client.session.send(
                self.client.control_channel.socket,
                "comm_msg",
                content,
            )
        except Exception as exc:
            err = f"control comm send failed: {exc}"
            self._logger.log(err)
            return False, err
        if not expect_reply:
            return True, None
        request_id = data.get("request_id")
        if not request_id:
            return False, "missing request id"
        ok, err, timed_out = self._await_comm_reply(request_id, timeout or 1.0)
        if ok:
            return True, None
        if timed_out and allow_timeout:
            self._logger.log(
                "control comm reply timed out; continuing without acknowledgement"
            )
            return True, None
        return False, err

    def _setup_control_comm(self) -> bool:
        """Ensure the control comm channel is established and ready."""
        if self._client is None:
            return False
        with self._control_comm_lock:
            if self._control_comm_ready and self._control_comm_id:
                return True
            comm_id = uuid.uuid4().hex
            content = {
                "comm_id": comm_id,
                "target_name": "ipybridge.control",
                "data": {},
            }
            try:
                self.client.session.send(
                    self.client.shell_channel.socket,
                    "comm_open",
                    content,
                )
            except Exception as exc:
                self._logger.log(f"control comm open failed: {exc}")
                self._control_comm_id = None
                self._control_comm_ready = False
                return False
            self._control_comm_id = comm_id
            self._control_comm_ready = False
        if not self._wait_for_comm_open(comm_id, timeout=1.0):
            self._logger.log("control comm open acknowledgement timed out")
        request_id = f"ping-{uuid.uuid4().hex}"
        ok, err = self._send_control_comm(
            {"request": "ping", "request_id": request_id},
            expect_reply=True,
            timeout=1.0,
        )
        if ok:
            with self._control_comm_lock:
                self._control_comm_ready = True
            self._logger.log("control comm ready")
            return True
        self._logger.log(f"control comm handshake failed: {err}")
        with self._control_comm_lock:
            self._control_comm_id = None
            self._control_comm_ready = False
        return False

    def interrupt_kernel(self) -> Tuple[bool, Optional[str]]:
        """Send an interrupt request to the kernel via the control comm."""
        if self._client is None:
            return False, "kernel client unavailable"
        if not self._setup_control_comm():
            return False, "control comm unavailable"
        request_id = f"interrupt-{uuid.uuid4().hex}"
        ok, err = self._send_control_comm(
            {"request": "interrupt", "request_id": request_id},
            expect_reply=True,
            timeout=0.4,
            allow_timeout=True,
        )
        if ok:
            self._logger.log("interrupt request delivered")
            return True, None
        with self._control_comm_lock:
            self._control_comm_ready = False
        return False, err or "interrupt failed"

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
                msg = self._get_iopub_msg(timeout=0.5)
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

    def execute_silent(self, code: str) -> Tuple[bool, Optional[str]]:
        """Execute code without expecting structured stdout payload."""
        if not isinstance(code, str) or not code.strip():
            return True, None
        msg_id = self.client.execute(
            code,
            store_history=False,
            allow_stdin=False,
            stop_on_error=True,
            silent=True,
        )
        error_text: Optional[str] = None
        idle = False
        start = time.time()
        try:
            while not idle and (time.time() - start) < 5.0:
                msg = self._get_iopub_msg(timeout=0.5)
                if msg.get("parent_header", {}).get("msg_id") != msg_id:
                    continue
                msg_type = msg.get("msg_type")
                if msg_type == "status" and msg.get("content", {}).get("execution_state") == "idle":
                    idle = True
                    break
                if msg_type == "error":
                    content = msg.get("content") or {}
                    ename = content.get("ename") or ""
                    evalue = content.get("evalue") or ""
                    frames = "\n".join(content.get("traceback") or [])
                    if ename or evalue:
                        error_text = f"{ename}: {evalue}"
                    else:
                        error_text = frames or "error"
                    idle = True
                    break
        except Exception as exc:
            self._logger.log(f"silent exec iopub loop error: {exc}")
            return False, str(exc)

        try:
            reply = self.client.get_shell_msg(timeout=5)
        except Exception as exc:
            self._logger.log(f"silent exec shell timeout: {exc}")
            return False, f"shell timeout: {exc}"

        content = reply.get("content") or {}
        status = content.get("status") or "ok"
        if status != "ok":
            ename = content.get("ename") or ""
            evalue = content.get("evalue") or ""
            if ename or evalue:
                return False, f"{ename}: {evalue}"
            return False, "error"

        if error_text:
            return False, error_text

        return True, None

    def complete(self, code: str, cursor_pos: int) -> Tuple[bool, Optional[dict], Optional[str]]:
        """Request completions from the kernel."""
        if not isinstance(code, str):
            code = str(code or "")
        try:
            cursor = int(cursor_pos)
        except Exception:
            cursor = len(code)
        try:
            reply = self.client.complete(code=code, cursor_pos=cursor, reply=True, timeout=2.0)
        except Exception as exc:
            self._logger.log(f"complete request failed: {exc}")
            return False, None, str(exc)
        if not isinstance(reply, dict):
            self._logger.log("complete reply missing payload")
            return False, None, "invalid reply"
        status = reply.get("status") or "ok"
        if status != "ok":
            self._logger.log(
                f"complete status={status} ename={reply.get('ename')} evalue={reply.get('evalue')}"
            )
            err = reply.get("error") or reply.get("status") or "error"
            return False, reply, err
        matches = reply.get("matches")
        match_count = len(matches) if isinstance(matches, list) else 0
        self._logger.log(
            f"complete reply matches={match_count} cursor_start={reply.get('cursor_start')}"
        )
        return True, reply, None


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
    def _send(self, payload: dict) -> Tuple[bool, Optional[dict], Optional[str]]:
        port = self.ensure_port()
        if not port:
            return False, None, "debug preview server unavailable"
        try:
            blob = json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n"
        except Exception as exc:
            return False, None, f"encode error: {exc}"
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
                sock.sendall(blob)
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

    def request(self, name: str, rows: int, cols: int, row_offset: int, col_offset: int) -> Tuple[bool, Optional[dict], Optional[str]]:
        return self._send(
            {
                "op": "preview",
                "name": name,
                "max_rows": rows,
                "max_cols": cols,
                "row_offset": row_offset,
                "col_offset": col_offset,
            }
        )

    def complete(self, code: str, cursor_pos: int, debug: bool = True) -> Tuple[bool, Optional[dict], Optional[str]]:
        return self._send(
            {
                "op": "complete",
                "code": code,
                "cursor_pos": cursor_pos,
                "debug": bool(debug),
            }
        )


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
        if op == "exec":
            return self._handle_exec(req_id, args)
        if op == "interrupt":
            return self._handle_interrupt(req_id)
        if op == "complete":
            return self._handle_complete(req_id, args)
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

    def _handle_exec(self, req_id, args: dict) -> dict:
        code = args.get("code")
        if not isinstance(code, str):
            return {"id": req_id, "ok": False, "error": "missing code"}
        ok, err = self._channel.execute_silent(code)
        response = {"id": req_id, "ok": ok, "tag": "exec"}
        if not ok:
            response["error"] = err or "error"
        return response

    def _handle_interrupt(self, req_id) -> dict:
        ok, err = self._channel.interrupt_kernel()
        response = {"id": req_id, "ok": ok, "tag": "interrupt"}
        if not ok:
            response["error"] = err or "interrupt failed"
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

    @staticmethod
    def _strip_prompt(code: str, cursor: int) -> Tuple[str, int, int]:
        """Remove a leading ipdb prompt and adjust the cursor position."""
        prompts = ("ipdb> ", "ipdb>", "(Pdb) ", "(Pdb)")
        for prompt in prompts:
            if not code.startswith(prompt):
                continue
            adj_cursor = cursor - len(prompt)
            if adj_cursor < 0:
                adj_cursor = 0
            return code[len(prompt):], adj_cursor, len(prompt)
        return code, cursor, 0

    def _debug_complete_internal(self, code: str, cursor: int) -> Tuple[bool, Optional[dict], Optional[str]]:
        """Ask the side-car server for completions; fall back to the kernel on error."""
        ok, data, err = self._preview.complete(code, cursor, True)
        if ok:
            return ok, data, err
        self._logger.log(f"debug completion socket err={err}")
        return self._channel.complete(code, cursor)

    def _debug_complete_helper(self, code: str, cursor: int) -> Tuple[bool, Optional[dict], Optional[str]]:
        """Execute __mi_debug_complete inside the kernel and fall back if needed."""
        try:
            code_expr = json.dumps(code)
        except Exception:
            code_expr = json.dumps(str(code))
        request = f"__mi_debug_complete({code_expr}, {cursor}, debug=True)"
        ok, data, err = self._channel.run_and_collect(request)
        if ok:
            return True, data, None
        self._logger.log(f"debug completion helper err={err}")
        return self._channel.complete(code, cursor)

    def _resolve_completion(self, code: str, cursor: int, debug: bool, style: str) -> Tuple[bool, Optional[dict], Optional[str]]:
        """Select the appropriate completion strategy for the request."""
        if not debug:
            return self._channel.complete(code, cursor)
        style = (style or "").strip().lower()
        if style == "helper":
            return self._debug_complete_helper(code, cursor)
        if style == "kernel":
            return self._channel.complete(code, cursor)
        # Default to the internal side-car route so we do not interrupt the active debugger.
        return self._debug_complete_internal(code, cursor)

    def _handle_complete(self, req_id, args: dict) -> dict:
        raw_code = args.get("code")
        if not isinstance(raw_code, str):
            return {"id": req_id, "ok": False, "error": "missing code"}
        cursor_pos = args.get("cursor_pos")
        try:
            cursor = int(cursor_pos)
        except Exception:
            cursor = len(raw_code)

        code, cursor, prompt_len = self._strip_prompt(raw_code, cursor)
        debug_mode = bool(args.get("debug"))
        debug_style = str(args.get("debug_style") or "")
        ok, data, err = self._resolve_completion(code, cursor, debug_mode, debug_style)
        result = {"id": req_id, "ok": ok, "tag": "complete"}
        if ok and isinstance(data, dict):
            if prompt_len:
                try:
                    if "cursor_start" in data:
                        data["cursor_start"] = int(data["cursor_start"]) + prompt_len
                except Exception:
                    pass
                try:
                    if "cursor_end" in data:
                        data["cursor_end"] = int(data["cursor_end"]) + prompt_len
                except Exception:
                    pass
            result["data"] = data
        else:
            self._logger.log(f"complete handler error={err} data_keys={list(data.keys()) if isinstance(data, dict) else '?'}")
            result["ok"] = False
            result["error"] = err or "error"
        match_count = 0
        if isinstance(data, dict):
            entries = data.get("matches")
            if isinstance(entries, list):
                match_count = len(entries)
        self._logger.log(f"complete ok={ok} matches={match_count}")
        return result


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
