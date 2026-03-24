# Electron Advanced Patterns

## Table of Contents

- [Multi-Window Management](#multi-window-management)
  - [Window Registry Pattern](#window-registry-pattern)
  - [Parent-Child Windows](#parent-child-windows)
  - [Window State Persistence](#window-state-persistence)
  - [Modal and Dialog Windows](#modal-and-dialog-windows)
- [Shared State Between Windows](#shared-state-between-windows)
  - [Main Process as State Hub](#main-process-as-state-hub)
  - [IPC-Based State Synchronization](#ipc-based-state-synchronization)
  - [MessagePort for Direct Window Communication](#messageport-for-direct-window-communication)
- [WebContentsView (Replacement for BrowserView)](#webcontentsview-replacement-for-browserview)
  - [Migration from BrowserView](#migration-from-browserview)
  - [Multi-View Layout Patterns](#multi-view-layout-patterns)
  - [View Lifecycle Management](#view-lifecycle-management)
- [Offscreen Rendering](#offscreen-rendering)
  - [Configuration and Use Cases](#configuration-and-use-cases)
  - [Capturing Frames](#capturing-frames)
  - [Performance Considerations](#performance-considerations)
- [Web Workers in Electron](#web-workers-in-electron)
  - [Dedicated Workers](#dedicated-workers)
  - [Shared Workers](#shared-workers)
  - [Worker Limitations and Workarounds](#worker-limitations-and-workarounds)
- [Utility Processes](#utility-processes)
  - [When to Use Utility Processes](#when-to-use-utility-processes)
  - [Spawning and Communication](#spawning-and-communication)
  - [Native Module Access](#native-module-access)
- [Sandboxing](#sandboxing)
  - [Sandbox Modes](#sandbox-modes)
  - [Sandbox Implications for Preload Scripts](#sandbox-implications-for-preload-scripts)
  - [Opting Out Per Window](#opting-out-per-window)
- [Custom Protocols](#custom-protocols)
  - [Protocol Registration Patterns](#protocol-registration-patterns)
  - [Streaming Responses](#streaming-responses)
  - [Privileged vs Standard Schemes](#privileged-vs-standard-schemes)
- [Deep Linking](#deep-linking)
  - [Platform Registration](#platform-registration)
  - [Single Instance Lock](#single-instance-lock)
  - [URL Routing](#url-routing)
- [Session and Cookie Management](#session-and-cookie-management)
  - [Session Partitioning](#session-partitioning)
  - [Cookie Store API](#cookie-store-api)
  - [Persistent vs In-Memory Sessions](#persistent-vs-in-memory-sessions)
  - [Proxy Configuration](#proxy-configuration)
- [Electron Fiddle](#electron-fiddle)
  - [Rapid Prototyping](#rapid-prototyping)
  - [Sharing and Gist Integration](#sharing-and-gist-integration)
  - [Version Testing](#version-testing)

---

## Multi-Window Management

### Window Registry Pattern

Track all open windows with a centralized registry in the main process:

```typescript
// window-manager.ts
import { BrowserWindow, screen } from 'electron';
import path from 'node:path';

interface WindowConfig {
  id: string;
  url: string;
  width?: number;
  height?: number;
  parent?: string;
}

class WindowManager {
  private windows = new Map<string, BrowserWindow>();

  create(config: WindowConfig): BrowserWindow {
    if (this.windows.has(config.id)) {
      const existing = this.windows.get(config.id)!;
      existing.focus();
      return existing;
    }

    const parentWin = config.parent ? this.windows.get(config.parent) : undefined;

    const win = new BrowserWindow({
      width: config.width ?? 1200,
      height: config.height ?? 800,
      parent: parentWin,
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true,
        sandbox: true,
      },
    });

    win.loadURL(config.url);
    win.on('closed', () => this.windows.delete(config.id));
    this.windows.set(config.id, win);

    return win;
  }

  get(id: string): BrowserWindow | undefined {
    return this.windows.get(id);
  }

  getAll(): Map<string, BrowserWindow> {
    return new Map(this.windows);
  }

  closeAll(): void {
    for (const [, win] of this.windows) {
      win.close();
    }
  }

  broadcast(channel: string, ...args: unknown[]): void {
    for (const [, win] of this.windows) {
      if (!win.isDestroyed()) {
        win.webContents.send(channel, ...args);
      }
    }
  }
}

export const windowManager = new WindowManager();
```

### Parent-Child Windows

```typescript
// Create a child window that stays on top of its parent
const settingsWindow = windowManager.create({
  id: 'settings',
  url: 'file:///settings.html',
  width: 600,
  height: 400,
  parent: 'main',
});

// Modal dialog — blocks parent interaction
const modal = new BrowserWindow({
  parent: mainWindow,
  modal: true,
  show: false,
  width: 400,
  height: 300,
  webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
});
modal.once('ready-to-show', () => modal.show());
modal.loadFile('modal.html');
```

### Window State Persistence

Save and restore window position, size, and maximized state across restarts:

```typescript
import { app, BrowserWindow, screen } from 'electron';
import fs from 'node:fs';
import path from 'node:path';

interface WindowState {
  x?: number;
  y?: number;
  width: number;
  height: number;
  isMaximized: boolean;
}

function loadWindowState(id: string, defaults: { width: number; height: number }): WindowState {
  const statePath = path.join(app.getPath('userData'), `window-state-${id}.json`);
  try {
    const data = JSON.parse(fs.readFileSync(statePath, 'utf-8'));
    // Validate that the saved position is still on a visible display
    const visible = screen.getAllDisplays().some((display) => {
      const { x, y, width, height } = display.bounds;
      return data.x >= x && data.x < x + width && data.y >= y && data.y < y + height;
    });
    if (!visible) {
      return { ...defaults, isMaximized: false };
    }
    return data;
  } catch {
    return { ...defaults, isMaximized: false };
  }
}

function saveWindowState(id: string, win: BrowserWindow): void {
  const statePath = path.join(app.getPath('userData'), `window-state-${id}.json`);
  const bounds = win.getBounds();
  const state: WindowState = {
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    isMaximized: win.isMaximized(),
  };
  fs.writeFileSync(statePath, JSON.stringify(state));
}

function createWindowWithState(id: string): BrowserWindow {
  const state = loadWindowState(id, { width: 1200, height: 800 });
  const win = new BrowserWindow({
    x: state.x,
    y: state.y,
    width: state.width,
    height: state.height,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });

  if (state.isMaximized) win.maximize();

  // Save state on changes (debounced)
  let saveTimeout: NodeJS.Timeout;
  const debouncedSave = () => {
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(() => saveWindowState(id, win), 500);
  };
  win.on('resize', debouncedSave);
  win.on('move', debouncedSave);
  win.on('close', () => saveWindowState(id, win));

  return win;
}
```

### Modal and Dialog Windows

```typescript
// Frameless floating panel
const panel = new BrowserWindow({
  frame: false,
  transparent: true,
  alwaysOnTop: true,
  skipTaskbar: true,
  resizable: false,
  width: 300,
  height: 200,
  webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
});

// Position relative to parent
const parentBounds = mainWindow.getBounds();
panel.setPosition(
  parentBounds.x + parentBounds.width - 320,
  parentBounds.y + parentBounds.height - 220
);
```

---

## Shared State Between Windows

### Main Process as State Hub

The main process is the natural single source of truth. All windows communicate through it:

```typescript
// state-store.ts (main process)
import { ipcMain, BrowserWindow } from 'electron';

interface AppState {
  theme: 'light' | 'dark';
  user: { name: string; email: string } | null;
  recentFiles: string[];
}

class StateStore {
  private state: AppState = {
    theme: 'light',
    user: null,
    recentFiles: [],
  };

  private subscribers = new Set<BrowserWindow>();

  constructor() {
    ipcMain.handle('state:get', () => structuredClone(this.state));

    ipcMain.handle('state:update', (_event, patch: Partial<AppState>) => {
      Object.assign(this.state, patch);
      this.notifyAll();
      return this.state;
    });
  }

  subscribe(win: BrowserWindow): void {
    this.subscribers.add(win);
    win.on('closed', () => this.subscribers.delete(win));
  }

  private notifyAll(): void {
    for (const win of this.subscribers) {
      if (!win.isDestroyed()) {
        win.webContents.send('state:changed', structuredClone(this.state));
      }
    }
  }
}

export const store = new StateStore();
```

### IPC-Based State Synchronization

```typescript
// preload.ts — expose state API to renderer
contextBridge.exposeInMainWorld('stateAPI', {
  getState: () => ipcRenderer.invoke('state:get'),
  updateState: (patch: Record<string, unknown>) => ipcRenderer.invoke('state:update', patch),
  onStateChanged: (callback: (state: unknown) => void) => {
    const handler = (_event: IpcRendererEvent, state: unknown) => callback(state);
    ipcRenderer.on('state:changed', handler);
    return () => ipcRenderer.removeListener('state:changed', handler);
  },
});
```

### MessagePort for Direct Window Communication

When two renderer processes need high-throughput communication without routing through main:

```typescript
// main.ts — establish a port pair between two windows
import { MessageChannelMain } from 'electron';

function connectWindows(win1: BrowserWindow, win2: BrowserWindow): void {
  const { port1, port2 } = new MessageChannelMain();
  win1.webContents.postMessage('connect-peer', { peerId: 'win2' }, [port1]);
  win2.webContents.postMessage('connect-peer', { peerId: 'win1' }, [port2]);
}

// preload.ts
ipcRenderer.on('connect-peer', (event) => {
  const port = event.ports[0];
  contextBridge.exposeInMainWorld('peerPort', {
    send: (data: unknown) => port.postMessage(data),
    onMessage: (cb: (data: unknown) => void) => {
      port.onmessage = (e) => cb(e.data);
      port.start();
    },
  });
});
```

---

## WebContentsView (Replacement for BrowserView)

`BrowserView` is deprecated since Electron 30. Use `WebContentsView` instead, which provides a more flexible multi-view architecture attached to `BaseWindow`.

### Migration from BrowserView

```typescript
// OLD — BrowserView (deprecated)
const view = new BrowserView({ webPreferences: { preload: '...' } });
win.addBrowserView(view);
view.setBounds({ x: 0, y: 50, width: 800, height: 550 });
view.webContents.loadURL('https://example.com');

// NEW — WebContentsView
import { BaseWindow, WebContentsView } from 'electron';

const win = new BaseWindow({ width: 800, height: 600 });
const view = new WebContentsView({
  webPreferences: {
    preload: path.join(__dirname, 'preload.js'),
    contextIsolation: true,
    sandbox: true,
  },
});
win.contentView.addChildView(view);
view.setBounds({ x: 0, y: 50, width: 800, height: 550 });
view.webContents.loadURL('https://example.com');
```

### Multi-View Layout Patterns

Build IDE-like layouts with multiple views:

```typescript
import { BaseWindow, WebContentsView } from 'electron';

function createIDELayout(): BaseWindow {
  const win = new BaseWindow({ width: 1400, height: 900 });

  // Sidebar
  const sidebar = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  sidebar.setBounds({ x: 0, y: 0, width: 250, height: 900 });
  sidebar.webContents.loadFile('sidebar.html');

  // Main editor
  const editor = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  editor.setBounds({ x: 250, y: 0, width: 900, height: 600 });
  editor.webContents.loadFile('editor.html');

  // Terminal panel
  const terminal = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  terminal.setBounds({ x: 250, y: 600, width: 900, height: 300 });
  terminal.webContents.loadFile('terminal.html');

  // Status bar
  const statusBar = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  statusBar.setBounds({ x: 0, y: 875, width: 1400, height: 25 });
  statusBar.webContents.loadFile('statusbar.html');

  win.contentView.addChildView(sidebar);
  win.contentView.addChildView(editor);
  win.contentView.addChildView(terminal);
  win.contentView.addChildView(statusBar);

  // Handle resize — recalculate bounds
  win.on('resize', () => {
    const [w, h] = win.getSize();
    sidebar.setBounds({ x: 0, y: 0, width: 250, height: h - 25 });
    editor.setBounds({ x: 250, y: 0, width: w - 250, height: Math.floor(h * 0.67) });
    terminal.setBounds({ x: 250, y: Math.floor(h * 0.67), width: w - 250, height: Math.ceil(h * 0.33) - 25 });
    statusBar.setBounds({ x: 0, y: h - 25, width: w, height: 25 });
  });

  return win;
}
```

### View Lifecycle Management

```typescript
// Dynamically add/remove views
function addTab(win: BaseWindow, url: string): WebContentsView {
  const view = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  win.contentView.addChildView(view);
  view.webContents.loadURL(url);
  return view;
}

function removeTab(win: BaseWindow, view: WebContentsView): void {
  win.contentView.removeChildView(view);
  // WebContentsView does not have a destroy() — the underlying WebContents
  // is garbage-collected once all references are released.
  view.webContents.close();
}
```

---

## Offscreen Rendering

### Configuration and Use Cases

Offscreen rendering (OSR) renders a BrowserWindow to a bitmap without displaying it on screen. Useful for:
- Generating thumbnails or screenshots
- Rendering content for LED walls or projection mapping
- Capturing page content for PDF or image export
- Automated visual testing

```typescript
const offscreen = new BrowserWindow({
  show: false,
  webPreferences: {
    offscreen: true,
    contextIsolation: true,
    sandbox: true,
  },
});

offscreen.webContents.setFrameRate(30);
```

### Capturing Frames

```typescript
offscreen.webContents.on('paint', (_event, _dirty, image) => {
  // image is a NativeImage — can convert to PNG, JPEG, or raw bitmap
  const png = image.toPNG();
  fs.writeFileSync('screenshot.png', png);
});

// For one-shot capture, use capturePage instead of paint events
offscreen.webContents.once('did-finish-load', async () => {
  const image = await offscreen.webContents.capturePage();
  fs.writeFileSync('capture.png', image.toPNG());
  offscreen.close();
});

offscreen.loadURL('https://example.com');
```

### Performance Considerations

- Set `frameRate` to the minimum needed (default is 60)
- Use `dirty` rect from paint event to do partial updates
- For GPU-accelerated rendering: `app.disableHardwareAcceleration()` is NOT needed — OSR uses software rendering by default
- For large canvases, consider using `webContents.capturePage(rect)` with a specific region

---

## Web Workers in Electron

### Dedicated Workers

Web Workers in Electron's renderer process work the same as in browsers:

```typescript
// renderer.ts
const worker = new Worker(new URL('./heavy-task.worker.ts', import.meta.url));
worker.postMessage({ type: 'process', data: largeDataset });
worker.onmessage = (event) => {
  console.log('Result:', event.data);
};

// heavy-task.worker.ts
self.onmessage = (event) => {
  const result = expensiveComputation(event.data);
  self.postMessage(result);
};
```

### Shared Workers

Shared Workers can be accessed by multiple renderer processes on the same origin:

```typescript
// Multiple renderers can connect to the same SharedWorker
const shared = new SharedWorker('shared-worker.js');
shared.port.postMessage({ type: 'subscribe', channel: 'updates' });
shared.port.onmessage = (event) => {
  console.log('Broadcast from shared worker:', event.data);
};
```

### Worker Limitations and Workarounds

- **No Node.js APIs**: Workers run in a pure browser context — no `require()`, no `fs`, no `child_process`
- **No preload scripts**: Workers cannot use `contextBridge`
- **For Node.js access**: Use `utilityProcess.fork()` instead (see below)
- **Bundler config**: When using Webpack or Vite, configure worker loaders:
  ```typescript
  // vite.config.ts
  export default defineConfig({
    worker: {
      format: 'es',
    },
  });
  ```

---

## Utility Processes

### When to Use Utility Processes

Use `utilityProcess` over `child_process.fork()` when you need:
- Native module access (e.g., `better-sqlite3`, `sharp`)
- Stable IPC via `MessagePort`
- Process that survives renderer crashes
- CPU-intensive work that shouldn't block the main process

### Spawning and Communication

```typescript
// main.ts
import { utilityProcess } from 'electron';
import path from 'node:path';

const child = utilityProcess.fork(path.join(__dirname, 'workers/db-worker.js'));

// Send messages
child.postMessage({ type: 'query', sql: 'SELECT * FROM users' });

// Receive messages
child.on('message', (result) => {
  console.log('Query result:', result);
});

// Handle exit
child.on('exit', (code) => {
  console.log(`Utility process exited with code ${code}`);
});
```

```typescript
// workers/db-worker.ts
import Database from 'better-sqlite3';

const db = new Database('/path/to/app.db');

process.parentPort!.on('message', (event) => {
  const { type, sql, params } = event.data;
  if (type === 'query') {
    const rows = db.prepare(sql).all(...(params ?? []));
    process.parentPort!.postMessage({ type: 'result', rows });
  }
});
```

### Native Module Access

Utility processes support native Node.js addons. Rebuild native modules for Electron's Node version:

```bash
npx @electron/rebuild --module-dir ./node_modules/better-sqlite3
```

The utility process uses the same Node.js version as the main process, so no separate rebuild is needed.

---

## Sandboxing

### Sandbox Modes

Since Electron 20, sandbox is enabled by default for all renderer processes:

| Setting | Effect |
|---------|--------|
| `sandbox: true` (default) | Full Chromium sandbox. Preload runs in limited environment. |
| `sandbox: false` | Preload has full Node.js access. **Avoid unless necessary.** |
| `app.enableSandbox()` | Force sandbox for ALL renderers, cannot be overridden per window. |

### Sandbox Implications for Preload Scripts

In sandboxed mode, preload scripts:
- **CAN** use: `contextBridge`, `ipcRenderer`, `webFrame`, `timers`, `URL`, DOM events
- **CANNOT** use: `require()` for arbitrary modules, `fs`, `child_process`, `path`, `os`
- **CAN** import: Only Electron's built-in preload modules

```typescript
// Sandboxed preload — must use contextBridge, cannot require('fs')
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  readFile: (path: string) => ipcRenderer.invoke('read-file', path),
});
```

### Opting Out Per Window

```typescript
// Only disable sandbox for specific windows that need it (e.g., legacy code)
const legacyWindow = new BrowserWindow({
  webPreferences: {
    sandbox: false,        // ⚠️ Disables OS-level sandbox
    contextIsolation: true, // Keep this true regardless
    preload: path.join(__dirname, 'preload-legacy.js'),
  },
});
```

⚠️ Disabling sandbox weakens security. Prefer refactoring to use IPC for Node.js operations.

---

## Custom Protocols

### Protocol Registration Patterns

```typescript
import { protocol, net, app, session } from 'electron';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// Register a scheme as privileged BEFORE app.ready
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'app',
    privileges: {
      standard: true,    // Enables relative URL resolution
      secure: true,      // Treated as HTTPS origin
      supportFetchAPI: true,
      corsEnabled: true,
      stream: true,      // Supports streaming responses
    },
  },
]);

app.whenReady().then(() => {
  // Handle requests to app:// protocol
  protocol.handle('app', (request) => {
    const url = new URL(request.url);
    // Serve from the app's dist directory
    const filePath = path.join(__dirname, 'dist', url.pathname);

    // Security: prevent directory traversal
    if (!filePath.startsWith(path.join(__dirname, 'dist'))) {
      return new Response('Forbidden', { status: 403 });
    }

    return net.fetch(pathToFileURL(filePath).toString());
  });
});
```

### Streaming Responses

```typescript
// Stream large files or generated content
protocol.handle('stream', async (request) => {
  const url = new URL(request.url);

  if (url.pathname === '/large-data') {
    const readable = new ReadableStream({
      start(controller) {
        for (let i = 0; i < 1000; i++) {
          controller.enqueue(new TextEncoder().encode(`chunk-${i}\n`));
        }
        controller.close();
      },
    });
    return new Response(readable, {
      headers: { 'Content-Type': 'text/plain' },
    });
  }

  return new Response('Not Found', { status: 404 });
});
```

### Privileged vs Standard Schemes

- **Standard**: Supports relative URL resolution (`<img src="/logo.png">` works)
- **Secure**: HTTPS-level security context (Service Workers, Crypto API available)
- **CORS-enabled**: Can be target of cross-origin requests
- **Stream**: Supports `ReadableStream` responses
- Register privileges in `protocol.registerSchemesAsPrivileged()` before `app.ready`

---

## Deep Linking

### Platform Registration

```typescript
// Register your app as handler for myapp:// URLs
if (process.defaultApp) {
  // In development, register with the Electron binary path
  app.setAsDefaultProtocolClient('myapp', process.execPath, [
    path.resolve(process.argv[1]),
  ]);
} else {
  app.setAsDefaultProtocolClient('myapp');
}
```

Platform-specific requirements:
- **macOS**: Add URL scheme to `Info.plist` (Electron Forge / electron-builder handle this)
- **Windows**: Registers in Windows Registry (HKCU\Software\Classes)
- **Linux**: Creates `.desktop` file with MimeType entry

### Single Instance Lock

Required for deep linking to ensure URLs route to the existing instance:

```typescript
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv, _workingDir) => {
    // Windows/Linux: URL is in argv
    const url = argv.find((arg) => arg.startsWith('myapp://'));
    if (url) handleDeepLink(url);

    // Focus existing window
    const mainWindow = windowManager.get('main');
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });

  // macOS: URL comes through open-url event
  app.on('open-url', (event, url) => {
    event.preventDefault();
    handleDeepLink(url);
  });
}
```

### URL Routing

```typescript
function handleDeepLink(url: string): void {
  try {
    const parsed = new URL(url);
    const route = parsed.hostname; // myapp://settings/theme → "settings"
    const path = parsed.pathname;  // → "/theme"
    const params = Object.fromEntries(parsed.searchParams);

    switch (route) {
      case 'open':
        openFile(params.file);
        break;
      case 'settings':
        openSettings(path.slice(1)); // "theme"
        break;
      case 'auth':
        handleOAuthCallback(params.code);
        break;
      default:
        console.warn(`Unknown deep link route: ${route}`);
    }
  } catch (err) {
    console.error('Invalid deep link URL:', url, err);
  }
}
```

---

## Session and Cookie Management

### Session Partitioning

Create isolated sessions for different concerns (e.g., separate auth for webview content):

```typescript
import { session, BrowserWindow } from 'electron';

// Default session — shared by all windows unless overridden
const defaultSession = session.defaultSession;

// Named persistent session — data stored on disk
const authSession = session.fromPartition('persist:auth');

// In-memory session — cleared on app restart
const guestSession = session.fromPartition('guest');

const guestWindow = new BrowserWindow({
  webPreferences: {
    session: guestSession,
    preload: path.join(__dirname, 'preload.js'),
    contextIsolation: true,
    sandbox: true,
  },
});
```

### Cookie Store API

```typescript
// Read cookies
const cookies = await session.defaultSession.cookies.get({ url: 'https://example.com' });

// Set a cookie
await session.defaultSession.cookies.set({
  url: 'https://example.com',
  name: 'auth_token',
  value: 'abc123',
  httpOnly: true,
  secure: true,
  sameSite: 'strict',
  expirationDate: Math.floor(Date.now() / 1000) + 86400, // 1 day
});

// Remove a cookie
await session.defaultSession.cookies.remove('https://example.com', 'auth_token');

// Listen for cookie changes
session.defaultSession.cookies.on('changed', (_event, cookie, cause, removed) => {
  console.log(`Cookie ${cookie.name} ${removed ? 'removed' : 'set'} (${cause})`);
});
```

### Persistent vs In-Memory Sessions

| Partition | Persistence | Use Case |
|-----------|------------|----------|
| `persist:name` | Disk (survives restart) | User auth, preferences |
| `name` (no prefix) | Memory only | Guest browsing, isolated views |
| `''` (empty / default) | Disk (app userData) | Main app session |

### Proxy Configuration

```typescript
// Set proxy for a specific session
await session.defaultSession.setProxy({
  proxyRules: 'http=proxy.example.com:8080;https=proxy.example.com:8443',
  proxyBypassRules: 'localhost,127.0.0.1',
});

// Use PAC script
await session.defaultSession.setProxy({
  pacScript: 'https://proxy.example.com/proxy.pac',
});

// Clear proxy
await session.defaultSession.setProxy({ mode: 'direct' });

// Resolve proxy for a URL
const proxy = await session.defaultSession.resolveProxy('https://example.com');
```

---

## Electron Fiddle

### Rapid Prototyping

[Electron Fiddle](https://www.electronjs.org/fiddle) is the official playground for prototyping Electron features. It provides:

- **Instant editing** of `main.js`, `preload.js`, `renderer.js`, and `index.html`
- **One-click run** with any Electron version
- **Built-in console** for main process logs
- **DevTools** for renderer inspection

Use it to:
- Test Electron APIs before integrating into your project
- Reproduce and report bugs with minimal examples
- Experiment with different Electron versions for compatibility

### Sharing and Gist Integration

Fiddle integrates with GitHub Gists:
- **Save as Gist**: Share your fiddle with a URL
- **Load from Gist**: Open any Electron Fiddle gist by ID
- **Versioned**: Each gist save creates a revision

When filing Electron issues, share a Fiddle gist that reproduces the bug.

### Version Testing

Test your code across Electron versions:
1. Select any released Electron version from the dropdown
2. Run your fiddle to verify behavior
3. Compare results across versions to find regressions

This is invaluable when:
- Upgrading your app's Electron version
- Checking when a bug was introduced
- Verifying API availability (e.g., `WebContentsView` requires Electron ≥ 30)
