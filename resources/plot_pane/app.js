const params = new URLSearchParams(window.location.search);
		const token = params.get("token");
		if (!token) {
			document.body.innerHTML = "<main style='padding:32px;font-size:1.1rem;'>Missing ?token=... parameter</main>";
			throw new Error("missing token");
		}

		const INLINE_BACKEND = "module://matplotlib_inline.backend_inline";
		const INLINE_LABEL = "inline";

		const state = {
			entries: [],
			selected: null,
			backend: null,
			backendActive: true,
			backendRequired: INLINE_LABEL,
		};

		const thumbnails = document.getElementById("thumbnails");
		const previewImage = document.getElementById("preview-image");
		const placeholder = document.getElementById("placeholder");
		const details = document.getElementById("details");
		const backendPill = document.getElementById("backend-pill");

		function auth(path) {
			const sep = path.includes("?") ? "&" : "?";
			return `${path}${sep}token=${encodeURIComponent(token)}`;
		}

		async function fetchJSON(path, options) {
			const res = await fetch(auth(path), options);
			if (!res.ok) {
				const payload = await res.text();
				throw new Error(payload);
			}
			return res.json();
		}

		function formatDate(ts) {
			if (!ts) {
				return "–";
			}
			return new Date(ts * 1000).toLocaleString();
		}

		function describeBackend(value) {
			if (!value || value === "unknown") {
				return "unknown";
			}
			const text = String(value);
			if (text.includes("matplotlib_inline")) {
				return INLINE_LABEL;
			}
			return text;
		}

		function renderBackend() {
			const backend = describeBackend(state.backend);
			const active = state.backendActive;
			backendPill.textContent = `Backend: ${backend}${active ? "" : " – paused"}`;
			backendPill.classList.toggle("paused", !active);
		}

		function renderSelection() {
			if (state.selected) {
				const src = auth(`/plots/${state.selected.id}.png`);
				previewImage.src = src;
				previewImage.style.display = "block";
				placeholder.style.display = "none";
				details.innerHTML = `
          <div><strong>Title:</strong> ${state.selected.title || "Figure " + state.selected.figure}</div>
          <div><strong>Size:</strong> ${state.selected.width}×${state.selected.height}px</div>
          <div><strong>DPI:</strong> ${state.selected.dpi}</div>
          <div><strong>Captured:</strong> ${formatDate(state.selected.created_at)}</div>
        `;
			} else {
				previewImage.style.display = "none";
				placeholder.style.display = "block";
				details.innerHTML = "<div>No plot selected.</div>";
			}
		}

		function renderThumbnails() {
			thumbnails.innerHTML = "";
			if (!state.entries.length) {
				const empty = document.createElement("div");
				empty.textContent = "No plots captured yet.";
				empty.style.opacity = "0.6";
				thumbnails.appendChild(empty);
				return;
			}
			const sorted = state.entries.slice().reverse();
			for (const entry of sorted) {
			const btn = document.createElement("div");
			btn.className = "thumb" + (state.selected && entry.id === state.selected.id ? " active" : "");
			const img = document.createElement("img");
			img.src = auth(`/plots/${entry.id}.png`);
			img.alt = entry.title || entry.label || entry.id;
			const caption = document.createElement("div");
			caption.className = "title";
			caption.textContent = entry.title || entry.label || "Plot";
			btn.appendChild(img);
			btn.appendChild(caption);
			btn.addEventListener("click", () => {
				selectPlot(entry.id);
			});
			thumbnails.appendChild(btn);
		}
		}

		function render() {
			renderBackend();
			renderSelection();
			renderThumbnails();
		}

		async function selectPlot(id) {
			try {
				const data = await fetchJSON(`/plots/${encodeURIComponent(id)}/select`, { method: "POST" });
				if (data && data.selected) {
					state.selected = data.selected;
					render();
				}
			} catch (err) {
				console.error(err);
			}
		}

		function wireButtons() {
			document.getElementById("btn-open").addEventListener("click", () => window.open(auth("/"), "_blank"));
			document.getElementById("btn-prev").addEventListener("click", () => fetchJSON("/plots/prev", { method: "POST" }));
			document.getElementById("btn-next").addEventListener("click", () => fetchJSON("/plots/next", { method: "POST" }));
			document.getElementById("btn-delete").addEventListener("click", () => fetchJSON("/plots/" + (state.selected && state.selected.id || ""), { method: "DELETE" }));
			document.getElementById("btn-clear").addEventListener("click", () => fetchJSON("/plots/clear", { method: "POST" }));
		}

		function attachEvents() {
			const ev = new EventSource(auth("/events"));
			ev.addEventListener("plot-sync", (event) => {
				const payload = JSON.parse(event.data || "{}");
				state.entries = payload.entries || [];
				state.selected = payload.selected || null;
				render();
			});
			ev.addEventListener("plot-added", (event) => {
				const payload = JSON.parse(event.data || "{}");
				state.entries = state.entries.filter((entry) => entry.id !== payload.id);
				state.entries.push(payload);
				renderThumbnails();
			});
			ev.addEventListener("plot-removed", (event) => {
				const payload = JSON.parse(event.data || "{}");
				state.entries = state.entries.filter((entry) => entry.id !== payload.id);
				if (state.selected && state.selected.id === payload.id) {
					state.selected = null;
				}
				render();
			});
			ev.addEventListener("plot-selected", (event) => {
				const payload = event.data ? JSON.parse(event.data) : null;
				state.selected = payload;
				renderSelection();
				renderThumbnails();
			});
			ev.addEventListener("backend-state", (event) => {
				const payload = JSON.parse(event.data || "{}");
				state.backend = payload.backend || state.backend;
				state.backendActive = payload.active !== false;
				if (payload.required) {
					state.backendRequired = payload.required;
				}
				renderBackend();
			});
			ev.addEventListener("error", () => {
				backendPill.textContent = "Connection lost. Reopen the viewer.";
				backendPill.classList.add("paused");
			});
		}

		async function bootstrap() {
			wireButtons();
			attachEvents();
			try {
				const snapshot = await fetchJSON("/plots");
				state.entries = snapshot.entries || [];
				state.selected = snapshot.selected || null;
			} catch (err) {
				console.error(err);
			}
			try {
				const status = await fetchJSON("/status");
				state.backend = status.backend;
				state.backendActive = status.backend_active !== false;
				if (status.backend_required) {
					state.backendRequired = status.backend_required;
				}
			} catch (err) {
				console.error(err);
			}
			render();
		}

		bootstrap();
