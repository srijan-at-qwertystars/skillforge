/**
 * Robust WebSocket Client — TypeScript
 *
 * Features:
 *   - Auto-reconnect with exponential backoff + jitter
 *   - Message queue for offline/disconnected state
 *   - Heartbeat (client-initiated ping/pong)
 *   - Event emitter pattern with typed events
 *   - Connection state machine
 *   - Request/response correlation
 *   - Configurable serialization
 *
 * Usage (Browser):
 *   const ws = new RobustWebSocket('wss://api.example.com/ws', {
 *     auth: { token: 'your-jwt-token' },
 *   });
 *   ws.on('message', (data) => console.log('Received:', data));
 *   ws.send({ type: 'chat', text: 'Hello!' });
 *
 * Usage (Node.js):
 *   import WebSocket from 'ws';
 *   const ws = new RobustWebSocket('wss://api.example.com/ws', {
 *     WebSocketClass: WebSocket,
 *   });
 */

// ── Types ──────────────────────────────────────────────

type WSState = 'disconnected' | 'connecting' | 'connected' | 'reconnecting' | 'closed';

interface WSClientOptions {
  /** Max reconnection attempts before giving up (default: Infinity) */
  maxRetries?: number;
  /** Base delay for exponential backoff in ms (default: 500) */
  baseDelay?: number;
  /** Maximum delay between reconnection attempts in ms (default: 30000) */
  maxDelay?: number;
  /** Client heartbeat interval in ms (default: 25000) */
  heartbeatInterval?: number;
  /** Max time to wait for heartbeat response in ms (default: 10000) */
  heartbeatTimeout?: number;
  /** Max queued messages while disconnected (default: 100) */
  maxQueueSize?: number;
  /** Request timeout for request/response pattern in ms (default: 10000) */
  requestTimeout?: number;
  /** Auth config — passed in handshake */
  auth?: { token: string };
  /** WebSocket subprotocols */
  protocols?: string | string[];
  /** Custom WebSocket class (for Node.js — pass `ws` module) */
  WebSocketClass?: typeof WebSocket;
  /** Binary type for received messages */
  binaryType?: BinaryType;
}

interface WSEvent {
  type: string;
  id?: string;
  payload?: unknown;
  timestamp?: number;
  [key: string]: unknown;
}

type EventHandler<T = unknown> = (data: T) => void;
type StateChangeHandler = (state: WSState, prevState: WSState) => void;

// ── Client Implementation ──────────────────────────────

