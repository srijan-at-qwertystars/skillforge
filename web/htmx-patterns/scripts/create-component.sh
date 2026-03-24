#!/usr/bin/env bash
# create-component.sh — Generate htmx component templates.
#
# Usage:
#   ./create-component.sh <component> [output-dir]
#
# Components: modal, infinite-scroll, inline-edit, search, tabs, file-upload
#
# Examples:
#   ./create-component.sh modal ./templates/partials
#   ./create-component.sh search .
#   ./create-component.sh inline-edit

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[component]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

COMPONENTS="modal, infinite-scroll, inline-edit, search, tabs, file-upload"

usage() {
  echo "Usage: $0 <component> [output-dir]"
  echo ""
  echo "Components: $COMPONENTS"
  echo ""
  echo "Generates an HTML file with htmx attributes and a companion server snippet."
  echo "Default output directory: current directory."
  exit 1
}

[[ $# -lt 1 ]] && usage

COMPONENT="$1"
OUTPUT_DIR="${2:-.}"

mkdir -p "$OUTPUT_DIR"

gen_modal() {
  local file="$OUTPUT_DIR/modal-component.html"
  cat > "$file" << 'HTML'
<!-- htmx Modal Component
     Trigger: button with hx-get loads modal content into #modal-container.
     Close:   Escape key, backdrop click, or cancel button.
     Submit:  Form inside modal posts to server; on success, closes modal and
              optionally triggers a refresh event via HX-Trigger header.
-->

<!-- Trigger button (place anywhere) -->
<button hx-get="/modal/new-item"
        hx-target="#modal-container"
        hx-swap="innerHTML"
        class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
  Open Modal
</button>

<!-- Container (place once in base layout) -->
<div id="modal-container"></div>

<!-- Server returns this on GET /modal/new-item -->
<template id="modal-template">
  <div id="modal-backdrop"
       class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
       hx-on:click="this.remove()">
    <div class="bg-white rounded-lg shadow-xl w-full max-w-md p-6 relative"
         hx-on:click="event.stopPropagation()">
      <button class="absolute top-3 right-3 text-gray-400 hover:text-gray-600"
              onclick="document.getElementById('modal-backdrop').remove()">✕</button>
      <h2 class="text-xl font-semibold mb-4">New Item</h2>
      <form hx-post="/items"
            hx-target="#item-list"
            hx-swap="beforeend"
            hx-on::after-request="document.getElementById('modal-backdrop')?.remove()">
        <div class="space-y-4">
          <div>
            <label class="block text-sm font-medium mb-1">Name</label>
            <input name="name" required class="w-full border rounded px-3 py-2">
          </div>
          <div>
            <label class="block text-sm font-medium mb-1">Description</label>
            <textarea name="description" rows="3" class="w-full border rounded px-3 py-2"></textarea>
          </div>
        </div>
        <div class="flex justify-end gap-3 mt-6">
          <button type="button"
                  onclick="document.getElementById('modal-backdrop').remove()"
                  class="px-4 py-2 text-gray-600 hover:text-gray-800">Cancel</button>
          <button type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">Save</button>
        </div>
      </form>
    </div>
  </div>
</template>

<!-- Keyboard close handler (add to base layout) -->
<script>
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    document.getElementById('modal-backdrop')?.remove();
  }
});
</script>
HTML
  log "Created: $file"
}

gen_infinite_scroll() {
  local file="$OUTPUT_DIR/infinite-scroll-component.html"
  cat > "$file" << 'HTML'
<!-- htmx Infinite Scroll Component
     The last item acts as a sentinel. When it scrolls into view (revealed),
     htmx fetches the next page. Server returns new items + a new sentinel,
     or an empty response when all items are loaded.
-->

<div id="feed" class="space-y-4">
  <!-- Existing items -->
  <div class="item bg-white p-4 rounded shadow">Item 1</div>
  <div class="item bg-white p-4 rounded shadow">Item 2</div>

  <!-- Sentinel: triggers next page load -->
  <div hx-get="/items?page=2"
       hx-trigger="revealed"
       hx-swap="outerHTML"
       hx-indicator="#scroll-spinner"
       class="text-center py-4">
    <span id="scroll-spinner" class="htmx-indicator text-gray-500">
      Loading more...
    </span>
  </div>
</div>

<!-- Server response for page 2 (replaces sentinel via outerHTML): -->
<template id="page-response-example">
  <div class="item bg-white p-4 rounded shadow">Item 3</div>
  <div class="item bg-white p-4 rounded shadow">Item 4</div>
  <!-- New sentinel for page 3 (omit if no more pages) -->
  <div hx-get="/items?page=3"
       hx-trigger="revealed"
       hx-swap="outerHTML"
       class="text-center py-4">
    <span class="htmx-indicator text-gray-500">Loading more...</span>
  </div>
</template>

<!-- Server snippet (Express):
app.get('/items', (req, res) => {
  const page = parseInt(req.query.page) || 1;
  const pageSize = 20;
  const items = getItems(page, pageSize);
  const hasMore = items.length === pageSize;
  res.render('partials/_items', { items, page, hasMore });
});
-->
HTML
  log "Created: $file"
}

