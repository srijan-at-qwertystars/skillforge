/**
 * React hooks for Tauri v2: invoke commands, listen to events, manage windows.
 *
 * Usage:
 *   import { useInvoke, useTauriEvent, useWindow } from './react-tauri-hooks';
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen, emit, type UnlistenFn } from '@tauri-apps/api/event';
import { getCurrentWindow, type Window } from '@tauri-apps/api/window';

// ─── useInvoke ───────────────────────────────────────────────

interface UseInvokeOptions<T> {
  /** Arguments to pass to the command */
  args?: Record<string, unknown>;
  /** Call the command immediately on mount (default: true) */
  immediate?: boolean;
  /** Transform the result before setting state */
  transform?: (data: T) => T;
  /** Called on error */
  onError?: (error: string) => void;
}

interface UseInvokeResult<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
  /** Manually re-invoke the command */
  refetch: (overrideArgs?: Record<string, unknown>) => Promise<T | null>;
}

/**
 * Hook to invoke a Tauri command with automatic state management.
 *
 * @example
 * const { data, loading, error, refetch } = useInvoke<string>('greet', {
 *   args: { name: 'World' },
 * });
 */
export function useInvoke<T>(
  command: string,
  options: UseInvokeOptions<T> = {},
): UseInvokeResult<T> {
  const { args, immediate = true, transform, onError } = options;
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(immediate);
  const mountedRef = useRef(true);

  const refetch = useCallback(
    async (overrideArgs?: Record<string, unknown>) => {
      setLoading(true);
      setError(null);
      try {
        let result = await invoke<T>(command, overrideArgs ?? args);
        if (transform) result = transform(result);
        if (mountedRef.current) {
          setData(result);
          setLoading(false);
        }
        return result;
      } catch (e) {
        const errMsg = e instanceof Error ? e.message : String(e);
        if (mountedRef.current) {
          setError(errMsg);
          setLoading(false);
        }
        onError?.(errMsg);
        return null;
      }
    },
    [command, JSON.stringify(args)],
  );

  useEffect(() => {
    mountedRef.current = true;
    if (immediate) {
      refetch();
    }
    return () => {
      mountedRef.current = false;
    };
  }, [refetch, immediate]);

  return { data, error, loading, refetch };
}

// ─── useTauriEvent ───────────────────────────────────────────

/**
 * Hook to listen for Tauri events with automatic cleanup.
 *
 * @example
 * useTauriEvent<{ progress: number }>('download-progress', (payload) => {
 *   setProgress(payload.progress);
 * });
 */
export function useTauriEvent<T>(
  eventName: string,
  handler: (payload: T) => void,
): void {
  const handlerRef = useRef(handler);
  handlerRef.current = handler;

  useEffect(() => {
    let unlisten: UnlistenFn | undefined;

    listen<T>(eventName, (event) => {
      handlerRef.current(event.payload);
    }).then((fn) => {
      unlisten = fn;
    });

    return () => {
      unlisten?.();
    };
  }, [eventName]);
}

// ─── useEmit ─────────────────────────────────────────────────

/**
 * Hook that returns a stable emit function for sending events to the backend.
 *
 * @example
 * const emitEvent = useEmit();
 * await emitEvent('start-sync', { force: true });
 */
export function useEmit() {
  return useCallback(
    async (eventName: string, payload?: unknown) => {
      await emit(eventName, payload);
    },
    [],
  );
}

// ─── useWindow ───────────────────────────────────────────────

interface UseWindowResult {
  window: Window;
  minimize: () => Promise<void>;
  maximize: () => Promise<void>;
  toggleMaximize: () => Promise<void>;
  close: () => Promise<void>;
  hide: () => Promise<void>;
  show: () => Promise<void>;
  setTitle: (title: string) => Promise<void>;
  isMaximized: boolean;
  isFocused: boolean;
  isFullscreen: boolean;
}

/**
 * Hook for managing the current Tauri window.
 *
 * @example
 * const { minimize, maximize, close, isMaximized, setTitle } = useWindow();
 */
export function useWindow(): UseWindowResult {
  const windowRef = useRef(getCurrentWindow());
  const [isMaximized, setIsMaximized] = useState(false);
  const [isFocused, setIsFocused] = useState(true);
  const [isFullscreen, setIsFullscreen] = useState(false);

  useEffect(() => {
    const win = windowRef.current;

    // Initial state
    win.isMaximized().then(setIsMaximized);
    win.isFocused().then(setIsFocused);
    win.isFullscreen().then(setIsFullscreen);

    // Listen for window state changes
    const unlisteners: Promise<UnlistenFn>[] = [
      win.onResized(async () => {
        setIsMaximized(await win.isMaximized());
      }),
      win.onFocusChanged(({ payload }) => {
        setIsFocused(payload);
      }),
    ];

    return () => {
      unlisteners.forEach((p) => p.then((fn) => fn()));
    };
  }, []);

  const win = windowRef.current;

  return {
    window: win,
    minimize: useCallback(() => win.minimize(), [win]),
    maximize: useCallback(() => win.maximize(), [win]),
    toggleMaximize: useCallback(async () => {
      if (await win.isMaximized()) {
        await win.unmaximize();
      } else {
        await win.maximize();
      }
    }, [win]),
    close: useCallback(() => win.close(), [win]),
    hide: useCallback(() => win.hide(), [win]),
    show: useCallback(() => win.show(), [win]),
    setTitle: useCallback((title: string) => win.setTitle(title), [win]),
    isMaximized,
    isFocused,
    isFullscreen,
  };
}

// ─── useThrottledInvoke ──────────────────────────────────────

/**
 * Hook for invoking a command with throttling (useful for search-as-you-type).
 *
 * @example
 * const { invoke: search, data, loading } = useThrottledInvoke<SearchResult[]>('search', 300);
 * // In an input handler:
 * search({ query: inputValue });
 */
export function useThrottledInvoke<T>(command: string, delayMs: number = 300) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const throttledInvoke = useCallback(
    (args?: Record<string, unknown>) => {
      if (timerRef.current) clearTimeout(timerRef.current);

      setLoading(true);
      timerRef.current = setTimeout(async () => {
        try {
          const result = await invoke<T>(command, args);
          setData(result);
          setError(null);
        } catch (e) {
          setError(e instanceof Error ? e.message : String(e));
        } finally {
          setLoading(false);
        }
      }, delayMs);
    },
    [command, delayMs],
  );

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  return { invoke: throttledInvoke, data, loading, error };
}

// ─── useWindowDragDrop ───────────────────────────────────────

interface DragDropState {
  isDragging: boolean;
  droppedFiles: string[];
}

/**
 * Hook for handling file drag-and-drop on the window.
 *
 * @example
 * const { isDragging, droppedFiles } = useWindowDragDrop((files) => {
 *   console.log('Files dropped:', files);
 * });
 */
export function useWindowDragDrop(
  onDrop?: (files: string[]) => void,
): DragDropState {
  const [isDragging, setIsDragging] = useState(false);
  const [droppedFiles, setDroppedFiles] = useState<string[]>([]);
  const onDropRef = useRef(onDrop);
  onDropRef.current = onDrop;

  useTauriEvent<string[]>('drag-enter', () => setIsDragging(true));
  useTauriEvent<void>('drag-leave', () => setIsDragging(false));
  useTauriEvent<string[]>('files-dropped', (files) => {
    setIsDragging(false);
    setDroppedFiles(files);
    onDropRef.current?.(files);
  });

  return { isDragging, droppedFiles };
}
