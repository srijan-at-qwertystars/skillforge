// Durable Object template with WebSocket handling, state management,
// alarm scheduling, and hibernation API.
//
// Features:
//   - WebSocket rooms with hibernation (cost-efficient)
//   - Tag-based user tracking that survives hibernation
//   - Persistent state with blockConcurrencyWhile
//   - Alarm-based periodic cleanup
//   - Request routing by method + pathname
//
// wrangler.toml:
//   [[durable_objects.bindings]]
//   name = "ROOM"
//   class_name = "RoomObject"
//
//   [[migrations]]
//   tag = "v1"
//   new_classes = ["RoomObject"]

interface Env {
  ROOM: DurableObjectNamespace;
}

interface RoomState {
  name: string;
  createdAt: string;
  messageCount: number;
}

interface ChatMessage {
  type: "message" | "join" | "leave" | "system" | "state";
  user?: string;
  text?: string;
  users?: string[];
  timestamp: number;
}

// --- Durable Object ---
export class RoomObject extends DurableObject {
  private state: RoomState | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);

    // Load state once on first request — blocks until complete
    ctx.blockConcurrencyWhile(async () => {
      this.state = await ctx.storage.get<RoomState>("roomState") ?? null;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    switch (`${request.method} ${url.pathname}`) {
      case "GET /websocket":
        return this.handleWebSocketUpgrade(request);
      case "POST /init":
        return this.handleInit(request);
      case "GET /state":
        return this.handleGetState();
      case "POST /broadcast":
        return this.handleBroadcast(request);
      case "POST /alarm":
        return this.handleScheduleAlarm(request);
      case "DELETE /":
        return this.handleDelete();
      default:
        return Response.json({ error: "Not found" }, { status: 404 });
    }
  }

  // --- WebSocket Handling (with Hibernation) ---

  private handleWebSocketUpgrade(request: Request): Response {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    const url = new URL(request.url);
    const username = url.searchParams.get("user");
    if (!username) {
      return Response.json({ error: "?user= parameter required" }, { status: 400 });
    }

    const pair = new WebSocketPair();
    const [client, server] = pair;

    // Accept with tags — tags survive hibernation and identify the socket
    this.ctx.acceptWebSocket(server, [username]);

    // Notify room of new user
    this.broadcast({
      type: "join",
      user: username,
      users: this.getConnectedUsers(),
      timestamp: Date.now(),
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  // Called when a WebSocket message is received (even after hibernation wake-up)
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const username = this.ctx.getTags(ws)[0];
    const text = typeof message === "string" ? message : new TextDecoder().decode(message);

    // Update message count
    if (this.state) {
      this.state.messageCount++;
      await this.ctx.storage.put("roomState", this.state);
    }

    // Broadcast to all connected clients
    this.broadcast({
      type: "message",
      user: username,
      text,
      timestamp: Date.now(),
    });
  }

  // Called when a WebSocket connection closes
  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    const username = this.ctx.getTags(ws)[0];
    ws.close(code, reason);

    this.broadcast({
      type: "leave",
      user: username,
      users: this.getConnectedUsers(),
      timestamp: Date.now(),
    });

    // If no more connections, schedule cleanup alarm
    if (this.ctx.getWebSockets().length === 0) {
      await this.ctx.storage.setAlarm(Date.now() + 24 * 60 * 60 * 1000); // 24h
    }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const username = this.ctx.getTags(ws)[0];
    console.error(`WebSocket error for ${username}:`, error);
    ws.close(1011, "Internal error");
  }

  // --- Alarms ---

  async alarm(): Promise<void> {
    const sockets = this.ctx.getWebSockets();

    if (sockets.length === 0) {
      // No active connections — clean up old state
      console.log("Room idle — cleaning up old messages");
      await this.ctx.storage.delete("messages");
    } else {
      // Room still active — reschedule
      await this.ctx.storage.setAlarm(Date.now() + 24 * 60 * 60 * 1000);
    }
  }

  // --- HTTP Handlers ---

  private async handleInit(request: Request): Promise<Response> {
    const { name } = await request.json<{ name: string }>();

    this.state = {
      name,
      createdAt: new Date().toISOString(),
      messageCount: 0,
    };
    await this.ctx.storage.put("roomState", this.state);

    return Response.json({ success: true, state: this.state });
  }

  private handleGetState(): Response {
    if (!this.state) {
      return Response.json({ error: "Room not initialized" }, { status: 404 });
    }

    return Response.json({
      ...this.state,
      connectedUsers: this.getConnectedUsers(),
      connectionCount: this.ctx.getWebSockets().length,
    });
  }

  private async handleBroadcast(request: Request): Promise<Response> {
    const { text } = await request.json<{ text: string }>();

    this.broadcast({
      type: "system",
      text,
      timestamp: Date.now(),
    });

    return Response.json({ success: true, recipients: this.ctx.getWebSockets().length });
  }

  private async handleScheduleAlarm(request: Request): Promise<Response> {
    const { delayMs } = await request.json<{ delayMs: number }>();
    await this.ctx.storage.setAlarm(Date.now() + delayMs);
    return Response.json({ scheduled: true, firesAt: new Date(Date.now() + delayMs).toISOString() });
  }

  private async handleDelete(): Promise<Response> {
    // Close all WebSocket connections
    for (const ws of this.ctx.getWebSockets()) {
      ws.close(1001, "Room deleted");
    }
    // Clear all storage
    await this.ctx.storage.deleteAll();
    this.state = null;
    return Response.json({ deleted: true });
  }

  // --- Helpers ---

  private getConnectedUsers(): string[] {
    return this.ctx.getWebSockets().map(ws => this.ctx.getTags(ws)[0]);
  }

  private broadcast(message: ChatMessage, exclude?: WebSocket): void {
    const payload = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws !== exclude) {
        try {
          ws.send(payload);
        } catch {
          // Socket already closed — will be cleaned up by webSocketClose
        }
      }
    }
  }
}

// --- Worker entry point (routes to Durable Object) ---
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const roomId = url.searchParams.get("room") ?? url.pathname.split("/")[2];

    if (!roomId) {
      return Response.json({ error: "Room ID required (?room=<id> or /rooms/<id>)" }, { status: 400 });
    }

    const id = env.ROOM.idFromName(roomId);
    const stub = env.ROOM.get(id);

    // Forward request to the Durable Object
    const doUrl = new URL(request.url);
    doUrl.hostname = "do";
    // Strip /rooms/<id> prefix for DO routing
    doUrl.pathname = doUrl.pathname.replace(/^\/rooms\/[^/]+/, "") || "/";

    return stub.fetch(new Request(doUrl, request));
  },
};