class RobustWebSocket {
  private ws: WebSocket | null = null;
  private state: WSState = 'disconnected';
  private attempt = 0;
  private queue: string[] = [];
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatTimeoutTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pendingRequests = new Map<string, {
    resolve: (value: unknown) => void;
    reject: (reason: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  // Event handlers
  private handlers = new Map<string, Set<EventHandler>>();
  private stateHandlers = new Set<StateChangeHandler>();
  private anyHandlers = new Set<EventHandler<WSEvent>>();

  private readonly options: Required<WSClientOptions>;

  constructor(
    private url: string,
    options: WSClientOptions = {},
  ) {
    this.options = {
      maxRetries: options.maxRetries ?? Infinity,
      baseDelay: options.baseDelay ?? 500,
      maxDelay: options.maxDelay ?? 30_000,
      heartbeatInterval: options.heartbeatInterval ?? 25_000,
      heartbeatTimeout: options.heartbeatTimeout ?? 10_000,
      maxQueueSize: options.maxQueueSize ?? 100,
      requestTimeout: options.requestTimeout ?? 10_000,
      auth: options.auth ?? { token: '' },
      protocols: options.protocols ?? [],
      WebSocketClass: options.WebSocketClass ?? WebSocket,
      binaryType: options.binaryType ?? 'arraybuffer',
    };

    this.connect();
  }

  // ── Public API ───────────────────────────────────────

  /** Send a message (queued if disconnected) */
  send(data: string | WSEvent): void {
    const serialized = typeof data === 'string' ? data : JSON.stringify(data);

    if (this.state === 'connected' && this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(serialized);
    } else {
      if (this.queue.length >= this.options.maxQueueSize) {
        this.queue.shift(); // drop oldest
      }
      this.queue.push(serialized);
    }
  }

  /** Send a request and wait for a correlated response */
  request<T = unknown>(type: string, payload?: unknown, timeout?: number): Promise<T> {
    return new Promise((resolve, reject) => {
      const id = this.generateId();
      const timeoutMs = timeout ?? this.options.requestTimeout;

      const timer = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Request timeout: ${type} (${timeoutMs}ms)`));
      }, timeoutMs);

      this.pendingRequests.set(id, {
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });

      this.send({ type, id, payload });
    });
  }

  /** Listen for a specific message type */
  on<T = unknown>(event: string, handler: EventHandler<T>): () => void {
    if (!this.handlers.has(event)) {
      this.handlers.set(event, new Set());
    }
    this.handlers.get(event)!.add(handler as EventHandler);

    // Return unsubscribe function
    return () => {
      this.handlers.get(event)?.delete(handler as EventHandler);
    };
  }

  /** Listen for a message type once */
  once<T = unknown>(event: string, handler: EventHandler<T>): () => void {
    const wrappedHandler: EventHandler = (data) => {
      unsub();
      (handler as EventHandler)(data);
    };
    const unsub = this.on(event, wrappedHandler);
    return unsub;
  }

  /** Listen for all messages */
  onAny(handler: EventHandler<WSEvent>): () => void {
    this.anyHandlers.add(handler);
    return () => this.anyHandlers.delete(handler);
  }

  /** Listen for state changes */
  onStateChange(handler: StateChangeHandler): () => void {
    this.stateHandlers.add(handler);
    return () => this.stateHandlers.delete(handler);
  }

  /** Remove all listeners for an event (or all events) */
  off(event?: string): void {
    if (event) {
      this.handlers.delete(event);
    } else {
      this.handlers.clear();
      this.anyHandlers.clear();
    }
  }

  /** Get current connection state */
  getState(): WSState {
    return this.state;
  }

  /** Get queued message count */
  getQueueSize(): number {
    return this.queue.length;
  }

  /** Manually trigger reconnection */
  reconnect(): void {
    if (this.state === 'closed') return;
    this.attempt = 0;
    this.disconnect(false);
    this.connect();
  }

  /** Close connection permanently (no reconnect) */
  close(): void {
    this.setState('closed');
    this.cleanup();
    this.ws?.close(1000, 'Client closed');
    this.ws = null;
    this.rejectAllPending('Connection closed');
  }

  /** Disconnect (will reconnect unless permanently closed) */
  disconnect(permanent = true): void {
    if (permanent) {
      this.close();
    } else {
      this.cleanup();
      this.ws?.close(1000);
      this.ws = null;
    }
  }

  // ── Internal ─────────────────────────────────────────

  private connect(): void {
    if (this.state === 'closed') return;
    this.setState(this.attempt > 0 ? 'reconnecting' : 'connecting');

    try {
      const protocols = this.options.auth.token
        ? [`auth.${this.options.auth.token}`, ...(Array.isArray(this.options.protocols) ? this.options.protocols : [this.options.protocols])]
        : this.options.protocols;

      this.ws = new this.options.WebSocketClass(this.url, protocols);
      if ('binaryType' in this.ws) {
        (this.ws as WebSocket).binaryType = this.options.binaryType;
      }
    } catch (err) {
      this.handleDisconnect(1006, 'Connection creation failed');
      return;
    }

    this.ws.onopen = () => {
      this.attempt = 0;
      this.setState('connected');
      this.startHeartbeat();
      this.flushQueue();
      this.emit('open', {});
    };

    this.ws.onmessage = (event: MessageEvent) => {
      this.handleMessage(event.data);
    };

    this.ws.onclose = (event: CloseEvent) => {
      this.emit('close', { code: event.code, reason: event.reason });
      this.handleDisconnect(event.code, event.reason);
    };

    this.ws.onerror = () => {
      // onclose fires after onerror, so we handle reconnection there
      this.emit('error', {});
    };
  }

  private handleMessage(raw: string | ArrayBuffer | Blob): void {
    if (typeof raw !== 'string') return; // handle binary separately if needed

    let msg: WSEvent;
    try {
      msg = JSON.parse(raw);
    } catch {
      this.emit('raw', raw);
      return;
    }

    // Handle heartbeat response
    if (msg.type === 'pong') {
      this.clearHeartbeatTimeout();
      return;
    }

    // Handle pending request/response correlation
    if (msg.id && this.pendingRequests.has(msg.id)) {
      const pending = this.pendingRequests.get(msg.id)!;
      this.pendingRequests.delete(msg.id);
      clearTimeout(pending.timer);

      if (msg.type === 'error') {
        pending.reject(new Error(String(msg.payload || msg.error || 'Request failed')));
      } else {
        pending.resolve(msg.payload ?? msg);
      }
      return;
    }

    // Emit typed event
    this.emit(msg.type, msg.payload ?? msg);

    // Emit to wildcard handlers
    this.anyHandlers.forEach((handler) => handler(msg));
  }

  private handleDisconnect(code: number, reason: string): void {
    this.stopHeartbeat();

    if (this.state === 'closed') return;

    // Normal close or max retries exceeded
    if (code === 1000 || this.attempt >= this.options.maxRetries) {
      this.setState('disconnected');
      if (this.attempt >= this.options.maxRetries) {
        this.emit('maxRetriesReached', { attempts: this.attempt });
      }
      return;
    }

    // Schedule reconnection
    this.setState('reconnecting');
    const delay = this.calculateDelay();
    this.emit('reconnecting', { attempt: this.attempt + 1, delay });

    this.reconnectTimer = setTimeout(() => {
      this.attempt++;
      this.connect();
    }, delay);
  }

  private calculateDelay(): number {
    const { baseDelay, maxDelay } = this.options;
    const exponential = Math.min(baseDelay * Math.pow(2, this.attempt), maxDelay);
    const jitter = exponential * (0.5 + Math.random() * 0.5);
    return Math.floor(jitter);
  }

  private flushQueue(): void {
    while (this.queue.length > 0 && this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(this.queue.shift()!);
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
        this.setHeartbeatTimeout();
      }
    }, this.options.heartbeatInterval);
  }

  private setHeartbeatTimeout(): void {
    this.clearHeartbeatTimeout();
    this.heartbeatTimeoutTimer = setTimeout(() => {
      console.warn('Heartbeat timeout — closing connection');
      this.ws?.close(4000, 'Heartbeat timeout');
    }, this.options.heartbeatTimeout);
  }

  private clearHeartbeatTimeout(): void {
    if (this.heartbeatTimeoutTimer) {
      clearTimeout(this.heartbeatTimeoutTimer);
      this.heartbeatTimeoutTimer = null;
    }
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.clearHeartbeatTimeout();
  }

  private cleanup(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private setState(newState: WSState): void {
    const prevState = this.state;
    if (prevState === newState) return;
    this.state = newState;
    this.stateHandlers.forEach((handler) => handler(newState, prevState));
  }

  private emit(event: string, data: unknown): void {
    this.handlers.get(event)?.forEach((handler) => handler(data));
  }

  private rejectAllPending(message: string): void {
    this.pendingRequests.forEach((pending) => {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
    });
    this.pendingRequests.clear();
  }

  private generateId(): string {
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  }
}

export { RobustWebSocket, type WSClientOptions, type WSEvent, type WSState };
