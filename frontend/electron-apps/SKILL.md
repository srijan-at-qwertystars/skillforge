---
name: electron-apps
description: >
  Guide for building desktop applications with Electron. Use when user mentions
  "Electron", "electron app", "BrowserWindow", "ipcMain", "ipcRenderer",
  "electron-builder", "Electron Forge", "main process", "renderer process",
  "preload script", "contextBridge", "electron-updater", "electron packager",
  "Tray", "Menu", "dialog", "nativeTheme", "protocol handler", "systemPreferences",
  "webContents", "session", "crashReporter", or desktop app packaging for
  Windows/macOS/Linux using Electron. NOT for Tauri, React Native, Flutter desktop,
  NW.js, PWAs, or general web development without Electron context.
---

# Electron Application Development

## Architecture

Electron apps run two process types:

- **Main process**: Node.js environment. Creates windows, manages app lifecycle, accesses native APIs. Entry point in `package.json` `"main"` field. One per app.
- **Renderer process**: Chromium-based. Renders UI with HTML/CSS/JS. One per `BrowserWindow`. Sandboxed by default—no direct Node.js access.
- **Preload scripts**: Bridge between main and renderer. Run before renderer content loads with access to `contextBridge` and limited Node.js APIs when sandboxed.
- **Utility process**: Spawned via `utilityProcess.fork()` for CPU-intensive tasks without blocking the main process. Preferred over `child_process` for native module support.

## Project Setup

### With Electron Forge (recommended for new projects)
```bash
npm init electron-app@latest my-app -- --template=webpack-typescript
cd my-app && npm start
```

### Minimal manual setup
```bash
npm init -y && npm install electron --save-dev
```

```json
// package.json
{
  "main": "main.js",
  "scripts": { "start": "electron ." }
}
```

## BrowserWindow Configuration

```js
const { app, BrowserWindow } = require('electron');
const path = require('node:path');

function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    titleBarStyle: 'hiddenInset', // macOS frameless with traffic lights
    trafficLightPosition: { x: 15, y: 15 },
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,    // ALWAYS true (default since v12)
      nodeIntegration: false,    // ALWAYS false (default)
      sandbox: true,             // Enable Chromium sandbox (default since v20)
      webSecurity: true,
    },
  });
  win.loadFile('index.html'); // or win.loadURL('http://localhost:3000') for dev
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
```

## IPC Communication

### Pattern 1: Renderer → Main (invoke/handle) — preferred for request/response
```js
// main.js
const { ipcMain } = require('electron');
ipcMain.handle('read-file', async (_event, filePath) => {
  const { readFile } = require('node:fs/promises');
  return readFile(filePath, 'utf-8');
});

// preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('electronAPI', {
  readFile: (path) => ipcRenderer.invoke('read-file', path),
});

// renderer.js
const content = await window.electronAPI.readFile('/tmp/data.txt');
```

### Pattern 2: Main → Renderer (send/on)
```js
// main.js — send to specific window
win.webContents.send('update-available', { version: '2.0.0' });

// preload.js — expose listener registration
contextBridge.exposeInMainWorld('electronAPI', {
  onUpdateAvailable: (callback) => ipcRenderer.on('update-available', (_e, data) => callback(data)),
});
```

### Pattern 3: Bidirectional with ports (MessageChannel)
```js
// main.js
const { MessageChannelMain } = require('electron');
const { port1, port2 } = new MessageChannelMain();
win.webContents.postMessage('port', null, [port2]);
port1.on('message', (event) => { /* handle */ });
port1.start();
```

### IPC Security Rules
- NEVER expose raw `ipcRenderer.send` or `ipcRenderer.on` to the renderer
- Always wrap IPC calls in specific, named functions via `contextBridge`
- Validate all arguments in main process handlers
- Use `invoke`/`handle` over `send`/`on` for request-response patterns

## Preload Script (secure pattern)

```js
// preload.js
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  // Typed, scoped API surface — no raw IPC exposure
  getSystemInfo: () => ipcRenderer.invoke('get-system-info'),
  saveFile: (name, data) => ipcRenderer.invoke('save-file', name, data),
  onProgress: (cb) => {
    const handler = (_event, value) => cb(value);
    ipcRenderer.on('progress', handler);
    return () => ipcRenderer.removeListener('progress', handler); // cleanup
  },
});
```

