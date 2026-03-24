/**
 * Electron Main Process Template
 *
 * Best practices:
 * - contextIsolation: true, sandbox: true, nodeIntegration: false
 * - Typed IPC handlers with input validation
 * - Window state persistence
 * - Graceful lifecycle management
 * - Security headers (CSP) for all responses
 * - Permission request handling
 * - Navigation restriction
 */

import {
  app,
  BrowserWindow,
  ipcMain,
  session,
  shell,
  dialog,
  nativeTheme,
} from 'electron';
import path from 'node:path';
import fs from 'node:fs';

// Handle Squirrel events for Windows installers (electron-forge NSIS/Squirrel)
if (require('electron-squirrel-startup')) app.quit();

// ─── Constants ────────────────────────────────────────────────────────────────

const IS_DEV = !app.isPackaged;
const PRELOAD_PATH = path.join(__dirname, 'preload.js');
const USER_DATA_PATH = app.getPath('userData');

// ─── Window State Persistence ─────────────────────────────────────────────────

interface WindowState {
  x?: number;
  y?: number;
  width: number;
  height: number;
  isMaximized: boolean;
}

function getWindowStatePath(id: string): string {
  return path.join(USER_DATA_PATH, `window-state-${id}.json`);
}

function loadWindowState(id: string, defaults: { width: number; height: number }): WindowState {
  try {
    const data = JSON.parse(fs.readFileSync(getWindowStatePath(id), 'utf-8'));
    return { ...defaults, ...data };
  } catch {
    return { ...defaults, isMaximized: false };
  }
}

function saveWindowState(id: string, win: BrowserWindow): void {
  if (win.isDestroyed()) return;
  const bounds = win.getNormalBounds();
  const state: WindowState = {
    ...bounds,
    isMaximized: win.isMaximized(),
  };
  fs.writeFileSync(getWindowStatePath(id), JSON.stringify(state));
}

// ─── Window Creation ──────────────────────────────────────────────────────────

let mainWindow: BrowserWindow | null = null;

function createMainWindow(): BrowserWindow {
  const state = loadWindowState('main', { width: 1200, height: 800 });

  const win = new BrowserWindow({
    ...state,
    minWidth: 800,
    minHeight: 600,
    show: false, // Show after ready-to-show to prevent flash
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      preload: PRELOAD_PATH,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
    },
  });

  if (state.isMaximized) win.maximize();

  // Show when ready to prevent white flash
  win.once('ready-to-show', () => win.show());

  // Persist window state
  let saveTimeout: NodeJS.Timeout;
  const debouncedSave = () => {
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(() => saveWindowState('main', win), 500);
  };
  win.on('resize', debouncedSave);
  win.on('move', debouncedSave);
  win.on('close', () => saveWindowState('main', win));

  // Load content
  if (IS_DEV && process.env.DEV_SERVER_URL) {
    win.loadURL(process.env.DEV_SERVER_URL);
    win.webContents.openDevTools({ mode: 'detach' });
  } else {
    win.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  win.on('closed', () => {
    mainWindow = null;
  });

  return win;
}

// ─── Security: Content Security Policy ────────────────────────────────────────

function setupCSP(): void {
  const csp = IS_DEV
    ? "default-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-eval'; connect-src 'self' ws://localhost:*"
    : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'";

  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [csp],
      },
    });
  });
}

// ─── Security: Permission Handling ────────────────────────────────────────────

function setupPermissions(): void {
  const allowedPermissions = new Set(['clipboard-read', 'clipboard-sanitized-write', 'notifications']);

  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(allowedPermissions.has(permission));
  });

  session.defaultSession.setPermissionCheckHandler((_webContents, permission) => {
    return allowedPermissions.has(permission);
  });
}

// ─── Security: Navigation Restrictions ────────────────────────────────────────

function setupNavigationSecurity(): void {
  app.on('web-contents-created', (_event, contents) => {
    // Restrict navigation
    contents.on('will-navigate', (event, navigationUrl) => {
      const parsedUrl = new URL(navigationUrl);
      if (parsedUrl.protocol !== 'file:' && parsedUrl.protocol !== 'app:') {
        if (!IS_DEV || !navigationUrl.startsWith('http://localhost')) {
          event.preventDefault();
        }
      }
    });

    // Restrict new window creation — open external links in browser
    contents.setWindowOpenHandler(({ url }) => {
      if (url.startsWith('https://')) {
        shell.openExternal(url);
      }
      return { action: 'deny' };
    });

    // Block webview creation
    contents.on('will-attach-webview', (event) => {
      event.preventDefault();
    });
  });
}

// ─── IPC Handlers ─────────────────────────────────────────────────────────────

