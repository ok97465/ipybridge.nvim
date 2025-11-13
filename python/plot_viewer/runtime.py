"""Matplotlib plot history server for ipybridge.nvim.

This module hosts a lightweight HTTP + SSE server that mirrors Spyder's plots
pane: every time the kernel calls ``plt.show`` or ``plt.savefig`` we snapshot the
active figures, store them in an in-memory history, and expose thumbnails +
metadata through a browser UI. The Neovim side can also steer the history via
ZMQ commands (next/prev/delete), so the UX stays keyboard‑friendly even though
rendering happens in a browser.
"""

from __future__ import annotations

import dataclasses
import functools
import io
import json
import queue
import secrets
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional
from urllib.parse import parse_qs, urlparse


# ---------------------------------------------------------------------------
# Utilities


def _resolve_asset_root() -> Path:
    """Locate the plot pane assets regardless of plugin install layout."""

    here = Path(__file__).resolve()
    parents = list(here.parents)
    candidates: List[Path] = []

    for depth in (2, 1, 0):
        if depth < len(parents):
            candidates.append(parents[depth] / "resources" / "plot_pane")

    for candidate in candidates:
        if candidate.is_dir():
            return candidate

    return candidates[0] if candidates else here.parent


_ASSET_ROOT = _resolve_asset_root()
_VIEWER_ASSET_CACHE: Dict[str, bytes] = {}


def _now() -> float:
    return time.time()


def _load_viewer_html() -> str:
    return (_ASSET_ROOT / "index.html").read_text(encoding="utf-8")


_VIEWER_HTML_CACHE: Optional[str] = None


def _viewer_html() -> str:
    """Load the viewer HTML lazily so missing assets do not break import."""

    global _VIEWER_HTML_CACHE
    if _VIEWER_HTML_CACHE is not None:
        return _VIEWER_HTML_CACHE
    try:
        _VIEWER_HTML_CACHE = _load_viewer_html()
    except OSError as exc:
        # Fall back to a tiny inline page that surfaces the root issue.
        _VIEWER_HTML_CACHE = (
            f"<html><body><h1>Plot viewer unavailable</h1><p>{exc}</p></body></html>"
        )
    return _VIEWER_HTML_CACHE


def _viewer_asset(name: str) -> bytes:
    """Return cached static asset bytes for the browser UI."""

    cached = _VIEWER_ASSET_CACHE.get(name)
    if cached is not None:
        return cached
    try:
        data = (_ASSET_ROOT / name).read_bytes()
    except OSError as exc:
        data = f"/* plot viewer asset missing ({name}): {exc} */".encode("utf-8")
    _VIEWER_ASSET_CACHE[name] = data
    return data


# ---------------------------------------------------------------------------
# Plot storage


@dataclass
class PlotEntry:
    """Single plot snapshot with PNG payload and metadata."""

    plot_id: str
    figure_number: int
    label: str
    title: str
    reason: str
    backend: str
    created_at: float
    width: int
    height: int
    dpi: float
    png: bytes = field(repr=False)

    def summary(self) -> dict:
        return {
            "id": self.plot_id,
            "figure": self.figure_number,
            "label": self.label,
            "title": self.title,
            "reason": self.reason,
            "backend": self.backend,
            "created_at": self.created_at,
            "width": self.width,
            "height": self.height,
            "dpi": self.dpi,
        }


