/**
 * signaling-server.js — Complete WebSocket signaling server with room management
 *
 * A production-ready signaling server for WebRTC applications supporting:
 *   - Room-based peer management (create, join, leave)
 *   - SDP offer/answer relay
 *   - ICE candidate forwarding
 *   - Heartbeat-based connection health
 *   - Graceful disconnect handling
 *   - Optional JWT authentication
 *
 * Usage:
 *   node signaling-server.js
 *
 * Environment variables:
 *   PORT          — Server port (default: 8080)
 *   AUTH_SECRET   — JWT secret for authentication (optional, disables auth if unset)
 *   MAX_ROOMS     — Maximum concurrent rooms (default: 1000)
 *   MAX_PEERS     — Maximum peers per room (default: 50)
 *   LOG_LEVEL     — Logging level: debug | info | warn | error (default: info)
 *
 * Client protocol (JSON over WebSocket):
 *   → { type: 'join', roomId: 'room1', displayName: 'Alice' }
 *   ← { type: 'room-joined', roomId, peerId, peers: [...] }
 *   ← { type: 'peer-joined', peerId, displayName }
 *
 *   → { type: 'offer', targetPeerId, sdp }
 *   → { type: 'answer', targetPeerId, sdp }
 *   → { type: 'candidate', targetPeerId, candidate }
 *   ← (same, with peerId of sender)
 *
 *   → { type: 'leave' }
 *   ← { type: 'peer-left', peerId }
 */

'use strict';

const http = require('http');
const { WebSocketServer } = require('ws');
const crypto = require('crypto');

// --- Configuration ---
const PORT = parseInt(process.env.PORT) || 8080;
const AUTH_SECRET = process.env.AUTH_SECRET || null;
const MAX_ROOMS = parseInt(process.env.MAX_ROOMS) || 1000;
const MAX_PEERS = parseInt(process.env.MAX_PEERS) || 50;
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';

const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };

function log(level, ...args) {
  if (LOG_LEVELS[level] >= LOG_LEVELS[LOG_LEVEL]) {
    console.log(`[${new Date().toISOString()}] [${level.toUpperCase()}]`, ...args);
  }
}

// --- Room Management ---
class RoomManager {
  constructor() {
    this.rooms = new Map();
  }

  getOrCreate(roomId) {
    if (!this.rooms.has(roomId)) {
      if (this.rooms.size >= MAX_ROOMS) {
        throw new Error('Maximum number of rooms reached');
      }
      this.rooms.set(roomId, new Map());
      log('info', `Room created: ${roomId}`);
    }
    return this.rooms.get(roomId);
  }

  join(roomId, peerId, ws, displayName) {
    const room = this.getOrCreate(roomId);
    if (room.size >= MAX_PEERS) {
      throw new Error('Room is full');
    }
    room.set(peerId, { ws, displayName, joinedAt: Date.now() });
    log('info', `Peer ${peerId} (${displayName}) joined room ${roomId} (${room.size} peers)`);
    return room;
  }

  leave(roomId, peerId) {
    const room = this.rooms.get(roomId);
    if (!room) return null;

    room.delete(peerId);
    log('info', `Peer ${peerId} left room ${roomId} (${room.size} peers)`);

    if (room.size === 0) {
      this.rooms.delete(roomId);
      log('info', `Room destroyed: ${roomId}`);
    }

    return room;
  }

  broadcast(roomId, message, excludePeerId = null) {
    const room = this.rooms.get(roomId);
    if (!room) return;

    const data = JSON.stringify(message);
    for (const [id, peer] of room) {
      if (id !== excludePeerId && peer.ws.readyState === 1) {
        peer.ws.send(data);
      }
    }
  }

  sendTo(roomId, targetPeerId, message) {
    const room = this.rooms.get(roomId);
    if (!room) return false;

    const peer = room.get(targetPeerId);
    if (peer && peer.ws.readyState === 1) {
      peer.ws.send(JSON.stringify(message));
      return true;
    }
    return false;
  }

  getPeerList(roomId, excludePeerId = null) {
    const room = this.rooms.get(roomId);
    if (!room) return [];

    return [...room.entries()]
      .filter(([id]) => id !== excludePeerId)
      .map(([id, peer]) => ({ peerId: id, displayName: peer.displayName }));
  }

  getStats() {
    let totalPeers = 0;
    for (const room of this.rooms.values()) {
      totalPeers += room.size;
    }
    return { rooms: this.rooms.size, peers: totalPeers };
  }
}

// --- Server Setup ---
const roomManager = new RoomManager();

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    const stats = roomManager.getStats();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      uptime: process.uptime(),
      ...stats
    }));
    return;
  }

  if (req.url === '/rooms') {
    const rooms = [...roomManager.rooms.entries()].map(([id, room]) => ({
      roomId: id,
      peers: room.size
    }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(rooms));
    return;
  }

  res.writeHead(404);
  res.end('Not Found');
});

const wss = new WebSocketServer({ server });

function generatePeerId() {
  return crypto.randomBytes(8).toString('hex');
}

