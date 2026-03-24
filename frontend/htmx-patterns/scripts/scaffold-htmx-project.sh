#!/usr/bin/env bash
# scaffold-htmx-project.sh — Scaffolds a basic htmx project with a chosen backend.
#
# Usage:
#   ./scaffold-htmx-project.sh --backend django|flask|express|go [--name PROJECT_NAME] [--dir OUTPUT_DIR]
#
# Options:
#   --backend, -b   Backend framework: django, flask, express, go (required)
#   --name, -n      Project name (default: my-htmx-app)
#   --dir, -d       Output directory (default: current directory)
#   --help, -h      Show this help message
#
# Examples:
#   ./scaffold-htmx-project.sh --backend flask --name todo-app
#   ./scaffold-htmx-project.sh -b express -n my-project -d ~/projects

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
BACKEND=""
PROJECT_NAME="my-htmx-app"
OUTPUT_DIR="."

# ── Color output ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Usage ─────────────────────────────────────────────────────────────
usage() {
  head -20 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend|-b) BACKEND="$2"; shift 2 ;;
    --name|-n)    PROJECT_NAME="$2"; shift 2 ;;
    --dir|-d)     OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h)    usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$BACKEND" ]]; then
  err "Missing required --backend flag"
  usage
fi

case "$BACKEND" in
  django|flask|express|go) ;;
  *) err "Unsupported backend: $BACKEND (choose: django, flask, express, go)"; exit 1 ;;
esac

# ── Project root ──────────────────────────────────────────────────────
PROJECT_DIR="${OUTPUT_DIR}/${PROJECT_NAME}"
if [[ -d "$PROJECT_DIR" ]]; then
  err "Directory already exists: $PROJECT_DIR"
  exit 1
fi

