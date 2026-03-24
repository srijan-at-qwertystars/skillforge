#!/usr/bin/env python3
"""
htmx-dev-server.py — Simple Python dev server for htmx development.

Features:
  - Serves HTML files with htmx CDN auto-injected
  - Live-reload via Server-Sent Events (SSE)
  - Example API endpoints for testing htmx patterns
  - File watcher for automatic reload on save

Usage:
  python htmx-dev-server.py [OPTIONS]

Options:
  --port PORT       Port to serve on (default: 8000)
  --dir DIR         Directory to serve (default: current directory)
  --no-reload       Disable live-reload
  --host HOST       Host to bind to (default: 127.0.0.1)
  --help            Show this help message

Examples:
  python htmx-dev-server.py
  python htmx-dev-server.py --port 3000 --dir ./public
  python htmx-dev-server.py --host 0.0.0.0 --port 8080
"""

import argparse
import json
import os
import sys
import threading
import time
from datetime import datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────

HTMX_VERSION = "2.0.4"
HYPERSCRIPT_VERSION = "0.9.14"

LIVE_RELOAD_SCRIPT = """
<script>
(function() {
  const evtSource = new EventSource("/__sse");
  evtSource.addEventListener("reload", () => location.reload());
  evtSource.onerror = () => setTimeout(() => location.reload(), 2000);
})();
</script>
"""

# In-memory items for the example API
example_items = [
    {"id": 1, "name": "Learn htmx", "done": False},
    {"id": 2, "name": "Build something awesome", "done": False},
]
next_id = 3


# ── File Watcher ─────────────────────────────────────────────────────

class FileWatcher:
    """Watches a directory for file changes and triggers reload events."""

    def __init__(self, watch_dir, extensions=None):
        self.watch_dir = Path(watch_dir)
        self.extensions = extensions or {".html", ".css", ".js", ".htm"}
        self.last_modified = {}
        self.has_changes = False
        self._scan()

    def _scan(self):
        """Scan directory and record modification times."""
        for path in self.watch_dir.rglob("*"):
            if path.is_file() and path.suffix in self.extensions:
                self.last_modified[str(path)] = path.stat().st_mtime

    def check(self):
        """Check for file changes. Returns True if changes detected."""
        changed = False
        current = {}
        for path in self.watch_dir.rglob("*"):
            if path.is_file() and path.suffix in self.extensions:
                key = str(path)
                mtime = path.stat().st_mtime
                current[key] = mtime
                if key not in self.last_modified or self.last_modified[key] != mtime:
                    changed = True
        self.last_modified = current
        self.has_changes = changed
        return changed


# ── SSE Clients ──────────────────────────────────────────────────────

sse_clients = []


def broadcast_reload():
    """Send reload event to all connected SSE clients."""
    dead = []
    for client in sse_clients:
        try:
            client["wfile"].write(b"event: reload\ndata: reload\n\n")
            client["wfile"].flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            dead.append(client)
    for d in dead:
        sse_clients.remove(d)


# ── Request Handler ──────────────────────────────────────────────────