function verifyToken(token) {
  if (!AUTH_SECRET) return { valid: true };

  try {
    // Simple HMAC-based token verification
    // For production, use a proper JWT library
    const [payload, sig] = token.split('.');
    const expected = crypto.createHmac('sha256', AUTH_SECRET)
      .update(payload).digest('base64url');
    if (sig !== expected) return { valid: false };

    return { valid: true, data: JSON.parse(Buffer.from(payload, 'base64url').toString()) };
  } catch {
    return { valid: false };
  }
}

wss.on('connection', (ws, req) => {
  // --- Authentication ---
  if (AUTH_SECRET) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const token = url.searchParams.get('token');

    if (!token || !verifyToken(token).valid) {
      ws.close(4003, 'Authentication failed');
      return;
    }
  }

  const peerId = generatePeerId();
  ws.peerId = peerId;
  ws.roomId = null;
  ws.isAlive = true;
  ws.displayName = null;

  log('debug', `WebSocket connected: ${peerId}`);

  ws.send(JSON.stringify({ type: 'welcome', peerId }));

  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (data) => {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
      return;
    }

    handleMessage(ws, msg);
  });

  ws.on('close', () => handleDisconnect(ws));
  ws.on('error', (err) => log('warn', `WebSocket error (${peerId}): ${err.message}`));
});

function handleMessage(ws, msg) {
  log('debug', `Message from ${ws.peerId}: ${msg.type}`);

  switch (msg.type) {
    case 'join': {
      if (ws.roomId) {
        // Leave current room first
        handleLeave(ws);
      }

      const roomId = msg.roomId?.toString().slice(0, 64);
      const displayName = msg.displayName?.toString().slice(0, 50) || `Peer-${ws.peerId.slice(0, 4)}`;

      if (!roomId) {
        ws.send(JSON.stringify({ type: 'error', message: 'roomId is required' }));
        return;
      }

      try {
        roomManager.join(roomId, ws.peerId, ws, displayName);
        ws.roomId = roomId;
        ws.displayName = displayName;

        const peers = roomManager.getPeerList(roomId, ws.peerId);

        ws.send(JSON.stringify({
          type: 'room-joined',
          roomId,
          peerId: ws.peerId,
          peers
        }));

        roomManager.broadcast(roomId, {
          type: 'peer-joined',
          peerId: ws.peerId,
          displayName
        }, ws.peerId);
      } catch (err) {
        ws.send(JSON.stringify({ type: 'error', message: err.message }));
      }
      break;
    }

    case 'leave':
      handleLeave(ws);
      break;

    case 'offer':
    case 'answer':
    case 'candidate': {
      if (!ws.roomId) {
        ws.send(JSON.stringify({ type: 'error', message: 'Not in a room' }));
        return;
      }

      const targetPeerId = msg.targetPeerId;
      if (!targetPeerId) {
        ws.send(JSON.stringify({ type: 'error', message: 'targetPeerId is required' }));
        return;
      }

      const forwarded = roomManager.sendTo(ws.roomId, targetPeerId, {
        type: msg.type,
        peerId: ws.peerId,
        sdp: msg.sdp,
        candidate: msg.candidate
      });

      if (!forwarded) {
        ws.send(JSON.stringify({ type: 'error', message: `Peer ${targetPeerId} not found` }));
      }
      break;
    }

    default:
      ws.send(JSON.stringify({ type: 'error', message: `Unknown message type: ${msg.type}` }));
  }
}

function handleLeave(ws) {
  if (!ws.roomId) return;

  const roomId = ws.roomId;
  roomManager.leave(roomId, ws.peerId);

  roomManager.broadcast(roomId, {
    type: 'peer-left',
    peerId: ws.peerId
  });

  ws.roomId = null;
  ws.send(JSON.stringify({ type: 'left', roomId }));
}

function handleDisconnect(ws) {
  if (ws.roomId) {
    const roomId = ws.roomId;
    roomManager.leave(roomId, ws.peerId);

    roomManager.broadcast(roomId, {
      type: 'peer-left',
      peerId: ws.peerId
    });
  }
  log('debug', `WebSocket disconnected: ${ws.peerId}`);
}

// --- Heartbeat ---
const heartbeatInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      log('debug', `Terminating unresponsive peer: ${ws.peerId}`);
      handleDisconnect(ws);
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(heartbeatInterval));

// --- Graceful Shutdown ---
function shutdown() {
  log('info', 'Shutting down...');

  for (const ws of wss.clients) {
    ws.send(JSON.stringify({ type: 'server-shutdown' }));
    ws.close(1001, 'Server shutting down');
  }

  wss.close(() => {
    server.close(() => {
      log('info', 'Server stopped');
      process.exit(0);
    });
  });

  setTimeout(() => process.exit(1), 5000);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// --- Start ---
server.listen(PORT, () => {
  log('info', `Signaling server listening on port ${PORT}`);
  log('info', `Auth: ${AUTH_SECRET ? 'enabled' : 'disabled'}`);
  log('info', `Max rooms: ${MAX_ROOMS}, Max peers/room: ${MAX_PEERS}`);
  log('info', `Health check: http://localhost:${PORT}/health`);
});
