// Phoenix LiveView JavaScript Hooks Template
//
// Register hooks in app.js:
//   import { Hooks } from "./hooks"
//   let liveSocket = new LiveSocket("/live", Socket, {
//     hooks: Hooks,
//     params: { _csrf_token: csrfToken }
//   })
//
// Usage in HEEx:
//   <div id="unique-id" phx-hook="HookName" data-config={Jason.encode!(@config)}>

// ── Infinite Scroll ──────────────────────────────────────────────────
// Triggers "load-more" event when the sentinel element enters the viewport.
//
// Usage: <div id="scroll-sentinel" phx-hook="InfiniteScroll"></div>
const InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry.isIntersecting) {
          this.pushEvent("load-more", {});
        }
      },
      { rootMargin: "200px" } // trigger 200px before visible
    );
    this.observer.observe(this.el);
  },
  updated() {
    // Re-observe in case the element was replaced
    this.observer.disconnect();
    this.observer.observe(this.el);
  },
  destroyed() {
    this.observer.disconnect();
  },
};

// ── Clipboard Copy ───────────────────────────────────────────────────
// Copies text content to clipboard on click.
//
// Usage: <button id="copy-btn" phx-hook="Clipboard" data-content={@text}>Copy</button>
const Clipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.content || this.el.innerText;
      navigator.clipboard.writeText(text).then(() => {
        // Notify server (optional)
        this.pushEvent("copied", { text });

        // Visual feedback
        const original = this.el.innerText;
        this.el.innerText = "Copied!";
        setTimeout(() => (this.el.innerText = original), 2000);
      });
    });
  },
};

// ── Local Time ───────────────────────────────────────────────────────
// Converts UTC datetime to user's local timezone.
//
// Usage: <time id={"time-#{@id}"} phx-hook="LocalTime" datetime={@inserted_at}></time>
const LocalTime = {
  mounted() {
    this.updated();
  },
  updated() {
    const dt = new Date(this.el.getAttribute("datetime"));
    this.el.textContent = dt.toLocaleString();
    this.el.setAttribute("title", dt.toISOString());
  },
};

// ── Chart (generic) ──────────────────────────────────────────────────
// Initializes and updates a chart library (e.g., Chart.js, ECharts).
//
// Usage: <canvas id="my-chart" phx-hook="Chart" data-config={Jason.encode!(@chart_config)}></canvas>
const Chart = {
  mounted() {
    this.initChart();

    // Listen for server-pushed data updates
    this.handleEvent("chart-update", ({ data }) => {
      this.updateChart(data);
    });
  },
  updated() {
    // Re-read config from data attribute on LiveView re-render
    const config = JSON.parse(this.el.dataset.config || "{}");
    if (this.chart && config.data) {
      this.updateChart(config.data);
    }
  },
  destroyed() {
    if (this.chart) {
      this.chart.destroy();
      this.chart = null;
    }
  },
  initChart() {
    const config = JSON.parse(this.el.dataset.config || "{}");
    // Replace with your chart library initialization:
    // this.chart = new ChartJS(this.el, config);
    console.log("Chart initialized with config:", config);
  },
  updateChart(data) {
    // Replace with your chart library update logic:
    // this.chart.data = data;
    // this.chart.update();
    console.log("Chart updated with data:", data);
  },
};

// ── Sortable List ────────────────────────────────────────────────────
// Makes a list sortable via drag-and-drop. Pushes new order to server.
//
// Requires: sortablejs (npm install sortablejs)
// Usage: <div id="sortable-list" phx-hook="Sortable" phx-update="stream">...</div>
const Sortable = {
  mounted() {
    // Dynamic import to avoid bundling if not used
    import("sortablejs").then(({ default: SortableJS }) => {
      this.sortable = SortableJS.create(this.el, {
        animation: 150,
        ghostClass: "opacity-30",
        onEnd: (evt) => {
          const order = Array.from(this.el.children).map((el) => el.id);
          this.pushEvent("reorder", { order });
        },
      });
    });
  },
  destroyed() {
    if (this.sortable) {
      this.sortable.destroy();
    }
  },
};

// ── Focus Trap ───────────────────────────────────────────────────────
// Traps keyboard focus within a container (for modals, dialogs).
//
// Usage: <div id="modal" phx-hook="FocusTrap">...</div>
const FocusTrap = {
  mounted() {
    this.focusableSelector =
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    this.el.addEventListener("keydown", (e) => this.handleKeyDown(e));

    // Focus first focusable element
    requestAnimationFrame(() => {
      const first = this.el.querySelector(this.focusableSelector);
      if (first) first.focus();
    });
  },
  handleKeyDown(e) {
    if (e.key !== "Tab") return;

    const focusable = Array.from(
      this.el.querySelectorAll(this.focusableSelector)
    );
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  },
  destroyed() {
    // Focus returns to trigger element (handled by LiveView modal component)
  },
};

// ── Debounced Input ──────────────────────────────────────────────────
// Pushes events with custom debounce logic (for search-as-you-type beyond phx-debounce).
//
// Usage: <input id="search" phx-hook="DebouncedInput" data-event="search" data-delay="400" />
const DebouncedInput = {
  mounted() {
    const eventName = this.el.dataset.event || "search";
    const delay = parseInt(this.el.dataset.delay || "300", 10);

    this.el.addEventListener("input", (e) => {
      clearTimeout(this.timeout);
      this.timeout = setTimeout(() => {
        this.pushEvent(eventName, { value: e.target.value });
      }, delay);
    });
  },
  destroyed() {
    clearTimeout(this.timeout);
  },
};

// ── Server Push Handler ──────────────────────────────────────────────
// Generic hook that listens for server-pushed events and executes DOM operations.
//
// Usage: <div id="notifications" phx-hook="ServerPush"></div>
const ServerPush = {
  mounted() {
    // Listen for specific server events
    this.handleEvent("highlight", ({ selector }) => {
      const el = document.querySelector(selector);
      if (el) {
        el.classList.add("highlight");
        setTimeout(() => el.classList.remove("highlight"), 2000);
      }
    });

    this.handleEvent("scroll-to", ({ selector }) => {
      const el = document.querySelector(selector);
      if (el) {
        el.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    });

    this.handleEvent("download", ({ url, filename }) => {
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      a.click();
    });
  },
};

// ── Export all hooks ─────────────────────────────────────────────────
export const Hooks = {
  InfiniteScroll,
  Clipboard,
  LocalTime,
  Chart,
  Sortable,
  FocusTrap,
  DebouncedInput,
  ServerPush,
};

// ── Registration (app.js) ────────────────────────────────────────────
// import { Socket } from "phoenix"
// import { LiveSocket } from "phoenix_live_view"
// import { Hooks } from "./hooks"
//
// let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
// let liveSocket = new LiveSocket("/live", Socket, {
//   hooks: Hooks,
//   params: { _csrf_token: csrfToken },
//   dom: {
//     // Optional: preserve focused elements during patches
//     onBeforeElUpdated(from, to) {
//       if (from._x_dataStack) { window.Alpine.clone(from, to) }
//     }
//   }
// })
// liveSocket.connect()
