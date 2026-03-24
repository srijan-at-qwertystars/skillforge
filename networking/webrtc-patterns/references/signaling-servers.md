# WebRTC Signaling Servers

## Table of Contents

- [Overview](#overview)
- [WebSocket Signaling Implementation](#websocket-signaling-implementation)
- [Socket.IO Patterns](#socketio-patterns)
- [HTTP Polling Fallback](#http-polling-fallback)
- [Room Management](#room-management)
- [SFU Signaling Protocols](#sfu-signaling-protocols)
- [Scaling Signaling Servers](#scaling-signaling-servers)
- [Security Considerations](#security-considerations)
- [Production Deployment](#production-deployment)

---

## Overview

WebRTC does not define a signaling protocol. You must implement one to exchange:

1. **SDP offers/answers** — Session descriptions containing codec, media, and transport info
2. **ICE candidates** — Network connectivity candidates (host, srflx, relay)
3. **Application messages** — Room join/leave, mute/unmute, metadata

Common transport choices:

| Transport | Latency | Complexity | Firewall-Friendly | Best For |
|-----------|---------|------------|-------------------|----------|
| WebSocket | Low | Medium | Yes (port 443) | Most apps |
| Socket.IO | Low | Low | Yes | Rapid prototyping |
| HTTP polling | High | Low | Yes | Constrained environments |
| SSE + POST | Medium | Medium | Yes | One-way updates + commands |
| gRPC | Low | High | Depends | Server-to-server |

---

## WebSocket Signaling Implementation

### Basic WebSocket Server (Node.js)

```javascript
const { WebSocketServer } = require('ws');
const http = require('http');

const server = http.createServer();
const wss = new WebSocketServer({ server });

const rooms = new Map();  // roomId → Map<peerId, ws>

wss.on('connection', (ws, req) => {
  const peerId = generateId();
  ws.peerId = peerId;
  ws.isAlive = true;

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
  ws.on('error', (err) => console.error(`Peer ${peerId} error:`, err.message));

  ws.send(JSON.stringify({ type: 'welcome', peerId }));
});

function handleMessage(ws, msg) {
  switch (msg.type) {
    case 'join':
      joinRoom(ws, msg.roomId);
      break;
    case 'leave':
      leaveRoom(ws);
      break;
    case 'offer':
    case 'answer':
    case 'candidate':
      forwardToPeer(ws, msg);
      break;
    default:
      ws.send(JSON.stringify({ type: 'error', message: `Unknown type: ${msg.type}` }));
  }
}

function joinRoom(ws, roomId) {
  if (!rooms.has(roomId)) {
    rooms.set(roomId, new Map());
  }

  const room = rooms.get(roomId);

  // Notify existing peers
  const existingPeers = [];
  for (const [id, peer] of room) {
    existingPeers.push(id);
    peer.send(JSON.stringify({
      type: 'peer-joined',
      peerId: ws.peerId
    }));
  }

  room.set(ws.peerId, ws);
  ws.roomId = roomId;

  ws.send(JSON.stringify({
    type: 'room-joined',
    roomId,
    peers: existingPeers
  }));
}

function leaveRoom(ws) {
  const roomId = ws.roomId;
  if (!roomId || !rooms.has(roomId)) return;

  const room = rooms.get(roomId);
  room.delete(ws.peerId);

  for (const [, peer] of room) {
    peer.send(JSON.stringify({
      type: 'peer-left',
      peerId: ws.peerId
    }));
  }

  if (room.size === 0) rooms.delete(roomId);
  ws.roomId = null;
}

function forwardToPeer(ws, msg) {
  const roomId = ws.roomId;
  if (!roomId || !rooms.has(roomId)) return;

  const room = rooms.get(roomId);
  const target = room.get(msg.targetPeerId);

  if (target && target.readyState === 1) {
    target.send(JSON.stringify({
      type: msg.type,
      peerId: ws.peerId,
      sdp: msg.sdp,
      candidate: msg.candidate
    }));
  }
}

function handleDisconnect(ws) {
  leaveRoom(ws);
}

function generateId() {
  return Math.random().toString(36).substring(2, 10);
}

// Heartbeat to detect dead connections
const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      handleDisconnect(ws);
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(heartbeat));

server.listen(8080, () => console.log('Signaling server on :8080'));
```

### Client-Side WebSocket Signaling

```javascript
class SignalingClient {
  constructor(url) {
    this.url = url;
    this.ws = null;
    this.peerId = null;
    this.handlers = new Map();
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 10;
    this.pendingMessages = [];
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);

      this.ws.onopen = () => {
        this.reconnectAttempts = 0;
        this.flushPending();
      };

      this.ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'welcome') {
          this.peerId = msg.peerId;
          resolve(msg.peerId);
        }
        const handler = this.handlers.get(msg.type);
        if (handler) handler(msg);
      };

      this.ws.onclose = () => {
        this.scheduleReconnect();
      };

      this.ws.onerror = (err) => {
        if (this.reconnectAttempts === 0) reject(err);
      };
    });
  }

  on(type, handler) {
    this.handlers.set(type, handler);
  }

  send(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    } else {
      this.pendingMessages.push(msg);
    }
  }

  flushPending() {
    while (this.pendingMessages.length > 0) {
      this.send(this.pendingMessages.shift());
    }
  }

  scheduleReconnect() {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      this.handlers.get('fatal-error')?.({ message: 'Max reconnect attempts reached' });
      return;
    }

    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
    this.reconnectAttempts++;

    setTimeout(() => {
      this.connect().catch(() => {});
    }, delay);
  }

  joinRoom(roomId) {
    this.send({ type: 'join', roomId });
  }

  sendOffer(targetPeerId, sdp) {
    this.send({ type: 'offer', targetPeerId, sdp });
  }

  sendAnswer(targetPeerId, sdp) {
    this.send({ type: 'answer', targetPeerId, sdp });
  }

  sendCandidate(targetPeerId, candidate) {
    this.send({ type: 'candidate', targetPeerId, candidate });
  }

  close() {
    this.maxReconnectAttempts = 0;
    this.ws?.close();
  }
}
```

### WebSocket with Binary Protocol (MessagePack)

For lower overhead signaling, use a binary format:

```javascript
const msgpack = require('@msgpack/msgpack');

// Encode
ws.send(msgpack.encode({ type: 'offer', sdp: offerSDP }));

// Decode
ws.on('message', (data) => {
  const msg = msgpack.decode(data);
  handleMessage(ws, msg);
});
```

---

## Socket.IO Patterns

### Socket.IO Signaling Server

```javascript
const { Server } = require('socket.io');
const http = require('http');

const httpServer = http.createServer();
const io = new Server(httpServer, {
  cors: { origin: '*', methods: ['GET', 'POST'] },
  pingInterval: 25000,
  pingTimeout: 10000
});

io.on('connection', (socket) => {
  console.log(`Connected: ${socket.id}`);

  socket.on('join-room', (roomId, callback) => {
    const room = io.sockets.adapter.rooms.get(roomId);
    const numClients = room ? room.size : 0;

    if (numClients >= 50) {
      callback({ error: 'Room is full' });
      return;
    }

    socket.join(roomId);
    socket.roomId = roomId;

    // Notify others
    socket.to(roomId).emit('peer-joined', { peerId: socket.id });

    // Send existing peers to the new participant
    const peers = room ? [...room].filter(id => id !== socket.id) : [];
    callback({ peers, roomId });
  });

  socket.on('offer', ({ targetPeerId, sdp }) => {
    io.to(targetPeerId).emit('offer', {
      peerId: socket.id,
      sdp
    });
  });

  socket.on('answer', ({ targetPeerId, sdp }) => {
    io.to(targetPeerId).emit('answer', {
      peerId: socket.id,
      sdp
    });
  });

  socket.on('candidate', ({ targetPeerId, candidate }) => {
    io.to(targetPeerId).emit('candidate', {
      peerId: socket.id,
      candidate
    });
  });

  socket.on('disconnect', () => {
    if (socket.roomId) {
      socket.to(socket.roomId).emit('peer-left', { peerId: socket.id });
    }
  });
});

httpServer.listen(3000, () => console.log('Socket.IO signaling on :3000'));
```

### Socket.IO Client Integration

```javascript
import { io } from 'socket.io-client';

class SocketIOSignaling {
  constructor(url) {
    this.socket = io(url, {
      reconnection: true,
      reconnectionDelay: 1000,
      reconnectionDelayMax: 30000,
      reconnectionAttempts: 10,
      transports: ['websocket', 'polling']  // prefer WS, fall back to polling
    });

    this.peerConnections = new Map();
  }

  joinRoom(roomId) {
    return new Promise((resolve, reject) => {
      this.socket.emit('join-room', roomId, (response) => {
        if (response.error) {
          reject(new Error(response.error));
          return;
        }
        // Create peer connections to existing peers
        for (const peerId of response.peers) {
          this.createPeerConnection(peerId, true);
        }
        resolve(response);
      });
    });
  }

  createPeerConnection(peerId, isInitiator) {
    const pc = new RTCPeerConnection(rtcConfig);
    this.peerConnections.set(peerId, pc);

    pc.onicecandidate = ({ candidate }) => {
      if (candidate) {
        this.socket.emit('candidate', { targetPeerId: peerId, candidate });
      }
    };

    pc.ontrack = (event) => {
      this.onRemoteTrack?.(peerId, event);
    };

    if (isInitiator) {
      this.initiateCall(peerId, pc);
    }

    return pc;
  }

  async initiateCall(peerId, pc) {
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    this.socket.emit('offer', { targetPeerId: peerId, sdp: offer });
  }

  setupListeners() {
    this.socket.on('peer-joined', ({ peerId }) => {
      this.createPeerConnection(peerId, true);
    });

    this.socket.on('offer', async ({ peerId, sdp }) => {
      let pc = this.peerConnections.get(peerId);
      if (!pc) pc = this.createPeerConnection(peerId, false);

      await pc.setRemoteDescription(new RTCSessionDescription(sdp));
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      this.socket.emit('answer', { targetPeerId: peerId, sdp: answer });
    });

    this.socket.on('answer', async ({ peerId, sdp }) => {
      const pc = this.peerConnections.get(peerId);
      if (pc) await pc.setRemoteDescription(new RTCSessionDescription(sdp));
    });

    this.socket.on('candidate', async ({ peerId, candidate }) => {
      const pc = this.peerConnections.get(peerId);
      if (pc) await pc.addIceCandidate(new RTCIceCandidate(candidate));
    });

    this.socket.on('peer-left', ({ peerId }) => {
      const pc = this.peerConnections.get(peerId);
      if (pc) {
        pc.close();
        this.peerConnections.delete(peerId);
        this.onPeerLeft?.(peerId);
      }
    });
  }
}
```

### Socket.IO Namespace Isolation

```javascript
// Separate namespaces for different concerns
const signalingNs = io.of('/signaling');
const chatNs = io.of('/chat');
const presenceNs = io.of('/presence');

signalingNs.on('connection', (socket) => {
  // WebRTC signaling only
  socket.on('offer', handleOffer);
  socket.on('answer', handleAnswer);
  socket.on('candidate', handleCandidate);
});

chatNs.on('connection', (socket) => {
  // Text chat alongside video
  socket.on('chat-message', (msg) => {
    socket.to(msg.roomId).emit('chat-message', {
      from: socket.id,
      text: msg.text,
      timestamp: Date.now()
    });
  });
});
```

---

## HTTP Polling Fallback

For environments where WebSocket is unavailable (restrictive proxies, older infrastructure):

### Long-Polling Server

```javascript
const express = require('express');
const app = express();
app.use(express.json());

const messageQueues = new Map();  // peerId → messages[]
const peers = new Map();          // peerId → { roomId, lastSeen }

app.post('/register', (req, res) => {
  const peerId = generateId();
  messageQueues.set(peerId, []);
  peers.set(peerId, { roomId: null, lastSeen: Date.now() });
  res.json({ peerId });
});

app.post('/join', (req, res) => {
  const { peerId, roomId } = req.body;
  const peer = peers.get(peerId);
  if (!peer) return res.status(404).json({ error: 'Unknown peer' });

  peer.roomId = roomId;
  peer.lastSeen = Date.now();

  // Notify others in room
  const roomPeers = getRoomPeers(roomId, peerId);
  for (const rp of roomPeers) {
    enqueue(rp, { type: 'peer-joined', peerId });
  }

  res.json({ peers: roomPeers });
});

app.post('/signal', (req, res) => {
  const { peerId, targetPeerId, type, sdp, candidate } = req.body;
  const peer = peers.get(peerId);
  if (!peer) return res.status(404).json({ error: 'Unknown peer' });

  peer.lastSeen = Date.now();
  enqueue(targetPeerId, { type, peerId, sdp, candidate });
  res.json({ ok: true });
});

// Long-polling endpoint
app.get('/poll/:peerId', (req, res) => {
  const { peerId } = req.params;
  const queue = messageQueues.get(peerId);
  if (!queue) return res.status(404).json({ error: 'Unknown peer' });

  const peer = peers.get(peerId);
  if (peer) peer.lastSeen = Date.now();

  if (queue.length > 0) {
    const messages = queue.splice(0);
    return res.json({ messages });
  }

  // Hold connection open for up to 30 seconds
  const timeout = setTimeout(() => {
    res.json({ messages: [] });
  }, 30000);

  const checkInterval = setInterval(() => {
    if (queue.length > 0) {
      clearTimeout(timeout);
      clearInterval(checkInterval);
      const messages = queue.splice(0);
      res.json({ messages });
    }
  }, 100);

  req.on('close', () => {
    clearTimeout(timeout);
    clearInterval(checkInterval);
  });
});

function enqueue(peerId, message) {
  const queue = messageQueues.get(peerId);
  if (queue) queue.push(message);
}

function getRoomPeers(roomId, excludePeerId) {
  return [...peers.entries()]
    .filter(([id, p]) => p.roomId === roomId && id !== excludePeerId)
    .map(([id]) => id);
}

// Cleanup stale peers
setInterval(() => {
  const staleThreshold = Date.now() - 60000;
  for (const [id, peer] of peers) {
    if (peer.lastSeen < staleThreshold) {
      if (peer.roomId) {
        const roomPeers = getRoomPeers(peer.roomId, id);
        for (const rp of roomPeers) {
          enqueue(rp, { type: 'peer-left', peerId: id });
        }
      }
      peers.delete(id);
      messageQueues.delete(id);
    }
  }
}, 15000);

app.listen(3001, () => console.log('Polling signaling on :3001'));
```

### Polling Client

```javascript
class PollingSignalingClient {
  constructor(baseUrl) {
    this.baseUrl = baseUrl;
    this.peerId = null;
    this.polling = false;
    this.handlers = new Map();
  }

  async register() {
    const res = await fetch(`${this.baseUrl}/register`, { method: 'POST' });
    const { peerId } = await res.json();
    this.peerId = peerId;
    return peerId;
  }

  async joinRoom(roomId) {
    const res = await fetch(`${this.baseUrl}/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ peerId: this.peerId, roomId })
    });
    const data = await res.json();
    this.startPolling();
    return data;
  }

  async signal(targetPeerId, type, payload) {
    await fetch(`${this.baseUrl}/signal`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        peerId: this.peerId,
        targetPeerId,
        type,
        ...payload
      })
    });
  }

  async startPolling() {
    this.polling = true;
    while (this.polling) {
      try {
        const res = await fetch(`${this.baseUrl}/poll/${this.peerId}`);
        const { messages } = await res.json();
        for (const msg of messages) {
          const handler = this.handlers.get(msg.type);
          if (handler) handler(msg);
        }
      } catch (err) {
        console.warn('Poll failed, retrying...', err.message);
        await new Promise(r => setTimeout(r, 2000));
      }
    }
  }

  on(type, handler) {
    this.handlers.set(type, handler);
  }

  stop() {
    this.polling = false;
  }
}
```

---

## Room Management

### Advanced Room Management

```javascript
class RoomManager {
  constructor() {
    this.rooms = new Map();
  }