info "Scaffolding htmx + ${BACKEND} project: ${PROJECT_NAME}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ── Shared: base HTML template ───────────────────────────────────────
create_base_html() {
  local tpl_dir="$1"
  mkdir -p "$tpl_dir"
  cat > "${tpl_dir}/base.html" << 'BASEHTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}htmx App{% endblock %}</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <script src="https://unpkg.com/hyperscript.org@0.9.14"></script>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body { font-family: system-ui, -apple-system, sans-serif; max-width: 800px; margin: 0 auto; padding: 1rem; }
    .htmx-indicator { display: none; }
    .htmx-request .htmx-indicator, .htmx-request.htmx-indicator { display: inline; }
    .htmx-swapping { opacity: 0; transition: opacity 0.3s ease-out; }
    .fade-in { animation: fadeIn 0.3s ease-in; }
    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    button { cursor: pointer; padding: 0.5rem 1rem; border: 1px solid #ccc; border-radius: 4px; background: #f8f9fa; }
    button:hover { background: #e9ecef; }
    input, select, textarea { padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; }
    .error { color: #dc3545; font-size: 0.875rem; }
    .success { color: #28a745; }
  </style>
</head>
<body>
  {% block content %}{% endblock %}
</body>
</html>
BASEHTML
}

# ── Django scaffold ──────────────────────────────────────────────────
scaffold_django() {
  info "Creating Django project structure..."
  mkdir -p app/{templates/{app/partials},static}

  cat > requirements.txt << 'EOF'
django>=5.0
django-htmx>=1.17
EOF

  cat > manage.py << 'MANAGE'
#!/usr/bin/env python
import os, sys
if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
MANAGE
  chmod +x manage.py

  mkdir -p config
  cat > config/__init__.py << 'EOF'
EOF

  cat > config/settings.py << 'SETTINGS'
import os
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_KEY = "change-me-in-production"
DEBUG = True
ALLOWED_HOSTS = ["*"]
INSTALLED_APPS = ["django.contrib.staticfiles", "django_htmx", "app"]
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django_htmx.middleware.HtmxMiddleware",
]
ROOT_URLCONF = "config.urls"
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "DIRS": [],
    "APP_DIRS": True,
    "OPTIONS": {"context_processors": ["django.template.context_processors.request"]},
}]
STATIC_URL = "/static/"
SETTINGS

  cat > config/urls.py << 'URLS'
from django.urls import path
from app import views

urlpatterns = [
    path("", views.index, name="index"),
    path("items/", views.item_list, name="item-list"),
    path("items/create/", views.item_create, name="item-create"),
]
URLS

  cat > app/__init__.py << 'EOF'
EOF

  cat > app/views.py << 'VIEWS'
from django.shortcuts import render
from django.http import HttpResponse

ITEMS = ["Learn htmx", "Build something"]

def index(request):
    return render(request, "app/index.html", {"items": ITEMS})

def item_list(request):
    return render(request, "app/partials/item_list.html", {"items": ITEMS})

def item_create(request):
    name = request.POST.get("name", "")
    if name:
        ITEMS.append(name)
    html = render(request, "app/partials/item_list.html", {"items": ITEMS}).content.decode()
    return HttpResponse(html)
VIEWS

  create_base_html "app/templates/app"

  cat > app/templates/app/index.html << 'INDEX'
{% extends "app/base.html" %}
{% block title %}htmx + Django{% endblock %}
{% block content %}
<h1>htmx + Django</h1>
<form hx-post="/items/create/" hx-target="#item-list" hx-swap="innerHTML"
      hx-headers='{"X-CSRFToken": "{{ csrf_token }}"}'>
  <input name="name" required placeholder="New item...">
  <button type="submit">Add</button>
</form>
<div id="item-list">
  {% include "app/partials/item_list.html" %}
</div>
{% endblock %}
INDEX

  cat > app/templates/app/partials/item_list.html << 'PARTIAL'
<ul>
{% for item in items %}
  <li>{{ item }}</li>
{% endfor %}
</ul>
PARTIAL

  ok "Django project scaffolded"
  info "Next steps:"
  echo "  cd ${PROJECT_DIR}"
  echo "  python -m venv venv && source venv/bin/activate"
  echo "  pip install -r requirements.txt"
  echo "  python manage.py runserver"
}

# ── Flask scaffold ───────────────────────────────────────────────────
scaffold_flask() {
  info "Creating Flask project structure..."
  mkdir -p {templates/partials,static}

  cat > requirements.txt << 'EOF'
flask>=3.0
EOF

  cat > app.py << 'APP'
from flask import Flask, render_template, request

app = Flask(__name__)
ITEMS = ["Learn htmx", "Build something"]

@app.route("/")
def index():
    return render_template("index.html", items=ITEMS)

@app.route("/items")
def item_list():
    return render_template("partials/item_list.html", items=ITEMS)

@app.route("/items", methods=["POST"])
def item_create():
    name = request.form.get("name", "")
    if name:
        ITEMS.append(name)
    return render_template("partials/item_list.html", items=ITEMS)

@app.route("/search")
def search():
    q = request.args.get("q", "").lower()
    filtered = [i for i in ITEMS if q in i.lower()]
    return render_template("partials/item_list.html", items=filtered)

if __name__ == "__main__":
    app.run(debug=True, port=5000)
APP

  create_base_html "templates"

  cat > templates/index.html << 'INDEX'
{% extends "base.html" %}
{% block title %}htmx + Flask{% endblock %}
{% block content %}
<h1>htmx + Flask</h1>
<input type="search" name="q" placeholder="Search..."
       hx-get="/search" hx-trigger="input changed delay:300ms"
       hx-target="#item-list">
<form hx-post="/items" hx-target="#item-list" hx-swap="innerHTML">
  <input name="name" required placeholder="New item...">
  <button type="submit">Add</button>
</form>
<div id="item-list">
  {% include "partials/item_list.html" %}
</div>
{% endblock %}
INDEX

  cat > templates/partials/item_list.html << 'PARTIAL'
<ul>
{% for item in items %}
  <li>{{ item }}</li>
{% endfor %}
</ul>
PARTIAL

  ok "Flask project scaffolded"
  info "Next steps:"
  echo "  cd ${PROJECT_DIR}"
  echo "  python -m venv venv && source venv/bin/activate"
  echo "  pip install -r requirements.txt"
  echo "  python app.py"
}

# ── Express scaffold ─────────────────────────────────────────────────
scaffold_express() {
  info "Creating Express project structure..."
  mkdir -p {views/partials,public}

  cat > package.json << 'PKG'
{
  "name": "htmx-express-app",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js"
  },
  "dependencies": {
    "express": "^4.18.0",
    "nunjucks": "^3.2.4"
  }
}
PKG

  cat > server.js << 'SERVER'
const express = require("express");
const nunjucks = require("nunjucks");
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.urlencoded({ extended: true }));
app.use(express.static("public"));

nunjucks.configure("views", { autoescape: true, express: app });

const items = ["Learn htmx", "Build something"];

// htmx detection middleware
app.use((req, res, next) => {
  req.htmx = req.headers["hx-request"] === "true";
  next();
});

app.get("/", (req, res) => {
  res.render("index.njk", { items });
});

app.get("/items", (req, res) => {
  res.render("partials/item_list.njk", { items });
});

app.post("/items", (req, res) => {
  const name = req.body.name;
  if (name) items.push(name);
  res.render("partials/item_list.njk", { items });
});

app.get("/search", (req, res) => {
  const q = (req.query.q || "").toLowerCase();
  const filtered = items.filter(i => i.toLowerCase().includes(q));
  res.render("partials/item_list.njk", { items: filtered });
});

