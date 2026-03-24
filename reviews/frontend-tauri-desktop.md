# QA Review: `frontend/tauri-desktop`

**Reviewer:** Copilot QA  
**Date:** 2025-07-17  
**Skill version:** SKILL.md (500 lines)  
**Supporting files:** 3 references, 3 scripts, 5 assets (~4,190 lines total)

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with TRIGGERS/NOT present |
| +/- triggers | ✅ Pass | 13 positive triggers, 5 negative exclusions |
| Under 500 lines | ✅ Pass | Exactly 500 lines (boundary) |
| Imperative voice | ✅ Pass | Uses imperative/descriptive throughout |
| Examples section | ✅ Pass | 3 worked examples (counter, minimize-to-tray, scoped FS) |
| References linked | ✅ Pass | 3 reference docs in table with descriptions |
| Scripts linked | ✅ Pass | 3 helper scripts with usage notes |
| Assets linked | ✅ Pass | 5 templates/patterns covering conf, Rust, React, capabilities, CI |

---

## b. Content Check — API Accuracy

### Verified Correct ✅

- **`invoke` import** from `@tauri-apps/api/core` — correct for v2 (replaces v1 `@tauri-apps/api/tauri`)
- **`#[tauri::command]`** syntax, `generate_handler![]`, `invoke_handler` — all correct
- **Event API** — `emit`/`listen` from `@tauri-apps/api/event` — correct
- **`use tauri::Emitter;`** — correct v2 trait import for `emit()`/`emit_to()`
- **Capabilities JSON format** — `identifier`, `windows`, `permissions`, `$schema` all match v2 spec
- **`WebviewWindowBuilder`** + `WebviewUrl` — correct v2 API (replaces v1 `WindowBuilder`)
- **Plugin system** — `.plugin(tauri_plugin_fs::init())` pattern is correct
- **Custom plugin builder** — `PluginBuilder::new("name").invoke_handler(...).setup(...).build()` — correct
- **System tray API** — `TrayIconBuilder`, `MouseButton`, `MouseButtonState` — correct v2 API
- **Menu API** — `MenuBuilder`, `SubmenuBuilder`, `MenuItemBuilder` — correct v2 API
- **CSP config** under `"app" > "security"` — correct v2 location
- **`freezePrototype`** security advice — correct and important
- **`#[cfg_attr(mobile, tauri::mobile_entry_point)]`** — correct v2 pattern (shown in Examples)

### Issues Found ⚠️

1. **Blocking I/O in async command (line 64–66):**  
   `std::fs::read_to_string` inside an `async fn` will block the tokio runtime thread. Should use `tokio::fs::read_to_string` or make the command sync. Misleading for users learning async patterns.

2. **Missing `use tauri::Listener;` import (line 129):**  
   The Rust `app_handle.listen(...)` call requires importing the `Listener` trait (`use tauri::Listener;`), but only `Emitter` is shown. Will fail to compile.

3. **Inconsistent entry point pattern:**  
   Lines 81–88 use `fn main()` directly (v1 style). Lines 447–455 correctly show `#[cfg_attr(mobile, tauri::mobile_entry_point)] pub fn run()` (v2 style). The early command registration example should use the `lib.rs` pattern to be consistent with v2 best practice.

4. **Missing `emit_to` gotcha:**  
   The `emit_to("main", ...)` example (line 128) doesn't mention that frontend listeners using global `listen()` will receive ALL events regardless of target. Users must use `getCurrentWindow().listen()` for window-scoped delivery. This is a documented v2 behavior change.

5. **Missing Channel API:**  
   Tauri v2 introduced the Channel API for streaming data from Rust to frontend (replaces repeated `emit` for progress). This is a significant v2 feature not covered in SKILL.md or referenced.

6. **Missing mobile support mention:**  
   Tauri v2's headline feature is iOS/Android support. Only mentioned in `references/advanced-patterns.md`, not in the main SKILL.md architecture section.

---

## c. Trigger Check

| Trigger | Specific to Tauri? | Risk |
|---------|-------------------|------|
| `"Tauri"`, `"tauri app"` | ✅ Exact match | None |
| `"tauri command"`, `"tauri plugin"`, `"tauri IPC"` | ✅ Exact match | None |
| `"create-tauri-app"`, `"tauri invoke"`, `"tauri events"` | ✅ Exact match | None |
| `"tauri window"`, `"tauri tray"`, `"tauri updater"` | ✅ Exact match | None |
| `"tauri capabilities"` | ✅ Exact match | None |
| `"desktop application with web frontend"` | ⚠️ Too broad | Would match Electron, NW.js, Neutralinojs |
| `"Rust backend desktop"` | ⚠️ Too broad | Would match Dioxus, Slint, Iced, egui |

**NOT triggers** correctly exclude: Electron, React Native, Flutter desktop, NW.js, general Rust.

**Verdict:** 11/13 triggers are precise. Two are overly broad and risk false positives for competing frameworks. Recommend narrowing to `"desktop app with Tauri"` / `"Rust Tauri backend"` or removing them.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Core APIs correct; blocking-async issue and missing Listener import are real compilation/runtime concerns |
| **Completeness** | 4 | Covers all major topics; missing Channel API, mobile support in main doc, and emit_to gotcha |
| **Actionability** | 5 | Excellent runnable examples, templates (conf, Rust patterns, React hooks, capabilities, CI/CD), helper scripts |
| **Trigger quality** | 3 | 2/13 triggers too broad — would false-positive on Electron and other Rust desktop frameworks |
| **Overall** | **4.0** | Solid skill with good structure and depth; needs targeted fixes for API accuracy and trigger precision |

---

## e. Recommendations

### Must Fix
1. Fix async command example: replace `std::fs::read_to_string` with `tokio::fs::read_to_string().await` or make it a sync command
2. Add `use tauri::Listener;` to the Rust event listening example
3. Narrow or remove overly broad triggers (`"desktop application with web frontend"`, `"Rust backend desktop"`)

### Should Fix
4. Standardize entry point examples on `lib.rs` + `#[cfg_attr(mobile, tauri::mobile_entry_point)]` pattern
5. Add `emit_to` scoping gotcha (use `getCurrentWindow().listen()` for targeted events)
6. Add Channel API section for streaming data patterns
7. Mention mobile (iOS/Android) support in the Architecture section

### Nice to Have
8. Add error handling patterns with `thiserror` in main SKILL.md (currently only in assets)
9. Add migration note (v1 → v2 key changes) for users coming from v1

---

## f. Issue Filing

**Overall = 4.0, no dimension ≤ 2 → no issue required.**

---

## g. SKILL.md Annotation

**Result: `pass`** (borderline — all fixes in "Must Fix" are recommended before production use)