  createRoom(options = {}) {
    const roomId = options.roomId || generateId();
    const room = {
      id: roomId,
      peers: new Map(),
      createdAt: Date.now(),
      maxPeers: options.maxPeers || 50,
      locked: false,
      password: options.password || null,
      metadata: options.metadata || {},
      speakers: new Set(),   // for webinar mode
      mode: options.mode || 'conference'  // 'conference' | 'webinar' | 'broadcast'
    };
    this.rooms.set(roomId, room);
    return room;
  }

  joinRoom(roomId, peerId, ws, options = {}) {
    let room = this.rooms.get(roomId);
    if (!room) {
      room = this.createRoom({ roomId });
    }

    if (room.locked && !options.isAdmin) {
      throw new Error('Room is locked');
    }
    if (room.password && options.password !== room.password) {
      throw new Error('Invalid room password');
    }
    if (room.peers.size >= room.maxPeers) {
      throw new Error('Room is full');
    }

    const peer = {
      id: peerId,
      ws,
      joinedAt: Date.now(),
      role: room.peers.size === 0 ? 'host' : (options.role || 'participant'),
      displayName: options.displayName || `User-${peerId.substring(0, 4)}`,
      audio: true,
      video: true
    };

    room.peers.set(peerId, peer);
    return { room, peer };
  }

