# QA Review: electron-apps

**Skill path:** `frontend/electron-apps/SKILL.md`
**Reviewed:** 2025-07-16
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter | ✅ | `name`, `description` with positive AND negative triggers |
| Under 500 lines | ✅ | 438 lines |
| Imperative voice | ✅ | Consistent throughout |
| Examples | ✅ | 3 worked examples (scaffold, secure IPC, cross-platform build) |
| References linked | ✅ | 3 reference docs (advanced-patterns, troubleshooting, security-guide) |
| Scripts linked | ✅ | 3 scripts (security-audit, setup-forge, build-and-sign), all `chmod +x` |
| Asset templates | ✅ | 5 production-ready templates (main process, preload, forge config, GH Actions, e-builder config) |

**Verdict:** Fully conformant structure.

---

## b. Content Check

### Verified Correct (via web search against Electron docs, 2024-2025)

- **contextIsolation default since v12** — confirmed
- **sandbox default since v20** — confirmed
- **nodeIntegration false by default** — confirmed
- **IPC patterns** — all 3 patterns (invoke/handle, send/on, MessageChannelMain) are accurate and use modern best practices
- **Security checklist** — all 9 items match official Electron security recommendations
- **protocol.handle()** — correct modern API (replaces deprecated `registerFileProtocol`)
- **utilityProcess.fork()** — correctly recommended over `child_process`
- **Electron Fuses** — mentioned in references and forge config template
- **Both Forge and electron-builder** — covered with decision guidance
- **Code signing** — correct for all 3 platforms (macOS/Windows/Linux)
- **@electron/rebuild** — correctly noted as newer alternative to `electron-rebuild`

### Missing Gotchas

1. **`webUtils.getPathForFile`** — Electron 32 removed the non-standard `File.path` property. The replacement `webUtils.getPathForFile()` is not mentioned anywhere in the skill. This is a common migration pitfall.
2. **`BaseWindow` + `WebContentsView`** — The main SKILL.md body doesn't cover `WebContentsView` or `BaseWindow` (only mentioned in references/advanced-patterns.md as "BrowserView replacement"). Given BrowserView is deprecated since v29/removed path, this deserves a callout in the main body.
3. **Electron 33 breaking changes** — macOS 10.15 (Catalina) support dropped, C++20 required for native modules. Not mentioned.
4. **`gatekeeperAssess`** in Example 3 — this electron-builder option is deprecated in recent versions; may confuse users on latest electron-builder.

### No Inaccuracies Found

All stated facts verified correct against official Electron documentation and release notes.

---

## c. Trigger Check

### Positive Triggers (22 terms)
`Electron`, `electron app`, `BrowserWindow`, `ipcMain`, `ipcRenderer`, `electron-builder`, `Electron Forge`, `main process`, `renderer process`, `preload script`, `contextBridge`, `electron-updater`, `electron packager`, `Tray`, `Menu`, `dialog`, `nativeTheme`, `protocol handler`, `systemPreferences`, `webContents`, `session`, `crashReporter`, plus "desktop app packaging for Windows/macOS/Linux using Electron."

### Negative Triggers
`NOT for Tauri, React Native, Flutter desktop, NW.js, PWAs, or general web development without Electron context.`

### False-Positive Analysis

| Scenario | Would it trigger? | Correct? |
|---|---|---|
| "Build a Tauri app with Rust" | No (explicit exclusion) | ✅ |
| "React Native desktop app" | No (explicit exclusion) | ✅ |
| "Build a menu component in React" | Unlikely — "Menu" alone is generic but combined trigger logic with other terms prevents this | ✅ |
| "Node.js main process" | Possible edge case — "main process" is somewhat generic | ⚠️ Minor |
| "Create an Electron app with Vue" | Yes | ✅ |
| "Set up a PWA with service workers" | No (explicit exclusion) | ✅ |
| "NW.js desktop packaging" | No (explicit exclusion) | ✅ |
| "General web dev with Webpack" | No ("without Electron context" qualifier) | ✅ |

**Verdict:** Excellent trigger specificity. One minor edge case ("main process" in non-Electron contexts) but low risk given combined matching.

---

## d. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | All stated facts verified correct. Minor: `gatekeeperAssess` may be deprecated in latest electron-builder. |
| **Completeness** | 4 | Excellent coverage of core Electron development. Missing `webUtils.getPathForFile` (Electron 32), `BaseWindow`/`WebContentsView` in main body, Electron 33 breaking changes. |
| **Actionability** | 5 | Copy-paste ready code. Security checklist is immediately actionable. Scripts automate auditing, scaffolding, and builds. 5 asset templates are production-ready. |
| **Trigger Quality** | 5 | 22 precise positive triggers, 6 explicit negative exclusions. Minimal false-positive risk. |
| **Overall** | **4.5** | High-quality, production-ready skill with minor gaps in latest Electron 32-33 breaking changes. |

---

## e. Recommendations

1. **Add `webUtils.getPathForFile` section** — Document the Electron 32 breaking change (`File.path` removal) and migration path. High impact for users upgrading.
2. **Surface `WebContentsView`/`BaseWindow` in main body** — Add a brief note or subsection since BrowserView is deprecated. Currently only in references.
3. **Add Electron 33 notes** — macOS 10.15 dropped, C++20 for native modules.
4. **Update Example 3** — Remove or annotate `gatekeeperAssess` as potentially deprecated.

---

## f. Issue Filing

**Overall score 4.5 ≥ 4.0** and **no dimension ≤ 2** → No GitHub issue required.

---

## g. Test Result

**PASS** — Skill is accurate, well-structured, and actionable. Recommended improvements are enhancements, not blockers.