gen_inline_edit() {
  local file="$OUTPUT_DIR/inline-edit-component.html"
  cat > "$file" << 'HTML'
<!-- htmx Inline Edit Component
     Double-click a cell to edit. Blur or Enter saves. Escape cancels.
     Server validates and returns the view-mode cell, or 422 with errors.
-->

<!-- View mode (each cell is independently editable) -->
<table class="w-full bg-white rounded shadow">
  <thead>
    <tr class="bg-gray-100">
      <th class="px-4 py-2 text-left">Name</th>
      <th class="px-4 py-2 text-left">Email</th>
      <th class="px-4 py-2 text-left">Actions</th>
    </tr>
  </thead>
  <tbody id="contact-table">
    <tr id="contact-1">
      <td class="px-4 py-2 cursor-pointer hover:bg-yellow-50"
          hx-get="/contacts/1/edit/name"
          hx-trigger="dblclick"
          hx-swap="innerHTML">John Doe</td>
      <td class="px-4 py-2 cursor-pointer hover:bg-yellow-50"
          hx-get="/contacts/1/edit/email"
          hx-trigger="dblclick"
          hx-swap="innerHTML">john@example.com</td>
      <td class="px-4 py-2">
        <button hx-delete="/contacts/1"
                hx-target="#contact-1"
                hx-swap="outerHTML swap:300ms"
                hx-confirm="Delete this contact?"
                class="text-red-500 hover:text-red-700">Delete</button>
      </td>
    </tr>
  </tbody>
</table>

<!-- Server returns this for GET /contacts/1/edit/name -->
<template id="edit-mode-example">
  <input name="value" value="John Doe"
         autofocus
         class="border rounded px-2 py-1 w-full"
         hx-put="/contacts/1/field/name"
         hx-trigger="blur, keyup[key=='Enter']"
         hx-target="closest td"
         hx-swap="innerHTML"
         hx-on:keyup="if(event.key==='Escape') htmx.ajax('GET','/contacts/1/view/name',{target:this.closest('td'),swap:'innerHTML'})">
</template>

<!-- CSS for delete animation -->
<style>
tr.htmx-swapping { opacity: 0; transition: opacity 300ms ease-out; }
td { transition: background-color 200ms; }
</style>
HTML
  log "Created: $file"
}

gen_search() {
  local file="$OUTPUT_DIR/search-component.html"
  cat > "$file" << 'HTML'
<!-- htmx Active Search Component
     Debounced search with loading indicator and result highlighting.
     Sends request 300ms after user stops typing.
-->

<div class="bg-white rounded-lg shadow p-6">
  <div class="relative">
    <input type="search" name="q"
           hx-get="/search"
           hx-trigger="input changed delay:300ms, search"
           hx-target="#search-results"
           hx-indicator="#search-indicator"
           hx-push-url="true"
           class="w-full border rounded-lg px-4 py-3 pl-10 focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
           placeholder="Search..."
           autocomplete="off">
    <!-- Search icon -->
    <svg class="absolute left-3 top-3.5 h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
    </svg>
    <!-- Loading spinner -->
    <span id="search-indicator" class="htmx-indicator absolute right-3 top-3.5 text-gray-400">
      ⏳
    </span>
  </div>
  <!-- Results container -->
  <div id="search-results" class="mt-4"></div>
</div>

<!-- Server response example (GET /search?q=foo) -->
<template id="results-example">
  <p class="text-sm text-gray-500 mb-2">3 results for "foo"</p>
  <ul class="divide-y divide-gray-200">
    <li class="py-3 hover:bg-gray-50 px-2 rounded">
      <a href="/items/1" class="block">
        <span class="font-medium">Foo Widget</span>
        <span class="text-sm text-gray-500 block">A fantastic foo-flavored widget</span>
      </a>
    </li>
  </ul>
</template>

<!-- Empty state -->
<template id="empty-example">
  <div class="text-center py-8 text-gray-500">
    <p class="text-lg">No results found</p>
    <p class="text-sm mt-1">Try a different search term</p>
  </div>
</template>
HTML
  log "Created: $file"
}