  leaveRoom(roomId, peerId) {
    const room = this.rooms.get(roomId);
    if (!room) return;

    room.peers.delete(peerId);
    room.speakers.delete(peerId);

    // Auto-promote new host if host left
    if (room.peers.size > 0 && ![...room.peers.values()].some(p => p.role === 'host')) {
      const oldest = [...room.peers.values()].sort((a, b) => a.joinedAt - b.joinedAt)[0];
      if (oldest) oldest.role = 'host';
    }

    // Clean up empty rooms
    if (room.peers.size === 0) {
      this.rooms.delete(roomId);
    }

    return room;
  }

  broadcastToRoom(roomId, message, excludePeerId = null) {
    const room = this.rooms.get(roomId);
    if (!room) return;

    const data = JSON.stringify(message);
    for (const [id, peer] of room.peers) {
      if (id !== excludePeerId && peer.ws.readyState === 1) {
        peer.ws.send(data);
      }
    }
  }

  getRoomInfo(roomId) {
    const room = this.rooms.get(roomId);
    if (!room) return null;

    return {
      id: room.id,
      peerCount: room.peers.size,
      maxPeers: room.maxPeers,
      locked: room.locked,
      mode: room.mode,
      createdAt: room.createdAt,
      peers: [...room.peers.values()].map(p => ({
        id: p.id,
        role: p.role,
        displayName: p.displayName
      }))
    };
  }

