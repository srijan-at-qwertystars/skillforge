#!/usr/bin/env bash
# setup-project.sh — Bootstrap an htmx project with a chosen backend, Tailwind CSS, and live reload.
#
# Usage:
#   ./setup-project.sh <project-name> <backend>
#
# Backends: express, flask, go
#
# Examples:
#   ./setup-project.sh my-app express
#   ./setup-project.sh dashboard flask
#   ./setup-project.sh api-server go

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

usage() {
  echo "Usage: $0 <project-name> <backend>"
  echo ""
  echo "Backends:"
  echo "  express  — Node.js + Express + EJS templates"
  echo "  flask    — Python + Flask + Jinja2 templates"
  echo "  go       — Go + net/http + html/template"
  echo ""
  echo "All backends include: htmx 2.x, Tailwind CSS (CDN), live reload."
  exit 1
}

[[ $# -lt 2 ]] && usage

PROJECT_NAME="$1"
BACKEND="$2"

[[ "$BACKEND" =~ ^(express|flask|go)$ ]] || error "Unknown backend '$BACKEND'. Choose: express, flask, go"
[[ -e "$PROJECT_NAME" ]] && error "Directory '$PROJECT_NAME' already exists."

log "Creating htmx project: $PROJECT_NAME (backend: $BACKEND)"
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# --- Common directories ---
mkdir -p templates/partials static/css static/js

# --- Base HTML layout ---
cat > templates/base.html << 'LAYOUT'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}App{% endblock %}</title>
  <script src="https://unpkg.com/htmx.org@2"></script>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    .htmx-indicator { display: none; }
    .htmx-request .htmx-indicator, .htmx-request.htmx-indicator { display: inline-block; }
    .htmx-swapping { opacity: 0; transition: opacity 300ms ease-out; }
  </style>
  {% block head %}{% endblock %}
</head>
<body class="bg-gray-50 text-gray-900 min-h-screen" hx-boost="true">
  <nav class="bg-white shadow px-6 py-3 flex justify-between items-center">
    <a href="/" class="text-xl font-bold">{{ project_name }}</a>
    <div id="notifications"></div>
  </nav>
  <main class="max-w-4xl mx-auto p-6">
    {% block content %}{% endblock %}
  </main>
  <div id="toast-container" class="fixed top-4 right-4 space-y-2 z-50"></div>
  <script>
    document.body.addEventListener('showToast', (evt) => {
      const msg = typeof evt.detail === 'string' ? evt.detail : evt.detail.value || evt.detail.message;
      const toast = document.createElement('div');
      toast.className = 'bg-green-500 text-white px-4 py-2 rounded shadow-lg transition-opacity';
      toast.textContent = msg;
      document.getElementById('toast-container').appendChild(toast);
      setTimeout(() => { toast.style.opacity = '0'; setTimeout(() => toast.remove(), 300); }, 3000);
    });
  </script>
</body>
</html>
LAYOUT

cat > templates/index.html << 'INDEX'
{% extends "base.html" %}
{% block title %}Home{% endblock %}
{% block content %}
<h1 class="text-3xl font-bold mb-6">Welcome to your htmx app</h1>
<div class="space-y-4">
  <div class="bg-white rounded-lg shadow p-6">
    <h2 class="text-xl font-semibold mb-4">Active Search Demo</h2>
    <input type="search" name="q"
           hx-get="/search"
           hx-trigger="input changed delay:300ms"
           hx-target="#search-results"
           hx-indicator="#search-spinner"
           class="border rounded px-3 py-2 w-full"
           placeholder="Search...">
    <span id="search-spinner" class="htmx-indicator text-gray-500 ml-2">Searching...</span>
    <div id="search-results" class="mt-4"></div>
  </div>
</div>
{% endblock %}
INDEX

cat > templates/partials/_search_results.html << 'SEARCH'
{% if results %}
<ul class="divide-y divide-gray-200">
  {% for item in results %}
  <li class="py-2">{{ item }}</li>
  {% endfor %}
</ul>
{% else %}
<p class="text-gray-500">No results found.</p>
{% endif %}
SEARCH

# --- Backend-specific setup ---
setup_express() {
  log "Setting up Express backend..."

  command -v node >/dev/null 2>&1 || error "Node.js is required. Install from https://nodejs.org"

  cat > package.json << PACKAGE
{
  "name": "${PROJECT_NAME}",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "start": "node server.js",
    "dev": "npx nodemon server.js"
  },
  "dependencies": {
    "express": "^4.18.0",
    "ejs": "^3.1.0"
  },
  "devDependencies": {
    "nodemon": "^3.0.0"
  }
}
PACKAGE

  cat > server.js << 'SERVER'
const express = require('express');
const path = require('path');
const app = express();
const PORT = process.env.PORT || 3000;

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'templates'));
app.use(express.static('static'));
app.use(express.urlencoded({ extended: true }));

// htmx detection middleware
app.use((req, res, next) => {
  req.isHtmx = req.headers['hx-request'] === 'true';
  if (req.isHtmx) res.set('Vary', 'HX-Request');
  next();
});

const ITEMS = ['Apple', 'Banana', 'Cherry', 'Date', 'Elderberry', 'Fig', 'Grape'];

app.get('/', (req, res) => {
  res.render('index', { project_name: process.env.PROJECT_NAME || 'My App' });
});