## Security Checklist

1. **contextIsolation: true** — always (prevents prototype pollution attacks)
2. **nodeIntegration: false** — always (prevents require() in renderer)
3. **sandbox: true** — always (Chromium OS-level sandbox)
4. **webSecurity: true** — never disable (enforces same-origin policy)
5. **Content Security Policy** — set in HTML or via `session.webRequest`:
```js
session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
  callback({
    responseHeaders: {
      ...details.responseHeaders,
      'Content-Security-Policy': ["default-src 'self'; script-src 'self'"],
    },
  });
});
```
6. **Never load remote content** in windows with elevated privileges
7. **Validate all IPC inputs** in main process handlers
8. **Use `shell.openExternal` carefully** — validate URLs against allowlists
9. **Disable `allowRunningInsecureContent`** and **`experimentalFeatures`**

## Menu and Tray

```js
const { Menu, Tray, nativeImage } = require('electron');

// Application menu
const template = [
  {
    label: 'File',
    submenu: [
      { label: 'New', accelerator: 'CmdOrCtrl+N', click: () => createWindow() },
      { type: 'separator' },
      { role: 'quit' },
    ],
  },
  { role: 'editMenu' },
  { role: 'viewMenu' },
];
Menu.setApplicationMenu(Menu.buildFromTemplate(template));

// System tray
const tray = new Tray(nativeImage.createFromPath('icon.png'));
tray.setToolTip('My App');
tray.setContextMenu(Menu.buildFromTemplate([
  { label: 'Show', click: () => win.show() },
  { label: 'Quit', click: () => app.quit() },
]));
```

## Dialog and File System

```js
const { dialog } = require('electron');

// Open file
const { canceled, filePaths } = await dialog.showOpenDialog(win, {
  properties: ['openFile', 'multiSelections'],
  filters: [{ name: 'Images', extensions: ['jpg', 'png', 'gif'] }],
});

// Save file
const { canceled, filePath } = await dialog.showSaveDialog(win, {
  defaultPath: 'export.pdf',
  filters: [{ name: 'PDF', extensions: ['pdf'] }],
});

// Message box
const { response } = await dialog.showMessageBox(win, {
  type: 'warning',
  buttons: ['Cancel', 'Delete'],
  defaultId: 0,
  cancelId: 0,
  message: 'Delete this item?',
});
```

## Auto-Updater

### With electron-updater (electron-builder ecosystem)
```js
const { autoUpdater } = require('electron-updater');

autoUpdater.autoDownload = false;
autoUpdater.checkForUpdates();

autoUpdater.on('update-available', (info) => {
  dialog.showMessageBox({ message: `Update ${info.version} available` }).then(() => {
    autoUpdater.downloadUpdate();
  });
});
autoUpdater.on('update-downloaded', () => { autoUpdater.quitAndInstall(); });
```

Requires a `publish` config in `package.json` pointing to GitHub Releases, S3, or a generic server.

## Native Modules

Compile native addons for Electron's Node.js version:
```bash
npm install electron-rebuild --save-dev
npx electron-rebuild  # run after installing native deps
```

Or use `@electron/rebuild` (newer):
```bash
npx @electron/rebuild
```

For `node-gyp` based modules, set `ELECTRON_RUN_AS_NODE=1` or use prebuild/prebuildify for precompiled binaries.

## Packaging and Distribution

### Electron Forge
```bash
# Add to existing project
npx electron-forge import
# Build distributables
npm run make
# Publish to GitHub Releases
npm run publish
```

### electron-builder
```json
// package.json
{
  "build": {
    "appId": "com.example.myapp",
    "mac": { "target": ["dmg", "zip"], "category": "public.app-category.developer-tools" },
    "win": { "target": ["nsis", "portable"] },
    "linux": { "target": ["AppImage", "deb"] },
    "publish": [{ "provider": "github" }]
  }
}
```
```bash
npx electron-builder --mac --win --linux
```