  listRooms() {
    return [...this.rooms.values()].map(room => ({
      id: room.id,
      peerCount: room.peers.size,
      maxPeers: room.maxPeers,
      mode: room.mode,
      locked: room.locked
    }));
  }
}
```

### Moderation Controls

```javascript
// Host-only actions
function handleModeration(ws, msg, roomManager) {
  const room = roomManager.rooms.get(ws.roomId);
  if (!room) return;

  const peer = room.peers.get(ws.peerId);
  if (peer?.role !== 'host') {
    ws.send(JSON.stringify({ type: 'error', message: 'Not authorized' }));
    return;
  }

  switch (msg.action) {
    case 'mute-peer':
      roomManager.broadcastToRoom(ws.roomId, {
        type: 'mute-request',
        targetPeerId: msg.targetPeerId,
        kind: msg.kind || 'audio'
      });
      break;

    case 'kick-peer':
      const targetPeer = room.peers.get(msg.targetPeerId);
      if (targetPeer) {
        targetPeer.ws.send(JSON.stringify({ type: 'kicked', reason: msg.reason }));
        targetPeer.ws.close();
        roomManager.leaveRoom(ws.roomId, msg.targetPeerId);
      }
      break;

    case 'lock-room':
      room.locked = true;
      roomManager.broadcastToRoom(ws.roomId, { type: 'room-locked' });
      break;

    case 'unlock-room':
      room.locked = false;
      roomManager.broadcastToRoom(ws.roomId, { type: 'room-unlocked' });
      break;

    case 'promote':
      const promotedPeer = room.peers.get(msg.targetPeerId);
      if (promotedPeer) {
        promotedPeer.role = msg.role || 'co-host';
        roomManager.broadcastToRoom(ws.roomId, {
          type: 'role-changed',
          peerId: msg.targetPeerId,
          role: promotedPeer.role
        });
      }
      break;
  }
}
```

---

## SFU Signaling Protocols

### mediasoup Signaling Protocol

mediasoup uses a request/response pattern over any transport:

```javascript
// Client → Server requests
const MEDIASOUP_REQUESTS = {
  // 1. Get router capabilities
  getRouterRtpCapabilities: {},

  // 2. Create transports
  createWebRtcTransport: { direction: 'send' | 'recv' },

  // 3. Connect transport (DTLS handshake)
  connectTransport: { transportId, dtlsParameters },

  // 4. Produce (send media)
  produce: { transportId, kind, rtpParameters, appData },

  // 5. Consume (receive media)
  consume: { producerId, rtpCapabilities },

  // 6. Resume consumer
  resumeConsumer: { consumerId }
};