app.get('/search', (req, res) => {
  const q = (req.query.q || '').toLowerCase();
  const results = q ? ITEMS.filter(i => i.toLowerCase().includes(q)) : [];
  res.render('partials/_search_results', { results });
});

app.listen(PORT, () => console.log(`Server running at http://localhost:${PORT}`));
SERVER

  log "Installing dependencies..."
  npm install --quiet 2>/dev/null || warn "npm install failed — run manually"
  log "Run: cd $PROJECT_NAME && npm run dev"
}

setup_flask() {
  log "Setting up Flask backend..."

  command -v python3 >/dev/null 2>&1 || error "Python 3 is required."

  python3 -m venv venv
  # shellcheck disable=SC1091
  source venv/bin/activate

  pip install flask 2>/dev/null || warn "pip install failed — run manually"

  cat > app.py << 'FLASKAPP'
from flask import Flask, render_template, request

app = Flask(__name__, template_folder="templates", static_folder="static")

ITEMS = ["Apple", "Banana", "Cherry", "Date", "Elderberry", "Fig", "Grape"]

@app.route("/")
def index():
    return render_template("index.html", project_name="My App")

@app.route("/search")
def search():
    q = request.args.get("q", "").lower()
    results = [i for i in ITEMS if q in i.lower()] if q else []
    return render_template("partials/_search_results.html", results=results)

if __name__ == "__main__":
    app.run(debug=True, port=3000)
FLASKAPP

  cat > requirements.txt << 'REQS'
flask>=3.0
REQS

  # Flask uses Jinja2 natively — templates work with {% %} syntax
  log "Run: cd $PROJECT_NAME && source venv/bin/activate && python app.py"
}

setup_go() {
  log "Setting up Go backend..."

  command -v go >/dev/null 2>&1 || error "Go is required. Install from https://go.dev"

  go mod init "$PROJECT_NAME" 2>/dev/null

  cat > main.go << 'GOMAIN'
package main

import (
	"html/template"
	"net/http"
	"os"
	"strings"
)

var tmpl *template.Template

func init() {
	tmpl = template.Must(template.ParseGlob("templates/*.html"))
	template.Must(tmpl.ParseGlob("templates/partials/*.html"))
}

var items = []string{"Apple", "Banana", "Cherry", "Date", "Elderberry", "Fig", "Grape"}

func isHtmx(r *http.Request) bool {
	return r.Header.Get("HX-Request") == "true"
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	tmpl.ExecuteTemplate(w, "index.html", map[string]string{"project_name": "My App"})
}

func searchHandler(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(r.URL.Query().Get("q"))
	var results []string
	if q != "" {
		for _, item := range items {
			if strings.Contains(strings.ToLower(item), q) {
				results = append(results, item)
			}
		}
	}
	if isHtmx(r) {
		w.Header().Set("Vary", "HX-Request")
	}
	tmpl.ExecuteTemplate(w, "_search_results.html", map[string]interface{}{"results": results})
}

func main() {
	fs := http.FileServer(http.Dir("static"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))
	http.HandleFunc("/", indexHandler)
	http.HandleFunc("/search", searchHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	println("Server running at http://localhost:" + port)
	http.ListenAndServe(":"+port, nil)
}
GOMAIN

  # Adapt templates for Go's template syntax
  cat > templates/base.html << 'GOBASE'
{{define "base"}}<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{.title}}</title>
  <script src="https://unpkg.com/htmx.org@2"></script>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    .htmx-indicator { display: none; }
    .htmx-request .htmx-indicator { display: inline-block; }
  </style>
</head>
<body class="bg-gray-50 text-gray-900 min-h-screen" hx-boost="true">
  <nav class="bg-white shadow px-6 py-3"><a href="/" class="text-xl font-bold">{{.project_name}}</a></nav>
  <main class="max-w-4xl mx-auto p-6">{{template "content" .}}</main>
</body>
</html>{{end}}
GOBASE

  cat > templates/index.html << 'GOINDEX'
{{template "base" .}}
{{define "content"}}
<h1 class="text-3xl font-bold mb-6">Welcome to your htmx app</h1>
<div class="bg-white rounded-lg shadow p-6">
  <h2 class="text-xl font-semibold mb-4">Active Search Demo</h2>
  <input type="search" name="q"
         hx-get="/search"
         hx-trigger="input changed delay:300ms"
         hx-target="#search-results"
         hx-indicator="#search-spinner"
         class="border rounded px-3 py-2 w-full"
         placeholder="Search...">
  <span id="search-spinner" class="htmx-indicator text-gray-500 ml-2">Searching...</span>
  <div id="search-results" class="mt-4"></div>
</div>
{{end}}
GOINDEX

  cat > templates/partials/_search_results.html << 'GOSEARCH'
{{define "_search_results.html"}}
{{if .results}}
<ul class="divide-y divide-gray-200">
  {{range .results}}<li class="py-2">{{.}}</li>{{end}}
</ul>
{{else}}
<p class="text-gray-500">No results found.</p>
{{end}}
{{end}}
GOSEARCH

  log "Run: cd $PROJECT_NAME && go run main.go"
}

case "$BACKEND" in
  express) setup_express ;;
  flask)   setup_flask ;;
  go)      setup_go ;;
esac

log "Project '$PROJECT_NAME' created successfully!"
log "Structure:"
find . -type f | head -30 | sed 's|^./|  |'