### Code Signing
- **macOS**: Requires Apple Developer certificate. Set `CSC_LINK` (path/base64 of .p12) and `CSC_KEY_PASSWORD` env vars. Notarize with `@electron/notarize` or electron-builder's `afterSign` hook.
- **Windows**: Requires Authenticode certificate (.pfx). Set `WIN_CSC_LINK` and `WIN_CSC_KEY_PASSWORD`.
- **Linux**: No mandatory signing, but GPG-sign packages for trust.

### Forge vs electron-builder decision
- **Electron Forge**: Integrated dev experience, scaffolding, Vite/Webpack support, simpler config. Best for new projects.
- **electron-builder**: More output formats, superior CI/CD integration, advanced auto-update, finer code-signing control. Best for production distribution.

## Performance Optimization

- **Lazy-load windows**: Don't create all windows at startup
- **Defer non-critical requires**: Use dynamic `import()` or lazy `require()` in main process
- **Use `backgroundThrottling: false`** only when needed (e.g., music players)
- **V8 snapshots**: Electron Forge supports custom snapshots to speed startup
- **Minimize renderer bundle**: Tree-shake, code-split with Webpack/Vite
- **Offload CPU work**: Use `utilityProcess.fork()` or Web Workers instead of blocking main
- **Profile with DevTools**: `chrome://tracing`, Performance tab, `process.getHeapStatistics()`
- **Avoid synchronous IPC**: Always use `invoke`/`handle`, never `sendSync`
- **Preload wisely**: Keep preload scripts minimal—heavy initialization slows window creation

## Debugging

```bash
# Launch with DevTools and verbose logging
ELECTRON_ENABLE_LOGGING=1 electron . --inspect=5858

# Debug main process with VS Code
# .vscode/launch.json
{
  "type": "node",
  "request": "launch",
  "name": "Debug Main",
  "runtimeExecutable": "${workspaceFolder}/node_modules/.bin/electron",
  "args": ["."],
  "cwd": "${workspaceFolder}"
}
```

- **Renderer**: DevTools (Ctrl+Shift+I / Cmd+Opt+I) or `win.webContents.openDevTools()`
- **Main process**: `--inspect` flag + Chrome `chrome://inspect` or VS Code attach
- **Production crashes**: Use `crashReporter.start()` to collect minidumps

## Protocol Handlers

### Custom protocol (serving local files securely)
```js
const { protocol } = require('electron');

protocol.handle('app', (request) => {
  const url = new URL(request.url);
  const filePath = path.join(__dirname, 'dist', url.pathname);
  return net.fetch(pathToFileURL(filePath).toString());
});

// Register as default handler for a URI scheme
app.setAsDefaultProtocolClient('myapp'); // handles myapp://...
```

### Deep linking
```js
// macOS: handle open-url event
app.on('open-url', (event, url) => { event.preventDefault(); handleDeepLink(url); });
// Windows/Linux: parse process.argv for the protocol URL in single-instance lock
app.on('second-instance', (_e, argv) => { handleDeepLink(argv.find(a => a.startsWith('myapp://'))); });
```

## Examples

### Example 1: Scaffold a new Electron + React + TypeScript app

Input: "Create a new Electron app with React and TypeScript"

Output:
```bash
npm init electron-app@latest my-app -- --template=vite-typescript
cd my-app
npm install react react-dom
npm install -D @types/react @types/react-dom
npm start
```
Configure `vite.renderer.config.ts` to handle JSX/TSX. The Vite template provides HMR out of the box.

### Example 2: Secure IPC for file operations

Input: "Let the renderer read and write files safely"

Output:
```js
// main.js
ipcMain.handle('read-file', async (_e, filePath) => {
  if (!filePath.startsWith(app.getPath('userData'))) throw new Error('Access denied');
  return fs.promises.readFile(filePath, 'utf-8');
});
ipcMain.handle('write-file', async (_e, filePath, content) => {
  if (!filePath.startsWith(app.getPath('userData'))) throw new Error('Access denied');
  await fs.promises.writeFile(filePath, content, 'utf-8');
});

// preload.js
contextBridge.exposeInMainWorld('fileAPI', {
  read: (p) => ipcRenderer.invoke('read-file', p),
  write: (p, c) => ipcRenderer.invoke('write-file', p, c),
});
```
Key: Validate paths in the main process to prevent directory traversal.

### Example 3: Build and publish for all platforms

Input: "Package my Electron app for macOS, Windows, and Linux with auto-update"