// Server → Client notifications
const MEDIASOUP_NOTIFICATIONS = {
  newProducer: { producerId, kind, peerId },
  producerClosed: { producerId },
  consumerClosed: { consumerId },
  consumerPaused: { consumerId },
  consumerResumed: { consumerId },
  peerJoined: { peerId, displayName },
  peerLeft: { peerId }
};
```

### Janus Signaling Protocol

```javascript
// Janus uses a session + handle model
const JANUS_MESSAGE_FLOW = {
  // 1. Create session
  create: { janus: 'create' },
  // Response: { janus: 'success', data: { id: sessionId } }

  // 2. Attach to plugin
  attach: { janus: 'attach', session_id: sessionId, plugin: 'janus.plugin.videoroom' },
  // Response: { janus: 'success', data: { id: handleId } }

  // 3. Send plugin message
  message: {
    janus: 'message',
    session_id: sessionId,
    handle_id: handleId,
    body: { request: 'join', room: 1234, ptype: 'publisher' },
    jsep: { type: 'offer', sdp: '...' }  // optional
  },

  // 4. Trickle ICE candidate
  trickle: {
    janus: 'trickle',
    session_id: sessionId,
    handle_id: handleId,
    candidate: { /* ICE candidate */ }
  },

  // 5. Keep-alive (every 25s)
  keepalive: { janus: 'keepalive', session_id: sessionId }
};
```

### LiveKit Signaling

```javascript
// LiveKit uses protobuf over WebSocket
// Client SDK handles protocol details — typical usage:
import { Room, RoomEvent } from 'livekit-client';