function setupIPC(): void {
  // System info
  ipcMain.handle('app:get-info', () => ({
    name: app.getName(),
    version: app.getVersion(),
    platform: process.platform,
    arch: process.arch,
    electronVersion: process.versions.electron,
  }));

  // Theme
  ipcMain.handle('theme:get', () => nativeTheme.shouldUseDarkColors ? 'dark' : 'light');
  ipcMain.handle('theme:set', (_event, theme: unknown) => {
    if (theme !== 'light' && theme !== 'dark' && theme !== 'system') {
      throw new Error('Invalid theme');
    }
    nativeTheme.themeSource = theme;
  });

  nativeTheme.on('updated', () => {
    mainWindow?.webContents.send('theme:changed', nativeTheme.shouldUseDarkColors ? 'dark' : 'light');
  });

  // File dialogs
  ipcMain.handle('dialog:open-file', async (_event, options: unknown) => {
    const opts = validateOpenDialogOptions(options);
    const result = await dialog.showOpenDialog(mainWindow!, opts);
    return result.canceled ? null : result.filePaths;
  });

  ipcMain.handle('dialog:save-file', async (_event, options: unknown) => {
    const opts = validateSaveDialogOptions(options);
    const result = await dialog.showSaveDialog(mainWindow!, opts);
    return result.canceled ? null : result.filePath;
  });

  // File operations (scoped to userData)
  ipcMain.handle('fs:read-file', async (_event, relativePath: unknown) => {
    const filePath = resolveUserDataPath(relativePath);
    return fs.promises.readFile(filePath, 'utf-8');
  });

  ipcMain.handle('fs:write-file', async (_event, relativePath: unknown, content: unknown) => {
    const filePath = resolveUserDataPath(relativePath);
    if (typeof content !== 'string') throw new Error('Content must be a string');
    if (content.length > 50 * 1024 * 1024) throw new Error('Content too large (50MB limit)');
    await fs.promises.mkdir(path.dirname(filePath), { recursive: true });
    await fs.promises.writeFile(filePath, content, 'utf-8');
  });

  // External links
  ipcMain.handle('shell:open-external', async (_event, url: unknown) => {
    if (typeof url !== 'string') throw new Error('URL must be a string');
    const parsed = new URL(url); // throws on invalid URL
    if (parsed.protocol !== 'https:') throw new Error('Only HTTPS URLs allowed');
    await shell.openExternal(url);
  });
}

// ─── Input Validation Helpers ─────────────────────────────────────────────────

function resolveUserDataPath(relativePath: unknown): string {
  if (typeof relativePath !== 'string') throw new Error('Path must be a string');
  if (relativePath.includes('\0')) throw new Error('Invalid path');
  const resolved = path.resolve(USER_DATA_PATH, relativePath);
  if (!resolved.startsWith(USER_DATA_PATH)) throw new Error('Path traversal detected');
  return resolved;
}

function validateOpenDialogOptions(options: unknown): Electron.OpenDialogOptions {
  if (!options || typeof options !== 'object') return {};
  const opts = options as Record<string, unknown>;
  return {
    properties: Array.isArray(opts.properties) ? opts.properties.filter((p): p is 'openFile' | 'openDirectory' | 'multiSelections' =>
      typeof p === 'string' && ['openFile', 'openDirectory', 'multiSelections'].includes(p)
    ) : ['openFile'],
    filters: Array.isArray(opts.filters) ? opts.filters.filter((f): f is Electron.FileFilter =>
      typeof f === 'object' && typeof f.name === 'string' && Array.isArray(f.extensions)
    ) : undefined,
  };
}

function validateSaveDialogOptions(options: unknown): Electron.SaveDialogOptions {
  if (!options || typeof options !== 'object') return {};
  const opts = options as Record<string, unknown>;
  return {
    defaultPath: typeof opts.defaultPath === 'string' ? opts.defaultPath : undefined,
    filters: Array.isArray(opts.filters) ? opts.filters.filter((f): f is Electron.FileFilter =>
      typeof f === 'object' && typeof f.name === 'string' && Array.isArray(f.extensions)
    ) : undefined,
  };
}

// ─── App Lifecycle ────────────────────────────────────────────────────────────

// Single instance lock
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', (_event, _argv, _workingDir) => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });
}

app.whenReady().then(() => {
  setupCSP();
  setupPermissions();
  setupNavigationSecurity();
  setupIPC();

  mainWindow = createMainWindow();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    mainWindow = createMainWindow();
  }
});

// Graceful error handling
process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error);
});

process.on('unhandledRejection', (reason) => {
  console.error('Unhandled rejection:', reason);
});