class PlotStore:
    """Bounded FIFO store that tracks selection and metadata."""

    def __init__(self, max_entries: int = 40) -> None:
        self._max_entries = max_entries
        self._entries: List[PlotEntry] = []
        self._selected: Optional[str] = None
        self._lock = threading.Lock()

    def add(self, entry: PlotEntry) -> List[PlotEntry]:
        removed: List[PlotEntry] = []
        with self._lock:
            self._entries.append(entry)
            self._selected = entry.plot_id
            while len(self._entries) > self._max_entries:
                removed.append(self._entries.pop(0))
        return removed

    def all(self) -> List[PlotEntry]:
        with self._lock:
            return list(self._entries)

    def summaries(self) -> List[dict]:
        return [entry.summary() for entry in self.all()]

    def get(self, plot_id: str) -> Optional[PlotEntry]:
        with self._lock:
            for entry in self._entries:
                if entry.plot_id == plot_id:
                    return entry
        return None

    def remove(self, plot_id: str) -> Optional[PlotEntry]:
        with self._lock:
            new_entries: List[PlotEntry] = []
            removed: Optional[PlotEntry] = None
            removed_index: Optional[int] = None
            for entry in self._entries:
                if entry.plot_id == plot_id and removed is None:
                    removed = entry
                    removed_index = len(new_entries)
                    continue
                new_entries.append(entry)
            self._entries = new_entries
            if removed and self._selected == removed.plot_id:
                if not self._entries:
                    self._selected = None
                elif removed_index is not None and removed_index < len(self._entries):
                    # Pick the plot that shifted into the removed slot.
                    self._selected = self._entries[removed_index].plot_id
                else:
                    # Removed last entry; fall back to the new tail.
                    self._selected = self._entries[-1].plot_id
        return removed

    def clear(self) -> List[PlotEntry]:
        with self._lock:
            removed = list(self._entries)
            self._entries = []
            self._selected = None
        return removed

    def select(self, plot_id: str) -> Optional[PlotEntry]:
        entry = self.get(plot_id)
        if entry:
            with self._lock:
                self._selected = entry.plot_id
        return entry

    def _rotate(self, step: int) -> Optional[PlotEntry]:
        with self._lock:
            if not self._entries:
                return None
            if self._selected is None:
                self._selected = self._entries[-1].plot_id
                return self._entries[-1]
            ids = [entry.plot_id for entry in self._entries]
            try:
                idx = ids.index(self._selected)
            except ValueError:
                idx = len(ids) - 1
            new_idx = (idx + step) % len(ids)
            self._selected = ids[new_idx]
            return self._entries[new_idx]

    def next(self) -> Optional[PlotEntry]:
        return self._rotate(1)

    def prev(self) -> Optional[PlotEntry]:
        return self._rotate(-1)

    def selected(self) -> Optional[PlotEntry]:
        with self._lock:
            if not self._selected:
                return None
            for entry in self._entries:
                if entry.plot_id == self._selected:
                    return entry
        return None

    def max_entries(self) -> int:
        return self._max_entries


# ---------------------------------------------------------------------------
# Event streaming (Server-Sent Events)


class EventStream:
    """Broadcast JSON payloads to connected SSE clients."""

    def __init__(self) -> None:
        self._clients: Dict[int, queue.Queue] = {}
        self._lock = threading.Lock()
        self._next_id = 1

    def register(self) -> tuple[int, "queue.Queue[dict]"]:
        with self._lock:
            client_id = self._next_id
            self._next_id += 1
            q: "queue.Queue[dict]" = queue.Queue()
            self._clients[client_id] = q
            return client_id, q

    def unregister(self, client_id: int) -> None:
        with self._lock:
            self._clients.pop(client_id, None)

    def publish(self, event: str, payload: dict) -> None:
        message = {
            "event": event,
            "payload": payload,
            "timestamp": _now(),
        }
        with self._lock:
            queues = list(self._clients.values())
        for q in queues:
            try:
                q.put_nowait(message)
            except queue.Full:
                continue


# ---------------------------------------------------------------------------
# HTTP server


class PlotHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, host_port, handler, context: "PlotServer") -> None:
        super().__init__(host_port, handler)
        self.context = context