const room = new Room();

room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
  const element = track.attach();
  document.getElementById('remote-video').appendChild(element);
});

room.on(RoomEvent.ParticipantDisconnected, (participant) => {
  console.log(`${participant.identity} left`);
});

await room.connect('wss://livekit.example.com', accessToken);

// Publish local tracks
const tracks = await room.localParticipant.enableCameraAndMicrophone();
```

---

## Scaling Signaling Servers

### Horizontal Scaling with Redis

```javascript
const { Server } = require('socket.io');
const { createAdapter } = require('@socket.io/redis-adapter');
const { createClient } = require('redis');

async function createScalableSignalingServer(httpServer) {
  const io = new Server(httpServer, {
    cors: { origin: '*' }
  });

  const pubClient = createClient({ url: 'redis://redis:6379' });
  const subClient = pubClient.duplicate();

  await Promise.all([pubClient.connect(), subClient.connect()]);

  io.adapter(createAdapter(pubClient, subClient));

  // Now multiple server instances share state via Redis
  // Rooms, broadcasts, and peer-to-peer messages work across instances

  return io;
}
```

### Sticky Sessions with Load Balancer

```nginx
# Nginx configuration for sticky sessions
upstream signaling_servers {
    ip_hash;  # sticky sessions based on client IP
    server signaling1:3000;
    server signaling2:3000;
    server signaling3:3000;
}

server {
    listen 443 ssl;
    server_name signal.example.com;

    location /socket.io/ {
        proxy_pass http://signaling_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400;
    }
}
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signaling-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app: signaling
  template:
    metadata:
      labels:
        app: signaling
    spec:
      containers:
      - name: signaling
        image: myapp/signaling:latest
        ports:
        - containerPort: 3000
        env:
        - name: REDIS_URL
          value: "redis://redis-service:6379"
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: signaling-service
spec:
  selector:
    app: signaling
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
```

### Connection Count Monitoring

```javascript
const prometheus = require('prom-client');

const connectedPeers = new prometheus.Gauge({
  name: 'signaling_connected_peers',
  help: 'Number of connected peers'
});

