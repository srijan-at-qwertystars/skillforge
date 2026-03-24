// Stimulus Controller Template
//
// Features: targets, values (reactive), actions, outlets, lifecycle callbacks.
// Place in: app/javascript/controllers/<name>_controller.js
//
// HTML usage:
//   <div data-controller="example"
//        data-example-url-value="/api/search"
//        data-example-debounce-value="300"
//        data-example-open-value="false">
//
//     <input data-example-target="input"
//            data-action="input->example#search keydown.escape->example#clear">
//
//     <button data-action="click->example#toggle">Toggle</button>
//
//     <div data-example-target="results"></div>
//     <div data-example-target="count"></div>
//   </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  // ── Targets: elements referenced by this controller ───────────────────────
  static targets = ["input", "results", "count"]

  // ── Values: reactive data attributes with type coercion ───────────────────
  static values = {
    url:      { type: String,  default: "/search" },
    debounce: { type: Number,  default: 300 },
    open:     { type: Boolean, default: false },
    count:    { type: Number,  default: 0 },
  }

  // ── Outlets: references to other controllers ──────────────────────────────
  // static outlets = ["other-controller"]

  // ── CSS Classes: configurable class names ─────────────────────────────────
  static classes = ["active", "loading"]

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  connect() {
    // Called when controller is connected to the DOM
    this.abortController = new AbortController()
  }

  disconnect() {
    // Called when controller is disconnected from the DOM
    this.abortController.abort()
    if (this.timeout) clearTimeout(this.timeout)
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  // Debounced search — triggered by input event
  search() {
    if (this.timeout) clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      this.performSearch()
    }, this.debounceValue)
  }

  // Toggle visibility
  toggle() {
    this.openValue = !this.openValue
  }

  // Clear input and results
  clear() {
    if (this.hasInputTarget) this.inputTarget.value = ""
    if (this.hasResultsTarget) this.resultsTarget.innerHTML = ""
    this.countValue = 0
  }

  // ── Value change callbacks (reactive) ─────────────────────────────────────

  openValueChanged() {
    if (this.hasResultsTarget) {
      this.resultsTarget.classList.toggle("hidden", !this.openValue)
    }
  }

  countValueChanged() {
    if (this.hasCountTarget) {
      this.countTarget.textContent = `${this.countValue} results`
    }
  }

  // ── Private methods ───────────────────────────────────────────────────────

  async performSearch() {
    const query = this.hasInputTarget ? this.inputTarget.value.trim() : ""
    if (query.length < 2) return

    this.element.classList.add(this.loadingClass || "loading")

    try {
      const url = `${this.urlValue}?q=${encodeURIComponent(query)}`
      const response = await fetch(url, {
        headers: {
          "Accept": "text/vnd.turbo-stream.html, text/html",
          "X-Requested-With": "XMLHttpRequest",
        },
        signal: this.abortController.signal,
      })

      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const html = await response.text()

      if (this.hasResultsTarget) {
        this.resultsTarget.innerHTML = html
      }

      this.openValue = true
      this.countValue = this.resultsTarget.querySelectorAll("[data-result]").length
    } catch (error) {
      if (error.name !== "AbortError") {
        console.error("Search failed:", error)
      }
    } finally {
      this.element.classList.remove(this.loadingClass || "loading")
    }
  }
}