class PlotRequestHandler(BaseHTTPRequestHandler):
    """Serve the viewer UI, JSON APIs, and PNG payloads."""

    server: PlotHTTPServer

    def log_message(
        self, format: str, *args
    ) -> None:  # noqa: A003 - match BaseHTTPRequestHandler signature
        # Silence default logging; Neovim already prints kernel logs.
        return

    # Routing helpers -----------------------------------------------------

    def _parse(self):
        parsed = urlparse(self.path)
        return parsed.path or "/", parse_qs(parsed.query)

    def _token_valid(self, params: dict) -> bool:
        token = params.get("token", [""])[0]
        return token == self.server.context.token

    def _send_json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # HTTP verbs ----------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802
        path, params = self._parse()
        if not self._token_valid(params):
            self._send_json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        if path in ("/", "/index.html"):
            self._serve_index()
            return
        if path == "/app.css":
            self._serve_asset("app.css", "text/css; charset=utf-8")
            return
        if path == "/app.js":
            self._serve_asset("app.js", "application/javascript; charset=utf-8")
            return
        if path == "/plots":
            self._send_json(self.server.context.list_plots())
            return
        if path.startswith("/plots/") and path.endswith(".png"):
            plot_id = path.rsplit("/", 1)[-1][:-4]
            payload = self.server.context.png_payload(plot_id)
            if payload is None:
                self._send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            self.send_response(HTTPStatus.OK.value)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if path == "/events":
            self._serve_events()
            return
        if path == "/status":
            self._send_json(self.server.context.status())
            return
        self._send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        path, params = self._parse()
        if not self._token_valid(params):
            self._send_json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        ctx = self.server.context
        if path.startswith("/plots/") and path.endswith("/select"):
            parts = path.strip("/").split("/")
            plot_id = parts[1] if len(parts) >= 3 else ""
            plot_id = plot_id or params.get("id", [""])[0]
            self._send_json(ctx.select_plot(plot_id))
            return
        if path == "/plots/next":
            self._send_json(ctx.rotate_plot(1))
            return
        if path == "/plots/prev":
            self._send_json(ctx.rotate_plot(-1))
            return
        if path == "/plots/clear":
            self._send_json(ctx.clear_plots())
            return
        self._send_json({"error": "unknown endpoint"}, HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:  # noqa: N802
        path, params = self._parse()
        if not self._token_valid(params):
            self._send_json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        if path.startswith("/plots/"):
            plot_id = path.rsplit("/", 1)[-1]
            payload = self.server.context.remove_plot(plot_id)
            if not payload:
                self._send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            self._send_json(payload)
            return
        self._send_json({"error": "unknown endpoint"}, HTTPStatus.NOT_FOUND)

    # Views ---------------------------------------------------------------

    def _serve_index(self) -> None:
        token = self.server.context.token
        html = _viewer_html().replace("__PLOT_TOKEN__", token)
        payload = html.encode("utf-8")
        self.send_response(HTTPStatus.OK.value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _serve_asset(self, name: str, content_type: str) -> None:
        payload = _viewer_asset(name)
        self.send_response(HTTPStatus.OK.value)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _serve_events(self) -> None:
        ctx = self.server.context
        client_id, q = ctx.events.register()
        try:
            self.send_response(HTTPStatus.OK.value)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            for event, payload in ctx.snapshot_events():
                data = json.dumps(payload, ensure_ascii=False)
                body = f"event: {event}\ndata: {data}\n\n".encode("utf-8")
                self.wfile.write(body)
                self.wfile.flush()
            while True:
                message = q.get()
                data = json.dumps(message["payload"], ensure_ascii=False)
                event = message["event"]
                body = f"event: {event}\ndata: {data}\n\n".encode("utf-8")
                self.wfile.write(body)
                self.wfile.flush()
        except Exception:
            pass
        finally:
            ctx.events.unregister(client_id)


# ---------------------------------------------------------------------------
# Plot server facade


INLINE_BACKEND = "module://matplotlib_inline.backend_inline"

_PLOT_REQUIRED_BACKEND = INLINE_BACKEND


class PlotServer:
    """Own the HTTP server, plot storage, and SSE broadcast helpers."""

    def __init__(self, max_entries: int = 40) -> None:
        self._store = PlotStore(max_entries)
        self._host = "127.0.0.1"
        self._token = secrets.token_urlsafe(32)
        self._httpd: Optional[PlotHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._port: Optional[int] = None
        self._lock = threading.Lock()
        self.events = EventStream()
        self._backend_name: Optional[str] = None
        self._backend_active: bool = True
        self._backend_required: str = _PLOT_REQUIRED_BACKEND

    # HTTP lifecycle ------------------------------------------------------

    def start(self) -> None:
        with self._lock:
            if self._httpd:
                return
            handler = PlotRequestHandler
            try:
                httpd = PlotHTTPServer((self._host, 0), handler, self)
            except (
                OSError
            ) as exc:  # pragma: no cover - startup errors are environment-specific
                raise RuntimeError(f"plot server failed to bind: {exc}") from exc
            self._httpd = httpd
            self._port = httpd.server_address[1]
            thread = threading.Thread(
                target=httpd.serve_forever, name="ipybridge-plot-httpd", daemon=True
            )
            thread.start()
            self._thread = thread

    def shutdown(self) -> None:
        with self._lock:
            if not self._httpd:
                return
            httpd = self._httpd
            thread = self._thread
            try:
                httpd.shutdown()
            finally:
                httpd.server_close()
                self._httpd = None
                self._port = None
                self._thread = None
        # Join outside the lock to avoid blocking other operations.
        if thread and thread.is_alive():
            thread.join(timeout=1.0)

    # Public helpers ------------------------------------------------------

    @property
    def token(self) -> str:
        return self._token

    @property
    def port(self) -> Optional[int]:
        return self._port

    def url(self) -> Optional[str]:
        if self._port is None:
            return None
        return f"http://{self._host}:{self._port}/?token={self._token}"

    def status(self) -> dict:
        selected = self._store.selected()
        return {
            "status": "ready" if self._httpd else "stopped",
            "port": self._port,
            "token": self._token,
            "url": self.url(),
            "count": len(self._store.all()),
            "selected": selected.summary() if selected else None,
            "history_limit": self._store.max_entries(),
            "backend": self._backend_name,
            "backend_active": self._backend_active,
            "backend_required": self._backend_required,
        }

    def current_selection(self) -> Optional[dict]:
        entry = self._store.selected()
        return entry.summary() if entry else None

    def set_backend_state(
        self, name: Optional[str], active: bool, required: Optional[str] = None
    ) -> None:
        self._backend_name = name
        self._backend_active = active
        if required:
            self._backend_required = required

    def snapshot_events(self) -> List[tuple[str, dict]]:
        return [
            ("plot-sync", self.list_plots()),
            (
                "backend-state",
                {
                    "backend": self._backend_name,
                    "active": self._backend_active,
                    "required": self._backend_required,
                },
            ),
        ]

    def list_plots(self) -> dict:
        entries = self._store.summaries()
        selected = self._store.selected()
        return {
            "entries": entries,
            "selected": selected.summary() if selected else None,
        }

    def png_payload(self, plot_id: str) -> Optional[bytes]:
        entry = self._store.get(plot_id)
        return entry.png if entry else None

    def add_entry(self, entry: PlotEntry) -> None:
        removed = self._store.add(entry)
        self.events.publish("plot-added", entry.summary())
        self.events.publish("plot-selected", entry.summary())
        for item in removed:
            self.events.publish("plot-removed", item.summary())

    def select_plot(self, plot_id: str) -> dict:
        entry = self._store.select(plot_id)
        if not entry:
            return {"ok": False, "error": "not found"}
        summary = entry.summary()
        self.events.publish("plot-selected", summary)
        return {"ok": True, "selected": summary}

    def rotate_plot(self, step: int) -> dict:
        entry = self._store.next() if step > 0 else self._store.prev()
        if not entry:
            return {"ok": False, "error": "no plots"}
        summary = entry.summary()
        self.events.publish("plot-selected", summary)
        return {"ok": True, "selected": summary}

    def remove_plot(self, plot_id: str) -> Optional[dict]:
        entry = self._store.remove(plot_id)
        if not entry:
            return None
        summary = entry.summary()
        self.events.publish("plot-removed", summary)
        selected = self._store.selected()
        if selected:
            self.events.publish("plot-selected", selected.summary())
        return {
            "ok": True,
            "removed": summary,
            "selected": selected.summary() if selected else None,
        }

    def clear_plots(self) -> dict:
        removed = [entry.summary() for entry in self._store.clear()]
        for item in removed:
            self.events.publish("plot-removed", item)
        self.events.publish("plot-selected", None)
        return {"ok": True, "removed": removed}


# ---------------------------------------------------------------------------
# Command routing


class PlotCommandRouter:
    """Route high-level actions (next/prev/delete/etc.) to PlotServer methods."""

    def __init__(self, server: PlotServer, status_provider: Callable[[], dict]) -> None:
        self._server = server
        self._status_provider = status_provider
        self._handlers = {
            "status": self._status,
            "list": self._list,
            "next": lambda payload: self._server.rotate_plot(1),
            "prev": lambda payload: self._server.rotate_plot(-1),
            "clear": lambda payload: self._server.clear_plots(),
            "select": self._select,
            "delete": self._delete,
        }

    def handle(self, action: Optional[str], payload: Optional[dict]) -> dict:
        if not action:
            return {"ok": False, "error": "missing action"}
        handler = self._handlers.get(action.lower())
        if not handler:
            return {"ok": False, "error": "unknown action"}
        return handler(payload or {})

    def _status(self, payload: dict) -> dict:
        return {"ok": True, "data": self._status_provider()}

    def _list(self, payload: dict) -> dict:
        return {"ok": True, "data": self._server.list_plots()}

    def _select(self, payload: dict) -> dict:
        plot_id = payload.get("id") if isinstance(payload, dict) else None
        if not plot_id:
            return {"ok": False, "error": "missing id"}
        return self._server.select_plot(str(plot_id))

    def _delete(self, payload: dict) -> dict:
        plot_id = payload.get("id") if isinstance(payload, dict) else None
        if not plot_id:
            selected = self._server.current_selection()
            plot_id = selected["id"] if selected else None
        if not plot_id:
            return {"ok": False, "error": "no selection"}
        result = self._server.remove_plot(str(plot_id))
        return result or {"ok": False, "error": "not found"}


# ---------------------------------------------------------------------------
# Runtime helpers


class _PlotServerController:
    """Own PlotServer lifecycle, configuration, and command routing."""

    def __init__(
        self,
        status_provider: Callable[[], dict],
        status_emitter: Callable[[Optional[dict]], dict],
    ) -> None:
        self._status_provider = status_provider
        self._emit_status = status_emitter
        self._server: Optional[PlotServer] = None
        self._command_router: Optional[PlotCommandRouter] = None
        self._config: Dict[str, int] = {"max_entries": 40}

    @property
    def server(self) -> Optional[PlotServer]:
        return self._server

    def inject_server(self, server: Optional[PlotServer]) -> None:
        self._server = server
        if server is None:
            self._command_router = None
            return
        self._command_router = PlotCommandRouter(server, self._status_provider)

    def configure(self, options: Optional[dict]) -> None:
        if options:
            self._config.update(options)

    def ensure_running(self) -> None:
        if self._server:
            return
        server = PlotServer(self._config.get("max_entries", 40))
        server.start()
        self._server = server
        self._command_router = PlotCommandRouter(server, self._status_provider)
        self._emit_status()

    def shutdown(self) -> None:
        if not self._server:
            return
        server = self._server
        self._server = None
        self._command_router = None
        server.shutdown()
        self._emit_status({"status": "stopped"})

    def status(self) -> dict:
        if self._server:
            return self._server.status()
        return {"status": "stopped"}

    def add_entry(self, entry: PlotEntry) -> None:
        if self._server:
            self._server.add_entry(entry)

    def set_backend_state(
        self, name: Optional[str], active: bool, required: str
    ) -> None:
        if self._server:
            self._server.set_backend_state(name, active, required)

    def handle_command(self, action: Optional[str], payload: Optional[dict]) -> dict:
        router = self._command_router
        if not router:
            server = self._server
            if not server:
                return {"ok": False, "error": "plot viewer disabled"}
            router = PlotCommandRouter(server, self._status_provider)
            self._command_router = router
        return router.handle(action, payload or {})


class _MatplotlibHookManager:
    """Install pyplot hooks, capture figures, and report backend state."""

    def __init__(
        self,
        required_backend: str,
        server_controller: _PlotServerController,
        status_changed: Callable[[Optional[dict]], dict],
        capture_callback: Optional[Callable[[str], None]] = None,
    ) -> None:
        self._required_backend = required_backend
        self._server_controller = server_controller
        self._status_changed = status_changed
        self._capture_callback = capture_callback
        self._hook_originals: Dict[str, Callable] = {}
        self._hooks_installed = False
        self._backend_name: Optional[str] = None
        self._backend_active = True
        self._inline_display_original: Optional[Callable] = None
        self._inline_display_disabled = False
        self._inline_capture_active = False
        self._close_after_capture = "matplotlib_inline" in str(
            required_backend or ""
        ).lower()

    def install(self) -> None:
        if self._hooks_installed:
            return
        import matplotlib.pyplot as plt  # type: ignore

        def register(fn_name: str, builder: Callable[[Callable], Callable]) -> None:
            current = getattr(plt, fn_name)
            self._hook_originals[fn_name] = current
            setattr(plt, fn_name, builder(current))

        def make_capture_wrapper(reason: str, capture_after: bool):
            def factory(original: Callable):
                @functools.wraps(original)
                def wrapped(*args, **kwargs):
                    return self._invoke_and_capture(
                        original, reason, capture_after, *args, **kwargs
                    )

                return wrapped

            return factory

        register("show", make_capture_wrapper("pyplot.show", False))
        register("savefig", make_capture_wrapper("pyplot.savefig", True))

        def make_backend_wrapper(original: Callable):
            @functools.wraps(original)
            def wrapped(*args, **kwargs):
                return self._switch_backend(original, *args, **kwargs)

            return wrapped

        register("switch_backend", make_backend_wrapper)
        self._hooks_installed = True

    def disable(self) -> None:
        self.uninstall()
        self._restore_inline_capture()
        self._backend_name = None
        self._backend_active = True
        self._status_changed(None)

    def uninstall(self) -> None:
        if not self._hooks_installed:
            return
        import matplotlib.pyplot as plt  # type: ignore

        for name, original in self._hook_originals.items():
            setattr(plt, name, original)
        self._hook_originals.clear()
        self._hooks_installed = False

    def force_backend(self) -> None:
        import matplotlib.pyplot as plt  # type: ignore
        import matplotlib  # type: ignore

        current = str(matplotlib.get_backend()).lower()
        target = str(self._required_backend).lower()
        if current != target:
            try:
                plt.switch_backend(self._required_backend)
            except Exception:
                pass
        self._ensure_inline_support()
        self._enable_inline_capture()

    def sync_backend_state(self) -> None:
        import matplotlib  # type: ignore

        backend = matplotlib.get_backend()
        lowered = str(backend).lower()
        required_lower = str(self._required_backend).lower()
        active = lowered == required_lower
        prev_name = self._backend_name
        prev_active = self._backend_active
        self._backend_name = lowered
        self._backend_active = active
        if lowered != prev_name or active != prev_active:
            self._server_controller.set_backend_state(
                lowered, active, self._required_backend
            )
            self._status_changed(None)

    def capture(self, reason: str) -> None:
        self.sync_backend_state()
        if not self._backend_active:
            return
        managers = self._get_managers()
        for manager in managers:
            entry = self._render_manager(manager, reason)
            if entry:
                self._server_controller.add_entry(entry)
                self._close_manager(manager)

    def snapshot(self) -> dict:
        return {
            "backend": self._backend_name,
            "backend_active": self._backend_active,
            "backend_required": self._required_backend,
        }

    def _forward_capture(self, reason: str) -> None:
        if self._capture_callback:
            try:
                self._capture_callback(reason)
                return
            except Exception:
                pass
        self.capture(reason)

    def _invoke_and_capture(
        self, func, reason: str, capture_after: bool, *args, **kwargs
    ):
        skip_capture = reason == "pyplot.show" and self._inline_capture_active
        if not skip_capture and not capture_after:
            self._forward_capture(reason)
        result = func(*args, **kwargs)
        if not skip_capture and capture_after:
            self._forward_capture(reason)
        return result

    def _switch_backend(self, original, *args, **kwargs):
        result = original(*args, **kwargs)
        self.sync_backend_state()
        return result

    def _ensure_inline_support(self) -> None:
        target = str(self._required_backend).lower()
        if "matplotlib_inline" not in target:
            return
        try:
            from IPython import get_ipython  # type: ignore
            from IPython.core.pylabtools import activate_matplotlib  # type: ignore
            from matplotlib_inline.backend_inline import configure_inline_support  # type: ignore
        except Exception:
            return
        shell = get_ipython()
        if shell is None:
            return
        try:
            activate_matplotlib(self._required_backend)
            configure_inline_support(shell, self._required_backend)
        except Exception:
            pass

    def _enable_inline_capture(self) -> None:
        if self._inline_capture_active:
            return
        target = str(self._required_backend).lower()
        if "matplotlib_inline" not in target:
            return
        try:
            from matplotlib_inline import backend_inline  # type: ignore
        except Exception:
            return
        display_fn = getattr(backend_inline, "display", None)
        if not callable(display_fn):
            return

        def capture_display(*args, **kwargs):
            figure = None
            if args:
                figure = args[0]
            elif "figure" in kwargs:
                figure = kwargs.get("figure")
            self._capture_inline_figure(figure)
            return None

        self._inline_display_original = display_fn
        backend_inline.display = capture_display
        self._inline_display_disabled = True
        self._inline_capture_active = True

    def _restore_inline_capture(self) -> None:
        if not self._inline_display_disabled:
            return
        try:
            from matplotlib_inline import backend_inline  # type: ignore
        except Exception:
            self._inline_display_disabled = False
            self._inline_display_original = None
            self._inline_capture_active = False
            return
        if callable(self._inline_display_original):
            backend_inline.display = self._inline_display_original
        self._inline_display_original = None
        self._inline_display_disabled = False
        self._inline_capture_active = False

    def _get_managers(self):
        from matplotlib._pylab_helpers import Gcf  # type: ignore

        return list(Gcf.get_all_fig_managers())  # type: ignore[attr-defined]

    def _render_manager(self, manager, reason: str) -> Optional[PlotEntry]:
        canvas = getattr(manager, "canvas", None)
        figure = getattr(canvas, "figure", None) if canvas else None
        return self._render_figure(figure, reason, manager)

    def _render_figure(self, figure, reason: str, manager=None) -> Optional[PlotEntry]:
        if figure is None:
            return None
        from matplotlib.backends.backend_agg import FigureCanvasAgg  # type: ignore

        canvas = getattr(figure, "canvas", None)
        if canvas is None:
            return None
        target_canvas = canvas
        if not hasattr(target_canvas, "print_png"):
            target_canvas = FigureCanvasAgg(figure)
        target_canvas.draw()
        buf = io.BytesIO()
        target_canvas.print_png(buf)
        width, height = target_canvas.get_width_height()
        figure_number = None
        if manager is not None:
            figure_number = getattr(manager, "num", None)
        if figure_number is None:
            figure_number = getattr(figure, "number", None)
        if figure_number is None:
            figure_number = 0
        label = figure.get_label() or f"Figure {figure_number}"
        title = ""
        suptitle = getattr(figure, "_suptitle", None)
        if suptitle is not None:
            title = suptitle.get_text()
        if not title and getattr(figure, "axes", None):
            if figure.axes:
                title = figure.axes[0].get_title()
        return PlotEntry(
            plot_id=str(uuid.uuid4()),
            figure_number=int(figure_number),
            label=label,
            title=title,
            reason=reason,
            backend=self._backend_name or "",
            created_at=_now(),
            width=int(width),
            height=int(height),
            dpi=float(getattr(figure, "dpi", 72.0)),
            png=buf.getvalue(),
        )

    def _capture_inline_figure(self, figure) -> None:
        self.sync_backend_state()
        if not self._backend_active:
            return
        entry = self._render_figure(getattr(figure, "figure", figure), "inline.flush")
        if entry:
            self._server_controller.add_entry(entry)
            self._close_figure(getattr(figure, "figure", figure))

    def _close_manager(self, manager) -> None:
        if not self._close_after_capture or manager is None:
            return
        canvas = getattr(manager, "canvas", None)
        figure = getattr(canvas, "figure", None) if canvas else None
        self._close_figure(figure)

    def _close_figure(self, figure) -> None:
        if not self._close_after_capture or figure is None:
            return
        try:
            import matplotlib.pyplot as plt  # type: ignore
        except Exception:
            return
        try:
            plt.close(figure)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Runtime that coordinates Matplotlib hooks and the HTTP server


class PlotRuntime:
    """Install Matplotlib hooks, capture figures, and expose browser controls."""

    def __init__(
        self, status_callback: Optional[Callable[[dict], None]] = None
    ) -> None:
        self._status_callback = status_callback
        self._required_backend = _PLOT_REQUIRED_BACKEND
        self._server_controller = _PlotServerController(
            lambda: self.status(), self._emit_status
        )
        self._hooks: Optional[_MatplotlibHookManager] = None
        self._hooks = _MatplotlibHookManager(
            required_backend=self._required_backend,
            server_controller=self._server_controller,
            status_changed=self._emit_status,
            capture_callback=self.capture,
        )

    @property
    def _server(self) -> Optional[PlotServer]:
        return self._server_controller.server

    @_server.setter
    def _server(self, value: Optional[PlotServer]) -> None:
        self._server_controller.inject_server(value)

    # Public API ---------------------------------------------------------

    def enable(self, options: Optional[dict] = None) -> dict:
        self._server_controller.configure(options)
        self._server_controller.ensure_running()
        if self._hooks:
            self._hooks.install()
            self._hooks.force_backend()
            self._hooks.sync_backend_state()
        return self._emit_status()

    def disable(self) -> dict:
        if self._hooks:
            self._hooks.disable()
        self._server_controller.shutdown()
        return self._emit_status({"status": "stopped"})

    def status(self) -> dict:
        payload = self._server_controller.status()
        hook_snapshot = (
            self._hooks.snapshot()
            if self._hooks
            else {
                "backend": None,
                "backend_active": True,
                "backend_required": self._required_backend,
            }
        )
        payload.update(hook_snapshot)
        return payload

    def capture(self, reason: str) -> None:
        if self._hooks:
            self._hooks.capture(reason)

    def handle_command(self, action: str, payload: Optional[dict] = None) -> dict:
        return self._server_controller.handle_command(action, payload)

    # Internals ----------------------------------------------------------

    def _emit_status(self, overrides: Optional[dict] = None) -> dict:
        payload = self.status()
        if overrides:
            payload.update(overrides)
        callback = self._status_callback
        if callback:
            try:
                callback(payload)
            except Exception:
                pass
        server = self._server_controller.server
        if server:
            server.events.publish(
                "backend-state",
                {
                    "backend": payload.get("backend"),
                    "active": payload.get("backend_active"),
                    "required": payload.get("backend_required"),
                },
            )
        return payload


def create_runtime(callback: Optional[Callable[[dict], None]] = None) -> PlotRuntime:
    return PlotRuntime(callback)


__all__ = ["PlotRuntime", "create_runtime"]