Output:
```bash
npm install electron-builder electron-updater --save-dev
```
```json
{
  "build": {
    "appId": "com.company.app",
    "mac": { "target": "dmg", "hardenedRuntime": true, "gatekeeperAssess": false },
    "win": { "target": "nsis" },
    "linux": { "target": "AppImage" },
    "publish": [{ "provider": "github", "owner": "you", "repo": "app" }]
  }
}
```
```bash
CSC_LINK=cert.p12 CSC_KEY_PASSWORD=pass npx electron-builder -mwl --publish always
```
Add `autoUpdater.checkForUpdates()` in main process for runtime updates.

## Reference Guides

In-depth guides for advanced topics are in `references/`:

- **[Advanced Patterns](references/advanced-patterns.md)** — Multi-window management, shared state between windows, WebContentsView (BrowserView replacement), offscreen rendering, web workers vs utility processes, sandboxing internals, custom protocols with streaming, deep linking with URL routing, session/cookie management, Electron Fiddle for prototyping.
- **[Troubleshooting](references/troubleshooting.md)** — Native module rebuild failures, node-gyp prerequisites by platform, Webpack/Vite build errors, main/renderer debugging techniques, DevTools extensions setup, memory leak detection (detached DOM, IPC listener leaks), ASAR extraction issues, white screen diagnosis, auto-updater debugging, and platform-specific bugs (macOS notarization, Windows SmartScreen, Linux sandbox).
- **[Security Guide](references/security-guide.md)** — Complete security checklist, contextIsolation deep dive with prototype pollution examples, sandbox enforcement levels, CSP configuration for dev/prod, webview tag hardening, remote module migration, secure IPC patterns with input validation and sender verification, Electron Fuses configuration, ASAR integrity validation, permission handling, navigation restrictions, and supply chain security.

## Scripts

Automation scripts in `scripts/` (all `chmod +x`):

- **[electron-security-audit.sh](scripts/electron-security-audit.sh)** — Audits an Electron project for security misconfigurations: checks nodeIntegration, contextIsolation, sandbox, webSecurity, raw ipcRenderer exposure, remote module usage, CSP presence, hardcoded secrets, permission handlers, and Electron version. Usage: `./electron-security-audit.sh [project-dir]`
- **[setup-electron-forge.sh](scripts/setup-electron-forge.sh)** — Scaffolds a new Electron Forge project with plugins (auto-unpack-natives, fuses), macOS entitlements, GitHub Actions CI, and git init. Supports vite-typescript, vite, webpack-typescript, webpack templates. Usage: `./setup-electron-forge.sh <name> [--template=vite-typescript]`
- **[build-and-sign.sh](scripts/build-and-sign.sh)** — Cross-platform build and code signing. Auto-detects Forge vs electron-builder. Handles macOS notarization, Windows Authenticode, platform/arch selection, and publishing. Usage: `./build-and-sign.sh [--platform=mac|win|linux|all] [--publish] [--skip-sign]`

## Asset Templates

Production-ready templates in `assets/`:

- **[main-process-template.ts](assets/main-process-template.ts)** — TypeScript main process with window state persistence, CSP setup, permission handling, navigation restrictions, typed IPC handlers with input validation, single-instance lock, and graceful error handling.
- **[preload-template.ts](assets/preload-template.ts)** — Secure preload script with contextBridge patterns, typed API surface, cleanup functions for event listeners, and TypeScript type exports for renderer consumption.
- **[electron-forge-config.ts](assets/electron-forge-config.ts)** — Complete Forge config with Vite plugin, auto-unpack-natives, Electron Fuses, makers for all platforms (DMG, Squirrel, deb, rpm), macOS notarization, and GitHub Releases publisher.
- **[github-actions-electron.yml](assets/github-actions-electron.yml)** — CI/CD workflow building on macOS (x64+arm64), Windows, and Linux. Lint/test stage, code signing with secrets, artifact upload, and draft GitHub Release creation on version tags.
- **[electron-builder-config.yml](assets/electron-builder-config.yml)** — Comprehensive electron-builder YAML config with ASAR settings, platform targets (dmg, nsis, portable, AppImage, deb, rpm), code signing, auto-update publishing, custom protocols, and extra resources.

<!-- tested: pass -->