gen_tabs() {
  local file="$OUTPUT_DIR/tabs-component.html"
  cat > "$file" << 'HTML'
<!-- htmx Tabs Component
     Each tab loads content from the server. Active state is managed via
     hx-on::after-request. Supports URL push for bookmarkable tabs.
-->

<div class="bg-white rounded-lg shadow">
  <!-- Tab navigation -->
  <div id="tab-nav" class="flex border-b" role="tablist"
       hx-target="#tab-content" hx-swap="innerHTML transition:true">
    <button role="tab"
            hx-get="/tabs/overview"
            hx-push-url="/dashboard?tab=overview"
            hx-on::after-request="activateTab(this)"
            class="tab-btn px-6 py-3 font-medium border-b-2 border-blue-500 text-blue-600"
            aria-selected="true">
      Overview
    </button>
    <button role="tab"
            hx-get="/tabs/analytics"
            hx-push-url="/dashboard?tab=analytics"
            hx-on::after-request="activateTab(this)"
            class="tab-btn px-6 py-3 font-medium border-b-2 border-transparent text-gray-500 hover:text-gray-700"
            aria-selected="false">
      Analytics
    </button>
    <button role="tab"
            hx-get="/tabs/settings"
            hx-push-url="/dashboard?tab=settings"
            hx-on::after-request="activateTab(this)"
            class="tab-btn px-6 py-3 font-medium border-b-2 border-transparent text-gray-500 hover:text-gray-700"
            aria-selected="false">
      Settings
    </button>
  </div>

  <!-- Tab content area -->
  <div id="tab-content" class="p-6">
    <!-- Initial content loaded server-side -->
    <p>Overview content here...</p>
  </div>
</div>

<script>
function activateTab(selectedTab) {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.classList.remove('border-blue-500', 'text-blue-600');
    btn.classList.add('border-transparent', 'text-gray-500');
    btn.setAttribute('aria-selected', 'false');
  });
  selectedTab.classList.remove('border-transparent', 'text-gray-500');
  selectedTab.classList.add('border-blue-500', 'text-blue-600');
  selectedTab.setAttribute('aria-selected', 'true');
}
</script>
HTML
  log "Created: $file"
}

gen_file_upload() {
  local file="$OUTPUT_DIR/file-upload-component.html"
  cat > "$file" << 'HTML'
<!-- htmx File Upload Component
     Supports multipart uploads with progress bar.
     Uses hx-encoding="multipart/form-data" and htmx:xhr:progress event.
-->

<div class="bg-white rounded-lg shadow p-6">
  <form hx-post="/upload"
        hx-encoding="multipart/form-data"
        hx-target="#upload-result"
        hx-swap="innerHTML"
        hx-indicator="#upload-indicator"
        class="space-y-4">

    <!-- Drop zone -->
    <div id="drop-zone"
         class="border-2 border-dashed border-gray-300 rounded-lg p-8 text-center hover:border-blue-500 transition-colors">
      <input type="file" name="files" multiple
             accept="image/*,.pdf,.doc,.docx"
             class="hidden" id="file-input"
             onchange="updateFileList(this)">
      <label for="file-input" class="cursor-pointer">
        <p class="text-gray-500 text-lg">Drop files here or click to browse</p>
        <p class="text-gray-400 text-sm mt-1">Max 10MB per file</p>
      </label>
      <div id="file-list" class="mt-4 text-sm text-gray-600"></div>
    </div>

    <!-- Progress bar -->
    <div id="upload-indicator" class="htmx-indicator">
      <div class="w-full bg-gray-200 rounded-full h-2">
        <div id="progress-bar" class="bg-blue-600 h-2 rounded-full transition-all" style="width: 0%"></div>
      </div>
      <p id="progress-text" class="text-sm text-gray-500 mt-1">Uploading... 0%</p>
    </div>

    <button type="submit"
            class="px-6 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50">
      Upload
    </button>
  </form>

  <div id="upload-result" class="mt-4"></div>
</div>

<script>
// Progress tracking
htmx.on('htmx:xhr:progress', function(evt) {
  if (evt.detail.lengthComputable) {
    const pct = Math.round((evt.detail.loaded / evt.detail.total) * 100);
    document.getElementById('progress-bar').style.width = pct + '%';
    document.getElementById('progress-text').textContent = 'Uploading... ' + pct + '%';
  }
});

// File list display
function updateFileList(input) {
  const list = document.getElementById('file-list');
  const files = Array.from(input.files);
  list.innerHTML = files.map(f =>
    '<span class="inline-block bg-gray-100 rounded px-2 py-1 mr-2 mb-1">' +
    f.name + ' (' + (f.size / 1024).toFixed(1) + ' KB)</span>'
  ).join('');
}

// Drag and drop
const dz = document.getElementById('drop-zone');
dz.addEventListener('dragover', (e) => { e.preventDefault(); dz.classList.add('border-blue-500', 'bg-blue-50'); });
dz.addEventListener('dragleave', () => { dz.classList.remove('border-blue-500', 'bg-blue-50'); });
dz.addEventListener('drop', (e) => {
  e.preventDefault();
  dz.classList.remove('border-blue-500', 'bg-blue-50');
  document.getElementById('file-input').files = e.dataTransfer.files;
  updateFileList(document.getElementById('file-input'));
});
</script>
HTML
  log "Created: $file"
}

case "$COMPONENT" in
  modal)           gen_modal ;;
  infinite-scroll) gen_infinite_scroll ;;
  inline-edit)     gen_inline_edit ;;
  search)          gen_search ;;
  tabs)            gen_tabs ;;
  file-upload)     gen_file_upload ;;
  *)               error "Unknown component '$COMPONENT'. Available: $COMPONENTS" ;;
esac

log "Done! Include the generated HTML in your templates."
