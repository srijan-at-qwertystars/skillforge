# Electron Security Guide

## Table of Contents

- [Security Checklist](#security-checklist)
- [contextIsolation Deep Dive](#contextisolation-deep-dive)
  - [How It Works](#how-it-works)
  - [Prototype Pollution Without It](#prototype-pollution-without-it)
  - [Migration from contextIsolation: false](#migration-from-contextisolation-false)
- [Sandbox Enforcement](#sandbox-enforcement)
  - [Process Sandboxing Levels](#process-sandboxing-levels)
  - [App-Level Sandbox](#app-level-sandbox)
  - [Verifying Sandbox Status](#verifying-sandbox-status)
- [Content Security Policy for Electron](#content-security-policy-for-electron)
  - [Recommended CSP](#recommended-csp)
  - [CSP via HTTP Headers](#csp-via-http-headers)
  - [CSP via Meta Tag](#csp-via-meta-tag)
  - [CSP for Development vs Production](#csp-for-development-vs-production)
- [Webview Tag Security](#webview-tag-security)
  - [Webview Risks](#webview-risks)
  - [Securing Webview Content](#securing-webview-content)
  - [Alternative: WebContentsView](#alternative-webcontentsview)
- [Remote Module Removal](#remote-module-removal)
  - [Why It Was Removed](#why-it-was-removed)
  - [Migration Patterns](#migration-patterns)
- [Secure IPC Patterns](#secure-ipc-patterns)
  - [Principle of Least Privilege](#principle-of-least-privilege)
  - [Input Validation](#input-validation)
  - [Sender Verification](#sender-verification)
  - [Avoiding Common IPC Mistakes](#avoiding-common-ipc-mistakes)
- [Electron Fuses](#electron-fuses)
  - [What Are Fuses](#what-are-fuses)
  - [Available Fuses](#available-fuses)
  - [Reading and Writing Fuses](#reading-and-writing-fuses)
  - [Recommended Fuse Configuration](#recommended-fuse-configuration)
- [Process Sandboxing](#process-sandboxing)
  - [Chromium Sandbox Architecture](#chromium-sandbox-architecture)
  - [Renderer Process Restrictions](#renderer-process-restrictions)
  - [Utility Process Security](#utility-process-security)
- [ASAR Integrity Validation](#asar-integrity-validation)
  - [How ASAR Integrity Works](#how-asar-integrity-works)
  - [Enabling Integrity Checks](#enabling-integrity-checks)
  - [Tamper Detection](#tamper-detection)
- [Additional Security Hardening](#additional-security-hardening)
  - [Permissions Handling](#permissions-handling)
  - [Navigation Restrictions](#navigation-restrictions)
  - [shell.openExternal Safety](#shellopenexternal-safety)
  - [Secure Storage](#secure-storage)
  - [Supply Chain Security](#supply-chain-security)

---

## Security Checklist

Every Electron app should meet these baseline requirements:

| # | Requirement | Default | Critical |
|---|------------|---------|----------|
| 1 | `contextIsolation: true` | ✅ (since v12) | Yes |
| 2 | `nodeIntegration: false` | ✅ (since v5) | Yes |
| 3 | `sandbox: true` | ✅ (since v20) | Yes |
| 4 | `webSecurity: true` | ✅ | Yes |
| 5 | Content Security Policy set | ❌ | Yes |
| 6 | `allowRunningInsecureContent: false` | ✅ | Yes |
| 7 | `experimentalFeatures: false` | ✅ | Medium |
| 8 | No `remote` module usage | N/A (removed) | Yes |
| 9 | IPC inputs validated | ❌ (manual) | Yes |
| 10 | Navigation restricted to known URLs | ❌ (manual) | Yes |
| 11 | `shell.openExternal` URL validated | ❌ (manual) | Yes |
| 12 | No `<webview>` with `nodeIntegration` | ❌ (manual) | Yes |
| 13 | Electron Fuses configured | ❌ (manual) | Medium |
| 14 | ASAR integrity enabled | ❌ (manual) | Medium |
| 15 | Permissions handler registered | ❌ (manual) | Medium |

---

## contextIsolation Deep Dive

### How It Works

`contextIsolation` runs preload scripts in a separate JavaScript context from the renderer page. The two contexts share the same DOM but have completely separate global scopes.

```
┌─────────────────────────────────────────┐
│ Renderer Process                        │
│ ┌─────────────────┐ ┌────────────────┐  │
│ │ Preload Context  │ │ Page Context   │  │
│ │                  │ │                │  │
│ │ require()       │ │ window.*       │  │
│ │ ipcRenderer     │ │ document.*     │  │
│ │ contextBridge → │ │ ← exposed API │  │
│ │                  │ │                │  │
│ └─────────────────┘ └────────────────┘  │
│         Shared DOM (read/write)         │
└─────────────────────────────────────────┘
```

`contextBridge.exposeInMainWorld()` is the ONLY safe way to pass values between contexts. It performs structured cloning, preventing prototype chain leaks.

### Prototype Pollution Without It

Without `contextIsolation`, a malicious page can override built-in prototypes:

```javascript
// Malicious page code (without contextIsolation)
Array.prototype.push = function(...args) {
  // Intercept all array operations in preload context
  sendToAttacker(args);
  return originalPush.apply(this, args);
};

Object.defineProperty(Object.prototype, 'password', {
  set(value) {
    sendToAttacker(value); // Steal any property named "password"
  }
});
```

With `contextIsolation: true`, these modifications only affect the page's own context and cannot reach the preload script's globals.

### Migration from contextIsolation: false

If upgrading a legacy app:

```javascript
// BEFORE (insecure — contextIsolation: false)
// preload.js
window.myAPI = {
  readFile: (path) => require('fs').readFileSync(path, 'utf-8'),
};

// AFTER (secure — contextIsolation: true)
// preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('myAPI', {
  readFile: (path) => ipcRenderer.invoke('read-file', path),
});

// main.js — add handler
ipcMain.handle('read-file', async (_event, filePath) => {
  // Validate path before reading
  if (!isAllowedPath(filePath)) throw new Error('Access denied');
  return fs.promises.readFile(filePath, 'utf-8');
});
```

Key migration steps:
1. Move all Node.js API calls to main process IPC handlers
2. Replace `window.X = ...` with `contextBridge.exposeInMainWorld()`
3. Wrap each IPC channel in a named function — never expose raw `ipcRenderer`
4. Add input validation in every `ipcMain.handle` callback

---

## Sandbox Enforcement

### Process Sandboxing Levels

```
Level 0: No sandbox (sandbox: false)
  └── Preload has full Node.js access
  └── ⚠️ A compromised renderer can access filesystem, spawn processes

Level 1: Per-window sandbox (sandbox: true, default since v20)
  └── Preload has limited API access
  └── Node.js APIs only available via IPC to main process

Level 2: App-level sandbox (app.enableSandbox())
  └── ALL renderers sandboxed, cannot be overridden per window
  └── Strongest isolation
```

### App-Level Sandbox

```typescript
// Call before app.ready — forces sandbox for every renderer
app.enableSandbox();

// After this, even windows with sandbox: false will be sandboxed
// This is the strongest enforcement — recommended for production
```

### Verifying Sandbox Status

```typescript
// In preload — check if sandbox is active
const isSandboxed = process.sandboxed; // true if sandboxed

// In main — verify renderer sandbox status
win.webContents.on('did-finish-load', () => {
  console.log('OS sandbox active:', win.webContents.getOSProcessId() !== process.pid);
});
```

---

## Content Security Policy for Electron

### Recommended CSP

```
default-src 'self';
script-src 'self';
style-src 'self' 'unsafe-inline';
img-src 'self' data:;
font-src 'self';
connect-src 'self' https://api.yourdomain.com;
object-src 'none';
base-uri 'self';
form-action 'self';
frame-ancestors 'none';
```

### CSP via HTTP Headers

Set CSP for all responses using `session.webRequest`:

```typescript
session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
  callback({
    responseHeaders: {
      ...details.responseHeaders,
      'Content-Security-Policy': [
        "default-src 'self'; " +
        "script-src 'self'; " +
        "style-src 'self' 'unsafe-inline'; " +
        "img-src 'self' data: https:; " +
        "connect-src 'self' https://api.example.com; " +
        "object-src 'none'; " +
        "base-uri 'self'"
      ],
    },
  });
});
```

### CSP via Meta Tag

```html
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';">
```

### CSP for Development vs Production

```typescript
const isDev = !app.isPackaged;

const csp = isDev
  ? "default-src 'self' 'unsafe-inline' 'unsafe-eval'; connect-src 'self' ws://localhost:*"
  : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'";

session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
  callback({
    responseHeaders: {
      ...details.responseHeaders,
      'Content-Security-Policy': [csp],
    },
  });
});
```

⚠️ **Never** use `'unsafe-eval'` or `'unsafe-inline'` for `script-src` in production. HMR/live-reload may need them in dev only.

---

## Webview Tag Security

### Webview Risks

The `<webview>` tag embeds external content in a separate renderer process. Risks:
- External content executing in your app's context
- `nodeIntegration` leaking to webview content
- Webview navigating to malicious sites
- Webview opening popups or new windows

### Securing Webview Content

```typescript
// 1. Disable webview tag entirely if not needed
app.on('web-contents-created', (_event, contents) => {
  contents.on('will-attach-webview', (event, _webPreferences, _params) => {
    event.preventDefault(); // Block all webview creation
  });
});

// 2. If webviews are needed, enforce security settings
app.on('web-contents-created', (_event, contents) => {
  contents.on('will-attach-webview', (event, webPreferences, params) => {
    // Strip away preload scripts
    delete webPreferences.preload;

    // Enforce security
    webPreferences.contextIsolation = true;
    webPreferences.nodeIntegration = false;
    webPreferences.sandbox = true;
    webPreferences.webSecurity = true;

    // Only allow specific URLs
    if (!params.src.startsWith('https://trusted-domain.com')) {
      event.preventDefault();
    }
  });
});
```

### Alternative: WebContentsView

Prefer `WebContentsView` over `<webview>` for embedding content — it provides better security boundaries and is not deprecated:

```typescript
import { BaseWindow, WebContentsView } from 'electron';

const embeddedView = new WebContentsView({
  webPreferences: {
    contextIsolation: true,
    sandbox: true,
    nodeIntegration: false,
  },
});
embeddedView.webContents.loadURL('https://trusted-content.com');
mainWindow.contentView.addChildView(embeddedView);
```

---

## Remote Module Removal

### Why It Was Removed

The `remote` module (removed in Electron 14+) allowed renderer processes to directly call main process APIs:

```javascript
// OLD — insecure remote module usage
const { dialog } = require('@electron/remote');
dialog.showMessageBox({ message: 'Hello' });
```

**Security issues**:
- Gave renderer processes unrestricted access to main process APIs
- Bypassed contextIsolation protections
- Enabled prototype pollution attacks across processes
- Made it trivial for XSS to escalate to full system access

### Migration Patterns

Replace every `remote` call with explicit IPC:

```typescript
// BEFORE: remote
const { BrowserWindow } = require('@electron/remote');
const win = new BrowserWindow({ width: 400, height: 300 });

// AFTER: IPC
// preload.js
contextBridge.exposeInMainWorld('windowAPI', {
  createWindow: (opts) => ipcRenderer.invoke('create-window', opts),
});

// main.js
ipcMain.handle('create-window', (_event, opts) => {
  // Validate options before creating window
  const win = new BrowserWindow({
    width: Math.min(opts.width || 400, 1920),
    height: Math.min(opts.height || 300, 1080),
    webPreferences: { contextIsolation: true, sandbox: true },
  });
  return win.id;
});
```

---

## Secure IPC Patterns

### Principle of Least Privilege

Expose the minimum API surface needed:

```typescript
// BAD — overly broad API
contextBridge.exposeInMainWorld('api', {
  send: (channel, data) => ipcRenderer.send(channel, data),         // ⚠️ any channel
  invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args), // ⚠️ any channel
  on: (channel, cb) => ipcRenderer.on(channel, cb),                   // ⚠️ any channel
});

// GOOD — scoped, specific API
const ALLOWED_INVOKE_CHANNELS = ['get-user', 'save-document', 'get-preferences'] as const;
const ALLOWED_LISTEN_CHANNELS = ['update-available', 'sync-status'] as const;

contextBridge.exposeInMainWorld('api', {
  getUser: () => ipcRenderer.invoke('get-user'),
  saveDocument: (doc: { title: string; body: string }) =>
    ipcRenderer.invoke('save-document', doc),
  getPreferences: () => ipcRenderer.invoke('get-preferences'),
  onUpdateAvailable: (cb: (info: unknown) => void) => {
    const handler = (_e: IpcRendererEvent, info: unknown) => cb(info);
    ipcRenderer.on('update-available', handler);
    return () => ipcRenderer.removeListener('update-available', handler);
  },
});
```

### Input Validation

Validate ALL inputs in main process handlers:

```typescript
import { ipcMain } from 'electron';
import path from 'node:path';
import { app } from 'electron';

ipcMain.handle('save-file', async (_event, filePath: unknown, content: unknown) => {
  // Type validation
  if (typeof filePath !== 'string') throw new Error('filePath must be a string');
  if (typeof content !== 'string') throw new Error('content must be a string');

  // Length validation
  if (filePath.length > 500) throw new Error('Path too long');
  if (content.length > 10 * 1024 * 1024) throw new Error('Content too large');

  // Path traversal prevention
  const resolved = path.resolve(app.getPath('userData'), filePath);
  if (!resolved.startsWith(app.getPath('userData'))) {
    throw new Error('Path traversal detected');
  }

  // Null byte injection prevention
  if (filePath.includes('\0')) throw new Error('Invalid path');

  await fs.promises.writeFile(resolved, content, 'utf-8');
});
```

### Sender Verification

Verify which window/webContents sent a message:

```typescript
ipcMain.handle('sensitive-operation', async (event) => {
  // Verify the sender is a known window
  const senderWebContents = event.sender;
  const senderWindow = BrowserWindow.fromWebContents(senderWebContents);

  if (!senderWindow || senderWindow.id !== mainWindow.id) {
    throw new Error('Unauthorized sender');
  }

  // Verify the origin of the sender
  const senderURL = new URL(senderWebContents.getURL());
  if (senderURL.protocol !== 'app:' && senderURL.protocol !== 'file:') {
    throw new Error('Unauthorized origin');
  }

  return performSensitiveOperation();
});
```

### Avoiding Common IPC Mistakes

```typescript
// MISTAKE 1: Passing functions (will be stripped by structured clone)
contextBridge.exposeInMainWorld('api', {
  // ⚠️ Callbacks passed to invoke are silently dropped
  doWork: (callback) => ipcRenderer.invoke('do-work', callback), // callback is lost
});
// FIX: Use event-based patterns for callbacks

// MISTAKE 2: Exposing ipcRenderer directly
contextBridge.exposeInMainWorld('ipc', ipcRenderer); // ⚠️ Full IPC access
// FIX: Wrap each channel in a named function

// MISTAKE 3: Not handling errors
ipcMain.handle('read-file', async (_e, path) => {
  return fs.promises.readFile(path, 'utf-8'); // ⚠️ No validation, error not caught
});
// FIX: Validate inputs and wrap in try/catch

// MISTAKE 4: Sending sensitive data to renderer
ipcMain.handle('get-config', () => {
  return { apiKey: process.env.API_KEY, dbPassword: process.env.DB_PASS }; // ⚠️
});
// FIX: Never send secrets to renderer — keep them in main process
```

---

## Electron Fuses

### What Are Fuses

Electron Fuses are compile-time feature toggles embedded in the Electron binary. Unlike runtime flags, fuses cannot be changed by modifying JavaScript — they require binary patching, making them tamper-resistant.

### Available Fuses

| Fuse | Purpose | Recommendation |
|------|---------|---------------|
| `RunAsNode` | Allow `ELECTRON_RUN_AS_NODE` env var | **Disable** in production |
| `CookieEncryption` | Encrypt cookies at rest | **Enable** |
| `NodeOptions` | Allow `NODE_OPTIONS` env var | **Disable** in production |
| `NodeCliInspect` | Allow `--inspect` flag | **Disable** in production |
| `EmbeddedAsarIntegrityValidation` | Validate ASAR checksum | **Enable** |
| `OnlyLoadAppFromAsar` | Prevent loading from plain app/ folder | **Enable** in production |
| `LoadBrowserProcessSpecificV8Snapshot` | Use browser-specific V8 snapshot | **Enable** |
| `GrantFileProtocolExtraPrivileges` | Extra privileges for file:// protocol | **Disable** |

### Reading and Writing Fuses

```bash
# Install the fuses CLI
npm install -g @electron/fuses

# Read current fuse state
npx @electron/fuses read --app /path/to/MyApp

# Write fuses (modify the binary)
npx @electron/fuses write \
  --app /path/to/MyApp \
  RunAsNode=off \
  CookieEncryption=on \
  NodeOptions=off \
  NodeCliInspect=off \
  EmbeddedAsarIntegrityValidation=on \
  OnlyLoadAppFromAsar=on \
  GrantFileProtocolExtraPrivileges=off
```

### Recommended Fuse Configuration

For production builds, apply fuses in your build pipeline AFTER packaging but BEFORE code signing:

```typescript
// In Electron Forge afterPack hook or electron-builder afterPack
import { flipFuses, FuseVersion, FuseV1Options } from '@electron/fuses';

async function afterPack(context) {
  const appPath = context.appOutDir;
  const electronBinary = getElectronBinaryPath(appPath); // platform-specific

  await flipFuses(electronBinary, {
    version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableCookieEncryption]: true,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,
    [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
  });
}
```

⚠️ Always write fuses BEFORE code signing. Modifying the binary after signing invalidates the signature.

---

## Process Sandboxing

### Chromium Sandbox Architecture

Electron inherits Chromium's multi-process sandbox:

```
┌──────────────────────────────────┐
│ Main Process (Browser Process)   │
│ ├── Full system access           │
│ ├── Manages all other processes  │
│ └── Runs with user privileges    │
├──────────────────────────────────┤
│ Renderer Process (sandboxed)     │
│ ├── No filesystem access         │
│ ├── No network access (direct)   │
│ ├── No process spawning          │
│ ├── Limited syscalls (seccomp)   │
│ └── Memory restrictions          │
├──────────────────────────────────┤
│ GPU Process                      │
│ ├── Restricted to GPU operations │
│ └── Sandboxed (less strict)      │
├──────────────────────────────────┤
│ Utility Process                  │
│ ├── Optional sandboxing          │
│ └── Configurable restrictions    │
└──────────────────────────────────┘
```

### Renderer Process Restrictions

When sandboxed, a renderer process:
- Cannot access the filesystem (no `fs`, `child_process`, etc.)
- Cannot use `require()` for Node.js modules (only Electron preload modules)
- Cannot modify process environment
- Is restricted by OS-level mechanisms:
  - **macOS**: App Sandbox + Seatbelt
  - **Windows**: Win32k lockdown + restricted token
  - **Linux**: seccomp-BPF + namespace sandbox

### Utility Process Security

```typescript
// Utility processes can optionally be sandboxed
const worker = utilityProcess.fork(path.join(__dirname, 'worker.js'), [], {
  // serviceName is used for crash reporting identification
  serviceName: 'data-processor',
});

// Utility processes have Node.js access by design — they are meant
// for trusted code that needs native capabilities without blocking main.
// Do NOT run untrusted code in utility processes.
```

---

## ASAR Integrity Validation

### How ASAR Integrity Works

ASAR integrity embeds a SHA-256 hash of the ASAR archive into the Electron binary. At startup, the hash is verified before loading any application code.

### Enabling Integrity Checks

```typescript
// 1. Enable the fuse
import { flipFuses, FuseVersion, FuseV1Options } from '@electron/fuses';

await flipFuses(electronBinary, {
  version: FuseVersion.V1,
  [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
  [FuseV1Options.OnlyLoadAppFromAsar]: true,
});

// 2. electron-builder handles hash embedding automatically when fuse is set
// 3. Electron Forge: configure in forge.config.ts
```

### Tamper Detection

With ASAR integrity enabled:
- Modifying any file in the ASAR archive causes a startup failure
- The app refuses to load if the hash doesn't match
- Combined with code signing, prevents post-distribution tampering

```
Startup flow with integrity:
1. Electron binary starts
2. Reads embedded ASAR hash from binary
3. Computes SHA-256 of app.asar
4. Compares computed hash with embedded hash
5. If mismatch → crash with integrity error
6. If match → load application code
```

---

## Additional Security Hardening

### Permissions Handling

Control access to hardware and APIs:

```typescript
// Handle permission requests (camera, microphone, geolocation, etc.)
session.defaultSession.setPermissionRequestHandler((webContents, permission, callback) => {
  const allowedPermissions = ['clipboard-read', 'notifications'];
  const url = new URL(webContents.getURL());

  // Only allow permissions for your own origin
  if (url.protocol === 'file:' || url.protocol === 'app:') {
    callback(allowedPermissions.includes(permission));
  } else {
    callback(false); // Deny all permissions for external content
  }
});

// Handle permission checks (synchronous)
session.defaultSession.setPermissionCheckHandler((_webContents, permission) => {
  const allowedChecks = ['clipboard-read', 'notifications'];
  return allowedChecks.includes(permission);
});

// Block all device permission requests (USB, Bluetooth, Serial, HID)
session.defaultSession.setDevicePermissionHandler(() => false);
```

### Navigation Restrictions

Prevent windows from navigating to unexpected URLs:

```typescript
app.on('web-contents-created', (_event, contents) => {
  // Restrict navigation
  contents.on('will-navigate', (event, navigationUrl) => {
    const parsedUrl = new URL(navigationUrl);
    const allowedOrigins = ['file:', 'app:', 'https://your-api.com'];

    if (!allowedOrigins.some((origin) => parsedUrl.protocol === origin || parsedUrl.origin === origin)) {
      event.preventDefault();
      console.warn('Blocked navigation to:', navigationUrl);
    }
  });

  // Restrict new window creation
  contents.setWindowOpenHandler(({ url }) => {
    // Open external links in default browser
    if (url.startsWith('https://')) {
      shell.openExternal(url);
    }
    return { action: 'deny' }; // Never allow new Electron windows from navigation
  });
});
```

### shell.openExternal Safety

`shell.openExternal` can execute arbitrary commands if given a malicious URL:

```typescript
import { shell } from 'electron';

// BAD — no validation
ipcMain.handle('open-link', async (_event, url) => {
  await shell.openExternal(url); // ⚠️ url could be file:///etc/passwd or a command
});

// GOOD — strict URL validation
ipcMain.handle('open-link', async (_event, url: unknown) => {
  if (typeof url !== 'string') throw new Error('URL must be a string');

  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error('Invalid URL');
  }

  // Only allow HTTPS URLs
  if (parsed.protocol !== 'https:') {
    throw new Error('Only HTTPS URLs are allowed');
  }

  // Optional: domain allowlist
  const allowedDomains = ['github.com', 'docs.example.com'];
  if (!allowedDomains.some((d) => parsed.hostname === d || parsed.hostname.endsWith(`.${d}`))) {
    throw new Error('Domain not allowed');
  }

  await shell.openExternal(url);
});
```

### Secure Storage

Never store secrets in plain text. Use OS credential stores:

```typescript
// Use safeStorage for encrypting sensitive data
import { safeStorage } from 'electron';

// Encrypt before storing
function encryptAndStore(key: string, value: string): void {
  if (!safeStorage.isEncryptionAvailable()) {
    throw new Error('Encryption not available on this system');
  }
  const encrypted = safeStorage.encryptString(value);
  // Store encrypted buffer in a file or electron-store
  store.set(key, encrypted.toString('base64'));
}

// Decrypt when reading
function retrieveAndDecrypt(key: string): string {
  const stored = store.get(key) as string;
  const buffer = Buffer.from(stored, 'base64');
  return safeStorage.decryptString(buffer);
}

// safeStorage uses:
// - macOS: Keychain
// - Windows: DPAPI
// - Linux: libsecret (GNOME Keyring / KWallet)
```

### Supply Chain Security

Protect your build and dependency chain:

1. **Lock dependencies**: Use `package-lock.json` or `yarn.lock`
2. **Audit regularly**: `npm audit` and `npx electron-security-checklist`
3. **Use exact versions**: `npm install --save-exact`
4. **Verify Electron integrity**: npm verifies package checksums automatically
5. **Pin Electron version**: Avoid accidental major upgrades
6. **Review postinstall scripts**: Some packages run arbitrary code on install
7. **Use ASAR integrity**: Prevents tampering with your packaged application
8. **Code sign everything**: Sign the app, installer, and update artifacts

```json
{
  "scripts": {
    "audit": "npm audit --production && npx @electron/fuses read --app dist/MyApp"
  }
}
```