const activeRooms = new prometheus.Gauge({
  name: 'signaling_active_rooms',
  help: 'Number of active rooms'
});

const signalingMessages = new prometheus.Counter({
  name: 'signaling_messages_total',
  help: 'Total signaling messages processed',
  labelNames: ['type']
});

// Update metrics
io.on('connection', (socket) => {
  connectedPeers.inc();
  socket.on('disconnect', () => connectedPeers.dec());
  socket.onAny((eventName) => {
    signalingMessages.inc({ type: eventName });
  });
});

// Expose /metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prometheus.register.contentType);
  res.send(await prometheus.register.metrics());
});
```

---

## Security Considerations

### Authentication and Authorization

```javascript
const jwt = require('jsonwebtoken');

// Authenticate WebSocket connections
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const token = url.searchParams.get('token');

  if (!token) {
    ws.close(4001, 'Missing authentication token');
    return;
  }

  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    ws.userId = payload.userId;
    ws.permissions = payload.permissions;  // ['join', 'publish', 'subscribe']
  } catch (err) {
    ws.close(4003, 'Invalid token');
    return;
  }
});
```

### Rate Limiting

```javascript
const rateLimiters = new Map();

function rateLimit(peerId, maxMessages = 100, windowMs = 10000) {
  if (!rateLimiters.has(peerId)) {
    rateLimiters.set(peerId, { count: 0, resetAt: Date.now() + windowMs });
  }

  const limiter = rateLimiters.get(peerId);

  if (Date.now() > limiter.resetAt) {
    limiter.count = 0;
    limiter.resetAt = Date.now() + windowMs;
  }

  limiter.count++;

  if (limiter.count > maxMessages) {
    return false;  // rate limited
  }
  return true;
}

// In message handler
ws.on('message', (data) => {
  if (!rateLimit(ws.peerId)) {
    ws.send(JSON.stringify({ type: 'error', message: 'Rate limited' }));
    return;
  }
  // ... handle message
});
```

### Input Validation

```javascript
const Ajv = require('ajv');
const ajv = new Ajv();

const schemas = {
  offer: {
    type: 'object',
    required: ['type', 'targetPeerId', 'sdp'],
    properties: {
      type: { const: 'offer' },
      targetPeerId: { type: 'string', minLength: 1, maxLength: 64 },
      sdp: { type: 'object' }
    },
    additionalProperties: false
  },
  candidate: {
    type: 'object',
    required: ['type', 'targetPeerId', 'candidate'],
    properties: {
      type: { const: 'candidate' },
      targetPeerId: { type: 'string', minLength: 1, maxLength: 64 },
      candidate: { type: 'object' }
    },
    additionalProperties: false
  }
};

function validateMessage(msg) {
  const schema = schemas[msg.type];
  if (!schema) return false;
  return ajv.validate(schema, msg);
}
```

---

## Production Deployment

### Health Check Endpoint

```javascript
app.get('/health', (req, res) => {
  const health = {
    status: 'ok',
    uptime: process.uptime(),
    connections: wss.clients.size,
    rooms: rooms.size,
    memory: process.memoryUsage(),
    timestamp: Date.now()
  };
  res.json(health);
});
```

### Graceful Shutdown

```javascript
process.on('SIGTERM', async () => {
  console.log('Shutting down gracefully...');

  // Notify all peers
  for (const ws of wss.clients) {
    ws.send(JSON.stringify({ type: 'server-shutdown' }));
    ws.close(1001, 'Server shutting down');
  }

  // Close WebSocket server
  wss.close(() => {
    console.log('WebSocket server closed');
    server.close(() => {
      console.log('HTTP server closed');
      process.exit(0);
    });
  });

  // Force exit after timeout
  setTimeout(() => process.exit(1), 10000);
});
```

### Environment Configuration

```bash
# .env for signaling server
PORT=3000
REDIS_URL=redis://localhost:6379
JWT_SECRET=your-secret-key
MAX_ROOMS=1000
MAX_PEERS_PER_ROOM=50
CORS_ORIGIN=https://app.example.com
LOG_LEVEL=info
NODE_ENV=production

# TLS (for direct WebSocket TLS termination)
TLS_CERT=/etc/ssl/certs/signaling.crt
TLS_KEY=/etc/ssl/private/signaling.key
```
