/**
 * Electron Preload Script Template
 *
 * This preload script uses contextBridge to expose a typed, scoped API
 * to the renderer process. It follows Electron security best practices:
 *
 * - Never exposes raw ipcRenderer
 * - Each IPC channel is wrapped in a named function
 * - Listener registrations return cleanup functions
 * - No Node.js APIs leak to the renderer
 *
 * Usage:
 *   Copy this file and adjust the API surface to match your app's needs.
 *   In the renderer, access the API via `window.electronAPI`.
 */

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';

// ─── Type Definitions ─────────────────────────────────────────────────────────

interface AppInfo {
  name: string;
  version: string;
  platform: string;
  arch: string;
  electronVersion: string;
}

interface FileFilter {
  name: string;
  extensions: string[];
}

interface OpenDialogOptions {
  properties?: Array<'openFile' | 'openDirectory' | 'multiSelections'>;
  filters?: FileFilter[];
}

interface SaveDialogOptions {
  defaultPath?: string;
  filters?: FileFilter[];
}

type Theme = 'light' | 'dark' | 'system';
type CleanupFunction = () => void;

// ─── API Definition ───────────────────────────────────────────────────────────

const electronAPI = {
  // ── App Info ──────────────────────────────────────────────────────────────
  getAppInfo: (): Promise<AppInfo> => ipcRenderer.invoke('app:get-info'),

  // ── Theme ─────────────────────────────────────────────────────────────────
  getTheme: (): Promise<'light' | 'dark'> => ipcRenderer.invoke('theme:get'),
  setTheme: (theme: Theme): Promise<void> => ipcRenderer.invoke('theme:set', theme),
  onThemeChanged: (callback: (theme: 'light' | 'dark') => void): CleanupFunction => {
    const handler = (_event: IpcRendererEvent, theme: 'light' | 'dark') => callback(theme);
    ipcRenderer.on('theme:changed', handler);
    return () => ipcRenderer.removeListener('theme:changed', handler);
  },

  // ── Dialogs ───────────────────────────────────────────────────────────────
  openFileDialog: (options?: OpenDialogOptions): Promise<string[] | null> =>
    ipcRenderer.invoke('dialog:open-file', options),
  saveFileDialog: (options?: SaveDialogOptions): Promise<string | null> =>
    ipcRenderer.invoke('dialog:save-file', options),

  // ── File System (scoped to userData) ──────────────────────────────────────
  readFile: (relativePath: string): Promise<string> =>
    ipcRenderer.invoke('fs:read-file', relativePath),
  writeFile: (relativePath: string, content: string): Promise<void> =>
    ipcRenderer.invoke('fs:write-file', relativePath, content),

  // ── External Links ────────────────────────────────────────────────────────
  openExternal: (url: string): Promise<void> =>
    ipcRenderer.invoke('shell:open-external', url),

  // ── Generic Event Listeners ───────────────────────────────────────────────
  // Add app-specific listeners below. Always return a cleanup function.

  /**
   * Listen for update availability notifications from the main process.
   * Returns a cleanup function to remove the listener.
   */
  onUpdateAvailable: (callback: (info: { version: string }) => void): CleanupFunction => {
    const handler = (_event: IpcRendererEvent, info: { version: string }) => callback(info);
    ipcRenderer.on('update:available', handler);
    return () => ipcRenderer.removeListener('update:available', handler);
  },

  /**
   * Listen for download progress from the main process.
   * Returns a cleanup function to remove the listener.
   */
  onDownloadProgress: (callback: (progress: { percent: number }) => void): CleanupFunction => {
    const handler = (_event: IpcRendererEvent, progress: { percent: number }) => callback(progress);
    ipcRenderer.on('update:progress', handler);
    return () => ipcRenderer.removeListener('update:progress', handler);
  },
};

// ─── Expose API ───────────────────────────────────────────────────────────────

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

// ─── Type Export for Renderer ─────────────────────────────────────────────────

/**
 * Add this to your renderer's global type declarations:
 *
 * ```typescript
 * // src/types/electron.d.ts
 * type ElectronAPI = typeof import('../preload').electronAPI;
 *
 * declare global {
 *   interface Window {
 *     electronAPI: ElectronAPI;
 *   }
 * }
 * ```
 */

export type { AppInfo, FileFilter, OpenDialogOptions, SaveDialogOptions, Theme, CleanupFunction };
export { electronAPI };