app.listen(PORT, () => console.log(`Server running on http://localhost:${PORT}`));
SERVER

  cat > views/base.njk << 'BASE'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}htmx App{% endblock %}</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <script src="https://unpkg.com/hyperscript.org@0.9.14"></script>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 1rem; }
    .htmx-indicator { display: none; }
    .htmx-request .htmx-indicator { display: inline; }
    button { cursor: pointer; padding: 0.5rem 1rem; }
    input { padding: 0.5rem; }
  </style>
</head>
<body>
  {% block content %}{% endblock %}
</body>
</html>
BASE

  cat > views/index.njk << 'INDEX'
{% extends "base.njk" %}
{% block title %}htmx + Express{% endblock %}
{% block content %}
<h1>htmx + Express</h1>
<input type="search" name="q" placeholder="Search..."
       hx-get="/search" hx-trigger="input changed delay:300ms"
       hx-target="#item-list">
<form hx-post="/items" hx-target="#item-list" hx-swap="innerHTML">
  <input name="name" required placeholder="New item...">
  <button type="submit">Add</button>
</form>
<div id="item-list">
  {% include "partials/item_list.njk" %}
</div>
{% endblock %}
INDEX

  cat > views/partials/item_list.njk << 'PARTIAL'
<ul>
{% for item in items %}
  <li>{{ item }}</li>
{% endfor %}
</ul>
PARTIAL

  ok "Express project scaffolded"
  info "Next steps:"
  echo "  cd ${PROJECT_DIR}"
  echo "  npm install"
  echo "  npm run dev"
}

# ── Go scaffold ──────────────────────────────────────────────────────
scaffold_go() {
  info "Creating Go project structure..."
  mkdir -p {cmd/server,templates/partials,static}

  cat > go.mod << GOMOD
module ${PROJECT_NAME}

go 1.21
GOMOD

  cat > cmd/server/main.go << 'MAIN'
package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strings"
)

var items = []string{"Learn htmx", "Build something"}
var tmpl *template.Template

func main() {
	tmpl = template.Must(template.ParseGlob("templates/*.html"))
	template.Must(tmpl.ParseGlob("templates/partials/*.html"))

	http.HandleFunc("/", indexHandler)
	http.HandleFunc("/items", itemsHandler)
	http.HandleFunc("/search", searchHandler)
	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("static"))))

	log.Println("Server starting on http://localhost:8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func isHTMX(r *http.Request) bool {
	return r.Header.Get("HX-Request") == "true"
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	tmpl.ExecuteTemplate(w, "index.html", map[string]interface{}{"Items": items})
}

func itemsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		r.ParseForm()
		name := r.FormValue("name")
		if name != "" {
			items = append(items, name)
		}
	}
	tmpl.ExecuteTemplate(w, "item_list.html", map[string]interface{}{"Items": items})
}

func searchHandler(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(r.URL.Query().Get("q"))
	var filtered []string
	for _, item := range items {
		if strings.Contains(strings.ToLower(item), q) {
			filtered = append(filtered, item)
		}
	}
	tmpl.ExecuteTemplate(w, "item_list.html", map[string]interface{}{"Items": filtered})
}
MAIN

  cat > templates/index.html << 'INDEX'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>htmx + Go</title>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 1rem; }
    .htmx-indicator { display: none; }
    .htmx-request .htmx-indicator { display: inline; }
    button { cursor: pointer; padding: 0.5rem 1rem; }
    input { padding: 0.5rem; }
  </style>
</head>
<body>
  <h1>htmx + Go</h1>
  <input type="search" name="q" placeholder="Search..."
         hx-get="/search" hx-trigger="input changed delay:300ms"
         hx-target="#item-list">
  <form hx-post="/items" hx-target="#item-list" hx-swap="innerHTML">
    <input name="name" required placeholder="New item...">
    <button type="submit">Add</button>
  </form>
  <div id="item-list">
    {{template "item_list.html" .}}
  </div>
</body>
</html>
INDEX

  cat > templates/partials/item_list.html << 'PARTIAL'
{{define "item_list.html"}}
<ul>
{{range .Items}}
  <li>{{.}}</li>
{{end}}
</ul>
{{end}}
PARTIAL

  ok "Go project scaffolded"
  info "Next steps:"
  echo "  cd ${PROJECT_DIR}"
  echo "  go run cmd/server/main.go"
}

# ── Dispatch ─────────────────────────────────────────────────────────
case "$BACKEND" in
  django)  scaffold_django  ;;
  flask)   scaffold_flask   ;;
  express) scaffold_express ;;
  go)      scaffold_go      ;;
esac

echo ""
ok "Project scaffolded at: ${PROJECT_DIR}"
info "All templates include htmx 2.0.4 CDN, loading indicators, and basic CRUD patterns."