class HtmxDevHandler(SimpleHTTPRequestHandler):
    """HTTP handler with htmx CDN injection, live-reload SSE, and example API."""

    live_reload = True

    def log_message(self, format, *args):
        """Colorized log output."""
        method = args[0].split()[0] if args else ""
        status = str(args[1]) if len(args) > 1 else ""
        color = "\033[32m" if status.startswith("2") else (
            "\033[33m" if status.startswith("3") else "\033[31m"
        )
        ts = datetime.now().strftime("%H:%M:%S")
        sys.stderr.write(f"\033[90m{ts}\033[0m {color}{format % args}\033[0m\n")

    def do_GET(self):
        if self.path == "/__sse":
            return self._handle_sse()
        if self.path.startswith("/__api/"):
            return self._handle_api_get()
        if self.path == "/__example":
            return self._serve_example_page()
        return self._serve_with_injection()

    def do_POST(self):
        if self.path.startswith("/__api/"):
            return self._handle_api_post()
        self.send_error(405, "Method not allowed")

    def do_DELETE(self):
        if self.path.startswith("/__api/"):
            return self._handle_api_delete()
        self.send_error(405, "Method not allowed")

    def do_PUT(self):
        if self.path.startswith("/__api/"):
            return self._handle_api_put()
        self.send_error(405, "Method not allowed")

    # ── SSE endpoint ─────────────────────────────────────────────────

    def _handle_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        sse_clients.append({"wfile": self.wfile})

        try:
            while True:
                self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
                time.sleep(15)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # ── HTML serving with htmx injection ─────────────────────────────

    def _serve_with_injection(self):
        # Let SimpleHTTPRequestHandler resolve the file path
        path = self.translate_path(self.path)

        if os.path.isdir(path):
            index = os.path.join(path, "index.html")
            if os.path.exists(index):
                path = index
            else:
                return super().do_GET()

        if not os.path.exists(path):
            return super().do_GET()

        if not path.endswith((".html", ".htm")):
            return super().do_GET()

        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # Inject htmx CDN if not already present
        if "htmx.org" not in content and "</head>" in content:
            inject = f'  <script src="https://unpkg.com/htmx.org@{HTMX_VERSION}"></script>\n'
            inject += f'  <script src="https://unpkg.com/hyperscript.org@{HYPERSCRIPT_VERSION}"></script>\n'
            content = content.replace("</head>", inject + "</head>")

        # Inject live-reload SSE script
        if self.live_reload and "/__sse" not in content and "</body>" in content:
            content = content.replace("</body>", LIVE_RELOAD_SCRIPT + "</body>")

        encoded = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(encoded))
        self.end_headers()
        self.wfile.write(encoded)

    # ── Example page ─────────────────────────────────────────────────

    def _serve_example_page(self):
        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>htmx Dev Server — Example Patterns</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }}
    h1 {{ color: #333; border-bottom: 2px solid #3d72b4; padding-bottom: 0.5rem; }}
    h2 {{ color: #3d72b4; margin-top: 2rem; }}
    .htmx-indicator {{ display: none; }}
    .htmx-request .htmx-indicator, .htmx-request.htmx-indicator {{ display: inline; }}
    .item {{ display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem; border-bottom: 1px solid #eee; }}
    .item.done span {{ text-decoration: line-through; color: #999; }}
    input {{ padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; }}
    button {{ padding: 0.4rem 0.8rem; border: 1px solid #ccc; border-radius: 4px; cursor: pointer; background: #f8f9fa; }}
    button:hover {{ background: #e9ecef; }}
    button.danger {{ color: #dc3545; border-color: #dc3545; }}
    .search-box {{ margin: 1rem 0; }}
    #toast {{ position: fixed; top: 1rem; right: 1rem; }}
    .toast-item {{ background: #28a745; color: white; padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 0.5rem; animation: fadeIn 0.3s; }}
    @keyframes fadeIn {{ from {{ opacity: 0; transform: translateY(-10px); }} }}
  </style>
</head>
<body>
  <h1>htmx Dev Server — Test Patterns</h1>
  <p>This page demonstrates htmx patterns using the built-in example API.</p>

  <h2>Active Search</h2>
  <div class="search-box">
    <input type="search" name="q" placeholder="Search items..."
           hx-get="/__api/items/search" hx-trigger="input changed delay:300ms"
           hx-target="#search-results" hx-indicator="#search-spinner">
    <span id="search-spinner" class="htmx-indicator">🔍 Searching...</span>
  </div>
  <div id="search-results"></div>

  <h2>Item List (CRUD)</h2>
  <form hx-post="/__api/items" hx-target="#item-list" hx-swap="innerHTML"
        _="on htmx:afterRequest reset() me">
    <input name="name" required placeholder="New item...">
    <button type="submit">Add</button>
    <span class="htmx-indicator">Adding...</span>
  </form>
  <div id="item-list" hx-get="/__api/items" hx-trigger="load">
    Loading...
  </div>
  <span id="item-count"></span>

  <h2>Click-to-Edit</h2>
  <div id="editable" hx-get="/__api/edit-demo" hx-trigger="load">Loading...</div>

  <div id="toast"></div>
</body>
</html>"""
        encoded = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(encoded))
        self.end_headers()
        self.wfile.write(encoded)

    # ── Example API endpoints ────────────────────────────────────────

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        body = self.rfile.read(length).decode("utf-8")
        from urllib.parse import parse_qs
        parsed = parse_qs(body)
        return {k: v[0] for k, v in parsed.items()}

    def _send_html(self, html, status=200, headers=None):
        encoded = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(encoded))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(encoded)

    def _render_items(self):
        html = ""
        for item in example_items:
            done_class = " done" if item["done"] else ""
            html += f"""<div id="item-{item['id']}" class="item{done_class}">
  <span>{item['name']}</span>
  <button hx-put="/__api/items/{item['id']}/toggle" hx-target="#item-{item['id']}" hx-swap="outerHTML">{'↩️' if item['done'] else '✅'}</button>
  <button class="danger" hx-delete="/__api/items/{item['id']}" hx-target="#item-{item['id']}" hx-swap="outerHTML swap:300ms" hx-confirm="Delete this item?">×</button>
</div>\n"""
        return html

    def _render_count(self):
        count = len(example_items)
        return f'<span id="item-count" hx-swap-oob="true">{count} item{"s" if count != 1 else ""}</span>'

    def _handle_api_get(self):
        global example_items

        if self.path == "/__api/items":
            html = self._render_items() + self._render_count()
            return self._send_html(html)

        if self.path.startswith("/__api/items/search"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            q = qs.get("q", [""])[0].lower()
            filtered = [i for i in example_items if q in i["name"].lower()]
            html = ""
            for item in filtered:
                html += f'<div class="item"><span>{item["name"]}</span></div>\n'
            if not filtered:
                html = "<p style='color:#999'>No items found.</p>"
            return self._send_html(html)

        if self.path == "/__api/edit-demo":
            html = """<div hx-target="this" hx-swap="outerHTML">
  <p><strong>Name:</strong> Jane Doe</p>
  <button hx-get="/__api/edit-demo/edit">Edit</button>
</div>"""
            return self._send_html(html)

        if self.path == "/__api/edit-demo/edit":
            html = """<form hx-put="/__api/edit-demo" hx-target="this" hx-swap="outerHTML">
  <input name="name" value="Jane Doe">
  <button type="submit">Save</button>
  <button type="button" hx-get="/__api/edit-demo" hx-target="this" hx-swap="outerHTML">Cancel</button>
</form>"""
            return self._send_html(html)

        self.send_error(404)

    def _handle_api_post(self):
        global next_id, example_items

        if self.path == "/__api/items":
            data = self._read_body()
            name = data.get("name", "").strip()
            if not name:
                return self._send_html(
                    '<div class="error">Name is required</div>', 422,
                    {"HX-Retarget": ".error", "HX-Reswap": "outerHTML"}
                )
            item = {"id": next_id, "name": name, "done": False}
            next_id += 1
            example_items.append(item)
            html = self._render_items() + self._render_count()
            return self._send_html(html, 201, {
                "HX-Trigger": json.dumps({"showToast": {"message": f"Added: {name}"}})
            })

        self.send_error(404)

    def _handle_api_delete(self):
        global example_items

        parts = self.path.split("/")
        if len(parts) == 4 and parts[2] == "items":
            item_id = int(parts[3])
            example_items = [i for i in example_items if i["id"] != item_id]
            return self._send_html(self._render_count())

        self.send_error(404)

    def _handle_api_put(self):
        global example_items

        if self.path == "/__api/edit-demo":
            data = self._read_body()
            name = data.get("name", "Jane Doe")
            html = f"""<div hx-target="this" hx-swap="outerHTML">
  <p><strong>Name:</strong> {name}</p>
  <button hx-get="/__api/edit-demo/edit">Edit</button>
</div>"""
            return self._send_html(html)

        parts = self.path.split("/")
        if len(parts) == 5 and parts[2] == "items" and parts[4] == "toggle":
            item_id = int(parts[3])
            for item in example_items:
                if item["id"] == item_id:
                    item["done"] = not item["done"]
                    done_class = " done" if item["done"] else ""
                    html = f"""<div id="item-{item['id']}" class="item{done_class}">
  <span>{item['name']}</span>
  <button hx-put="/__api/items/{item['id']}/toggle" hx-target="#item-{item['id']}" hx-swap="outerHTML">{'↩️' if item['done'] else '✅'}</button>
  <button class="danger" hx-delete="/__api/items/{item['id']}" hx-target="#item-{item['id']}" hx-swap="outerHTML swap:300ms" hx-confirm="Delete?">×</button>
</div>"""
                    return self._send_html(html)
            self.send_error(404)
            return

        self.send_error(404)


# ── Main ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="htmx development server with live-reload and example endpoints"
    )
    parser.add_argument("--port", type=int, default=8000, help="Port (default: 8000)")
    parser.add_argument("--dir", default=".", help="Directory to serve (default: .)")
    parser.add_argument("--host", default="127.0.0.1", help="Host (default: 127.0.0.1)")
    parser.add_argument("--no-reload", action="store_true", help="Disable live-reload")
    args = parser.parse_args()

    serve_dir = os.path.abspath(args.dir)
    os.chdir(serve_dir)

    HtmxDevHandler.live_reload = not args.no_reload

    # Start file watcher thread
    if not args.no_reload:
        watcher = FileWatcher(serve_dir)

        def watch_loop():
            while True:
                time.sleep(1)
                if watcher.check():
                    print(f"\033[33m[RELOAD]\033[0m File change detected, reloading clients...")
                    broadcast_reload()

        t = threading.Thread(target=watch_loop, daemon=True)
        t.start()

    server = HTTPServer((args.host, args.port), HtmxDevHandler)
    print(f"\033[32m[htmx-dev-server]\033[0m Serving {serve_dir}")
    print(f"\033[32m[htmx-dev-server]\033[0m http://{args.host}:{args.port}")
    print(f"\033[32m[htmx-dev-server]\033[0m Example page: http://{args.host}:{args.port}/__example")
    print(f"\033[32m[htmx-dev-server]\033[0m Live reload: {'enabled' if not args.no_reload else 'disabled'}")
    print(f"\033[90mPress Ctrl+C to stop\033[0m\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\033[32m[htmx-dev-server]\033[0m Shutting down...")
        server.server_close()


if __name__ == "__main__":
    main()
