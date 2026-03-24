# Electron Troubleshooting Guide

## Table of Contents

- [Build Failures](#build-failures)
  - [Native Module Rebuilds](#native-module-rebuilds)
  - [node-gyp Errors](#node-gyp-errors)
  - [Electron Version Mismatch](#electron-version-mismatch)
  - [Webpack/Vite Build Errors](#webpackvite-build-errors)
- [Debugging Techniques](#debugging-techniques)
  - [Main Process Debugging](#main-process-debugging)
  - [Renderer Process Debugging](#renderer-process-debugging)
  - [DevTools Extensions](#devtools-extensions)
  - [Logging Best Practices](#logging-best-practices)
- [Memory Leaks](#memory-leaks)
  - [Detached DOM Nodes](#detached-dom-nodes)
  - [IPC Listener Leaks](#ipc-listener-leaks)
  - [BrowserWindow Reference Leaks](#browserwindow-reference-leaks)
  - [Profiling Memory Usage](#profiling-memory-usage)
- [ASAR Issues](#asar-issues)
  - [ASAR Extraction Failures](#asar-extraction-failures)
  - [Native Modules Inside ASAR](#native-modules-inside-asar)
  - [File Path Resolution in ASAR](#file-path-resolution-in-asar)
- [White Screen on Startup](#white-screen-on-startup)
  - [Common Causes](#common-causes)
  - [Diagnostic Steps](#diagnostic-steps)
  - [Fixes](#fixes)
- [Auto-Updater Errors](#auto-updater-errors)
  - [electron-updater Issues](#electron-updater-issues)
  - [Code Signing and Update Verification](#code-signing-and-update-verification)
  - [Update Server Configuration](#update-server-configuration)
- [Platform-Specific Bugs](#platform-specific-bugs)
  - [macOS: Notarization Failures](#macos-notarization-failures)
  - [macOS: Hardened Runtime Issues](#macos-hardened-runtime-issues)
  - [Windows: ASAR Integrity Errors](#windows-asar-integrity-errors)
  - [Windows: SmartScreen Warnings](#windows-smartscreen-warnings)
  - [Windows: DLL Load Failures](#windows-dll-load-failures)
  - [Linux: Sandbox Errors](#linux-sandbox-errors)
  - [Linux: Tray Icon Issues](#linux-tray-icon-issues)

---

## Build Failures

### Native Module Rebuilds

**Problem**: Native modules compiled for system Node.js fail in Electron because Electron ships its own Node.js version with different ABI.

**Solution**:

```bash
# Using @electron/rebuild (recommended)
npx @electron/rebuild

# Rebuild a specific module
npx @electron/rebuild --module-dir node_modules/better-sqlite3

# With Electron Forge — rebuild happens automatically in the make/package step
# For dev, add a postinstall hook:
# package.json
{
  "scripts": {
    "postinstall": "electron-rebuild"
  }
}
```

**Common error messages**:
```
Error: The module was compiled against a different Node.js version
NODE_MODULE_VERSION XX. This version of Node.js requires NODE_MODULE_VERSION YY.
```

**Fix**: Always run `@electron/rebuild` after `npm install` or when changing Electron version.

### node-gyp Errors

**Problem**: `node-gyp` fails to compile native modules.

**Prerequisites by platform**:

| Platform | Required Tools |
|----------|---------------|
| Windows | Visual Studio Build Tools 2019+, Python 3.x |
| macOS | Xcode Command Line Tools (`xcode-select --install`) |
| Linux | `build-essential`, `python3`, `libsecret-1-dev` (for keytar) |

**Common errors and fixes**:

```bash
# "gyp ERR! find Python" — Python not found or wrong version
npm config set python /usr/bin/python3

# Windows: "gyp ERR! find VS" — no Visual Studio Build Tools
npm install --global windows-build-tools
# Or install manually: Visual Studio Build Tools with "C++ build tools" workload

# "gyp ERR! stack Error: Could not find any Python installation"
# Ensure Python 3.6+ is installed and on PATH

# macOS: "No Xcode or CLT version detected"
xcode-select --install
sudo xcode-select --reset

# Permission errors on Linux
sudo apt-get install -y build-essential libsecret-1-dev
```

**Using prebuild binaries** to avoid node-gyp entirely:

```bash
# Many packages offer prebuilt binaries
npm install --prefer-prebuilt better-sqlite3
# Or use prebuildify-compatible packages that bundle prebuilds
```

### Electron Version Mismatch

**Problem**: Renderer or main process crashes on startup with ABI mismatch.

**Diagnosis**:
```bash
# Check Electron's Node.js version
npx electron -e "console.log(process.versions)"

# Compare with installed native module target
node -p "require('./node_modules/better-sqlite3/package.json').binary?.napi_versions"
```

**Fix**: Pin Electron version and rebuild:
```bash
# Lock Electron version in package.json (exact, no caret)
npm install electron@33.0.0 --save-exact --save-dev
npx @electron/rebuild
```

### Webpack/Vite Build Errors

**Problem**: Bundler fails to resolve Electron modules or Node.js built-ins.

**Webpack fix**:
```javascript
// webpack.config.js
module.exports = {
  target: 'electron-renderer', // or 'electron-main'
  externals: {
    electron: 'commonjs electron',
  },
  resolve: {
    fallback: {
      path: false,
      fs: false,
      os: false,
    },
  },
};
```

**Vite fix**:
```typescript
// vite.config.ts
import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    rollupOptions: {
      external: ['electron'],
    },
  },
  resolve: {
    // Don't resolve Node.js builtins in renderer
    conditions: ['browser'],
  },
});
```

**Common errors**:
- `Module not found: Error: Can't resolve 'fs'` → Add to `externals` or `resolve.fallback`
- `__dirname is not defined` → Set `target: 'electron-main'` or define `__dirname` in config
- `require is not defined` → Renderer is sandboxed — use IPC via preload

---

## Debugging Techniques

### Main Process Debugging

```bash
# Launch with inspector
electron --inspect=5858 .

# Break on first line
electron --inspect-brk=5858 .

# Connect with Chrome DevTools
# Open chrome://inspect in Chrome → configure target localhost:5858
```

**VS Code launch configuration**:
```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug Main Process",
      "type": "node",
      "request": "launch",
      "cwd": "${workspaceFolder}",
      "runtimeExecutable": "${workspaceFolder}/node_modules/.bin/electron",
      "args": ["."],
      "outputCapture": "std",
      "sourceMaps": true,
      "resolveSourceMapLocations": ["${workspaceFolder}/**", "!**/node_modules/**"]
    }
  ]
}
```

**Logging from main process**:
```bash
# Enable Electron internal logging
ELECTRON_ENABLE_LOGGING=1 electron .

# Enable verbose Chromium logs
ELECTRON_LOG_FILE=electron.log electron . --log-level=0
```

### Renderer Process Debugging

```typescript
// Open DevTools programmatically
win.webContents.openDevTools({ mode: 'detach' });

// Only in development
if (!app.isPackaged) {
  win.webContents.openDevTools();
}

// Log renderer console to main process terminal
win.webContents.on('console-message', (_event, level, message, line, sourceId) => {
  console.log(`[Renderer] ${message} (${sourceId}:${line})`);
});
```

**Remote debugging packaged apps**:
```bash
# Launch packaged app with remote debugging
./MyApp --remote-debugging-port=9222

# Connect from Chrome at chrome://inspect
```

### DevTools Extensions

Install React DevTools, Vue DevTools, or other extensions:

```typescript
import { session } from 'electron';
import path from 'node:path';

// Using electron-devtools-installer
import installExtension, { REACT_DEVELOPER_TOOLS } from 'electron-devtools-installer';

app.whenReady().then(async () => {
  if (!app.isPackaged) {
    try {
      await installExtension(REACT_DEVELOPER_TOOLS);
      console.log('React DevTools installed');
    } catch (err) {
      console.error('Failed to install extension:', err);
    }
  }
});

// Manual installation — load unpacked extension
app.whenReady().then(async () => {
  await session.defaultSession.loadExtension(
    path.join(os.homedir(), '.config/google-chrome/Default/Extensions/fmkadmapgofadopljbjfkapdkoienihi/5.0.2_0')
  );
});
```

### Logging Best Practices

```typescript
// Use electron-log for production logging
import log from 'electron-log';

log.transports.file.level = 'info';
log.transports.file.maxSize = 10 * 1024 * 1024; // 10 MB
log.transports.file.resolvePathFn = () =>
  path.join(app.getPath('userData'), 'logs', 'app.log');

// Replace console in main process
Object.assign(console, log.functions);

// Log unhandled errors
process.on('uncaughtException', (error) => {
  log.error('Uncaught exception:', error);
});

process.on('unhandledRejection', (reason) => {
  log.error('Unhandled rejection:', reason);
});

// Log file locations by platform:
// macOS: ~/Library/Logs/{app name}/
// Windows: %USERPROFILE%\AppData\Roaming\{app name}\logs\
// Linux: ~/.config/{app name}/logs/
```

---

## Memory Leaks

### Detached DOM Nodes

**Symptom**: Renderer memory grows continuously. Heap snapshots show increasing "(detached)" node counts.

**Common causes**:
1. Event listeners referencing removed DOM elements
2. Closures capturing DOM references
3. Framework component unmount not cleaning up

**Detection**:
```typescript
// In DevTools Console:
// 1. Take heap snapshot
// 2. Perform action that should free memory
// 3. Force GC (click trash icon)
// 4. Take another snapshot
// 5. Compare — filter for "Detached"
```

**Fix pattern**:
```typescript
// BAD — event listener keeps reference to removed element
const el = document.createElement('div');
document.body.appendChild(el);
window.addEventListener('resize', () => {
  el.style.width = window.innerWidth + 'px'; // el leaked after removal
});

// GOOD — use AbortController for cleanup
const controller = new AbortController();
const el = document.createElement('div');
document.body.appendChild(el);
window.addEventListener('resize', () => {
  el.style.width = window.innerWidth + 'px';
}, { signal: controller.signal });

// When removing element:
controller.abort();
document.body.removeChild(el);
```

### IPC Listener Leaks

**Symptom**: `MaxListenersExceededWarning` in console. Memory grows with each window open/close cycle.

**Cause**: Adding IPC listeners without removing them when windows close.

```typescript
// BAD — listener added on every window creation, never removed
function createWindow() {
  const win = new BrowserWindow({ /* ... */ });
  ipcMain.on('some-event', (_event, data) => {
    win.webContents.send('response', data);
    // ⚠️ This listener persists after win is closed, referencing a destroyed window
  });
}

// GOOD — clean up listeners on window close
function createWindow() {
  const win = new BrowserWindow({ /* ... */ });
  const handler = (_event: IpcMainEvent, data: unknown) => {
    if (!win.isDestroyed()) {
      win.webContents.send('response', data);
    }
  };
  ipcMain.on('some-event', handler);
  win.on('closed', () => {
    ipcMain.removeListener('some-event', handler);
  });
}

// BETTER — use ipcMain.handle (auto-scoped to request-response)
ipcMain.handle('some-request', async (_event, data) => {
  return processData(data); // No window reference needed
});
```

**Preload-side cleanup**:
```typescript
// Preload — provide cleanup function
contextBridge.exposeInMainWorld('api', {
  onUpdate: (callback: (data: unknown) => void) => {
    const handler = (_event: IpcRendererEvent, data: unknown) => callback(data);
    ipcRenderer.on('update', handler);
    return () => ipcRenderer.removeListener('update', handler); // Return cleanup function
  },
});

// React component — clean up on unmount
useEffect(() => {
  const cleanup = window.api.onUpdate((data) => setData(data));
  return cleanup;
}, []);
```

### BrowserWindow Reference Leaks

```typescript
// BAD — global reference to closed window
let settingsWindow: BrowserWindow | null = null;

function openSettings() {
  settingsWindow = new BrowserWindow({ /* ... */ });
  settingsWindow.on('closed', () => {
    // ⚠️ Forgetting to null the reference prevents GC
  });
}

// GOOD — null reference on close
function openSettings() {
  settingsWindow = new BrowserWindow({ /* ... */ });
  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}
```

### Profiling Memory Usage

```typescript
// Main process memory
console.log('Main process memory:', process.memoryUsage());
// { rss, heapTotal, heapUsed, external, arrayBuffers }

// Renderer process memory
const metrics = app.getAppMetrics();
for (const proc of metrics) {
  console.log(`PID ${proc.pid} (${proc.type}): ${proc.memory.workingSetSize} KB`);
}

// Periodic monitoring
setInterval(() => {
  const metrics = app.getAppMetrics();
  const total = metrics.reduce((sum, p) => sum + p.memory.workingSetSize, 0);
  console.log(`Total memory: ${(total / 1024).toFixed(1)} MB`);
}, 30000);
```

---

## ASAR Issues

### ASAR Extraction Failures

**Problem**: Packaged app fails to read files from ASAR archive.

**Common errors**:
```
Error: ENOENT: no such file or directory, open '/path/to/app.asar/some-file'
ASAR integrity check failed
```

**Fixes**:

```javascript
// Force extraction for specific files/directories in electron-builder
// package.json
{
  "build": {
    "asarUnpack": [
      "node_modules/sharp/**/*",
      "node_modules/better-sqlite3/**/*",
      "resources/**/*.node"
    ]
  }
}

// In Electron Forge
// forge.config.ts
{
  packagerConfig: {
    asar: {
      unpack: "**/*.{node,dll,so,dylib}"
    }
  }
}
```

### Native Modules Inside ASAR

Native `.node` modules cannot be loaded from inside an ASAR archive. They must be unpacked.

```json
// electron-builder: asarUnpack globs
{
  "build": {
    "asarUnpack": ["**/*.node"]
  }
}
```

At runtime, Electron transparently redirects ASAR paths to the `app.asar.unpacked` directory. No code changes needed — just configure `asarUnpack`.

### File Path Resolution in ASAR

```typescript
// __dirname inside ASAR returns the ASAR path
// e.g., /path/to/resources/app.asar/src

// For files that must exist on disk (e.g., spawning a binary):
import { app } from 'electron';

// Use app.getAppPath() for the ASAR root
const appPath = app.getAppPath();

// For unpacked files, replace .asar with .asar.unpacked
const unpackedPath = appPath.replace('app.asar', 'app.asar.unpacked');

// For extraResources (files outside ASAR)
const resourcePath = process.resourcesPath; // /path/to/resources/
```

---

## White Screen on Startup

### Common Causes

1. **Failed to load entry file** — wrong path in `loadFile()` / `loadURL()`
2. **Uncaught exception in renderer** — JS error prevents rendering
3. **Missing build output** — `dist/` folder not generated before packaging
4. **CSP blocking scripts** — Content Security Policy prevents script execution
5. **Protocol registration failed** — custom protocol not serving files
6. **Incorrect `main` field** — `package.json` `main` points to wrong file

### Diagnostic Steps

```typescript
// 1. Check for renderer errors
win.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
  console.error(`Failed to load: ${validatedURL} — ${errorDescription} (${errorCode})`);
});

// 2. Check for crashes
win.webContents.on('render-process-gone', (_event, details) => {
  console.error('Renderer crashed:', details.reason, details.exitCode);
});

// 3. Open DevTools before content loads
win.webContents.openDevTools();

// 4. Log the URL being loaded
console.log('Loading:', win.webContents.getURL());

// 5. Check if file exists
const entryPath = path.join(__dirname, 'dist', 'index.html');
console.log('Entry exists:', fs.existsSync(entryPath), entryPath);
```

### Fixes

```typescript
// Fix 1: Use correct path resolution
// BAD — relative path breaks in packaged app
win.loadFile('index.html');
// GOOD — resolve from __dirname
win.loadFile(path.join(__dirname, 'index.html'));

// Fix 2: Show window only after content loads
const win = new BrowserWindow({ show: false });
win.once('ready-to-show', () => win.show());

// Fix 3: Fallback on load failure
win.webContents.on('did-fail-load', () => {
  // Retry or show error page
  win.loadFile(path.join(__dirname, 'error.html'));
});

// Fix 4: For Vite/Webpack dev mode — use loadURL
if (process.env.NODE_ENV === 'development') {
  win.loadURL('http://localhost:5173');
} else {
  win.loadFile(path.join(__dirname, '../renderer/index.html'));
}
```

---

## Auto-Updater Errors

### electron-updater Issues

**Problem**: Updates fail silently or with cryptic errors.

**Common errors and fixes**:

```
Error: net::ERR_CONNECTION_REFUSED
```
→ Update server unreachable. Check `publish` config URL and network.

```
Error: Cannot find latest.yml / latest-mac.yml
```
→ Missing update manifest. Ensure `electron-builder --publish always` uploaded all artifacts.

```
Error: sha512 checksum mismatch
```
→ Corrupted download or mismatched manifest. Rebuild and republish.

```
Error: EACCES: permission denied
```
→ App installed in protected directory. On Linux, avoid `/opt`; prefer user-writable paths.

**Debugging auto-updater**:

```typescript
import { autoUpdater } from 'electron-updater';
import log from 'electron-log';

// Enable verbose logging
autoUpdater.logger = log;
(autoUpdater.logger as typeof log).transports.file.level = 'debug';

// Log all events
autoUpdater.on('checking-for-update', () => log.info('Checking for update...'));
autoUpdater.on('update-available', (info) => log.info('Update available:', info));
autoUpdater.on('update-not-available', (info) => log.info('No update:', info));
autoUpdater.on('download-progress', (progress) => log.info('Progress:', progress.percent));
autoUpdater.on('update-downloaded', (info) => log.info('Downloaded:', info));
autoUpdater.on('error', (err) => log.error('Update error:', err));
```

### Code Signing and Update Verification

**Problem**: Update fails signature verification on macOS or Windows.

**macOS**:
- Updates MUST be code-signed with the same Apple Developer certificate
- Hardened runtime must be enabled
- App must be notarized
- `autoUpdater` uses Squirrel.Mac which verifies code signature automatically

**Windows**:
- NSIS installer verifies Authenticode signature
- If you change signing certificate, users must reinstall
- Set `publisherName` in `build` config to match certificate CN

```json
{
  "build": {
    "win": {
      "publisherName": "Your Company Name",
      "verifyUpdateCodeSignature": true
    }
  }
}
```

### Update Server Configuration

**GitHub Releases** (simplest):
```json
{
  "build": {
    "publish": [{
      "provider": "github",
      "owner": "your-org",
      "repo": "your-app",
      "releaseType": "release"
    }]
  }
}
```

**Generic server**:
```json
{
  "build": {
    "publish": [{
      "provider": "generic",
      "url": "https://updates.example.com/releases",
      "channel": "latest"
    }]
  }
}
```

Required files on the server:
- `latest.yml` / `latest-mac.yml` / `latest-linux.yml` — update manifest
- The actual installer files (`.exe`, `.dmg`, `.AppImage`)

**Staged rollouts**:
```typescript
// Implement staged rollouts with a staging percentage
autoUpdater.currentVersion // check current version
// Use autoUpdater.channel to switch between 'latest', 'beta', 'alpha'
autoUpdater.channel = 'beta';
```

---

## Platform-Specific Bugs

### macOS: Notarization Failures

**Problem**: App rejected by Apple notarization service.

**Common errors**:

```
The executable does not have the hardened runtime enabled.
```
→ Enable hardened runtime:
```json
{
  "build": {
    "mac": {
      "hardenedRuntime": true,
      "gatekeeperAssess": false,
      "entitlements": "build/entitlements.mac.plist",
      "entitlementsInherit": "build/entitlements.mac.plist"
    }
  }
}
```

**Required entitlements** (`build/entitlements.mac.plist`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
```

**Notarization with `@electron/notarize`**:
```typescript
// electron-builder afterSign hook
const { notarize } = require('@electron/notarize');

exports.default = async function notarizing(context) {
  if (context.electronPlatformName !== 'darwin') return;

  await notarize({
    appPath: context.appOutDir + `/${context.packager.appInfo.productFilename}.app`,
    appleId: process.env.APPLE_ID,
    appleIdPassword: process.env.APPLE_APP_SPECIFIC_PASSWORD,
    teamId: process.env.APPLE_TEAM_ID,
  });
};
```

### macOS: Hardened Runtime Issues

**Problem**: App crashes or features break after enabling hardened runtime.

**Symptoms**:
- JIT compilation fails (V8, WebAssembly)
- Dynamic libraries won't load
- Crash on startup with code signature errors

**Fix**: Add necessary entitlements (see above). The three entitlements listed are required for Electron to function with hardened runtime.

### Windows: ASAR Integrity Errors

**Problem**: App fails to start with "ASAR integrity check failed" on Windows.

**Causes**:
- Antivirus modified the ASAR file
- Incomplete installation or update
- File corruption during download

**Fix**:
```json
// Disable ASAR integrity in electron-builder (not recommended for production)
{
  "build": {
    "asar": true,
    "asarUnpack": ["**/*.node"],
    "win": {
      "artifactName": "${productName}-Setup-${version}.${ext}"
    }
  }
}
```

**Better fix**: Use Electron Fuses to control integrity checking:
```bash
npx @electron/fuses read --app /path/to/MyApp.exe
npx @electron/fuses write --app /path/to/MyApp.exe EnableEmbeddedAsarIntegrityValidation=off
```

### Windows: SmartScreen Warnings

**Problem**: Windows SmartScreen shows "Windows protected your PC" when users run the installer.

**Solutions**:
1. **Code sign with EV certificate** — Extended Validation (EV) certificates build SmartScreen reputation immediately
2. **Standard certificate** — Reputation builds over time as more users install
3. **Submit to Microsoft** — Use the [SmartScreen reporting form](https://www.microsoft.com/en-us/wdsi/filesubmission)

```json
// Ensure code signing is configured
{
  "build": {
    "win": {
      "certificateFile": "cert.pfx",
      "certificatePassword": "",
      "signingHashAlgorithms": ["sha256"],
      "rfc3161TimeStampServer": "http://timestamp.digicert.com"
    }
  }
}
```

### Windows: DLL Load Failures

**Problem**: Native modules fail with "The specified module could not be found" even though the `.node` file exists.

**Cause**: Missing Visual C++ Redistributable or dependent DLLs.

**Fix**:
```json
// Bundle VC++ Redistributable in NSIS installer
{
  "build": {
    "nsis": {
      "include": "build/installer.nsh"
    }
  }
}
```

```nsis
; build/installer.nsh
!macro customInstall
  ; Install VC++ 2015-2022 Redistributable
  ExecWait '"$INSTDIR\resources\vc_redist.x64.exe" /install /quiet /norestart'
!macroend
```

**Diagnosis**:
```bash
# Use Dependencies tool (Windows) to check DLL dependencies
# https://github.com/lucasg/Dependencies
Dependencies.exe -chain path\to\module.node
```

### Linux: Sandbox Errors

**Problem**: App crashes on startup with sandbox-related errors.

```
[FATAL:setuid_sandbox_host.cc] The SUID sandbox helper binary was found, but is not configured correctly.
```

**Fixes**:

```bash
# Option 1: Fix sandbox permissions (preferred)
sudo chown root:root chrome-sandbox
sudo chmod 4755 chrome-sandbox

# Option 2: Disable sandbox (NOT recommended for production)
# Launch with --no-sandbox flag
./MyApp --no-sandbox

# Option 3: Use the unprivileged user namespace sandbox
# Ensure kernel supports it:
sysctl kernel.unprivileged_userns_clone
# Enable if disabled:
sudo sysctl -w kernel.unprivileged_userns_clone=1
```

**In AppImage**: Sandbox issues are common because AppImage runs in a FUSE mount:
```bash
# AppImage with sandbox — requires --no-sandbox or namespace sandbox
./MyApp.AppImage --no-sandbox
```

### Linux: Tray Icon Issues

**Problem**: Tray icon doesn't appear, appears as empty, or doesn't respond to clicks.

**Causes and fixes**:
- **GNOME**: Requires AppIndicator extension. Install `gnome-shell-extension-appindicator`
- **KDE**: Works natively with `StatusNotifierItem`
- **Wayland**: Tray support varies; XWayland compatibility may help
- **Icon format**: Use PNG, not SVG. Provide multiple sizes (16x16, 22x22, 24x24, 48x48)

```typescript
// Provide fallback icon path
const iconPath = process.platform === 'linux'
  ? path.join(__dirname, 'assets', 'tray-icon@2x.png')
  : path.join(__dirname, 'assets', 'tray-icon.png');

const tray = new Tray(nativeImage.createFromPath(iconPath));

// Workaround for click not working on some Linux DEs
tray.on('click', () => {
  // Some DEs only support context menu, not click
  tray.popUpContextMenu();
});
```
