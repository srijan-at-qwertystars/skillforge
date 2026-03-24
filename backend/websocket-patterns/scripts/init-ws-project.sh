#!/usr/bin/env bash
#
# init-ws-project.sh — Initialize a WebSocket project with server, client, and reconnection logic
#
# Usage:
#   ./init-ws-project.sh [project-name]
#
# Creates a new directory with:
#   - package.json with ws + express dependencies
#   - WebSocket server with rooms, broadcast, heartbeat
#   - Client HTML page with auto-reconnection
#   - Basic project structure
#
# Examples:
#   ./init-ws-project.sh my-ws-app
#   ./init-ws-project.sh                  # defaults to "ws-project"

set -euo pipefail

PROJECT_NAME="${1:-ws-project}"

if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating WebSocket project: $PROJECT_NAME"

# Create project structure
mkdir -p "$PROJECT_NAME"/{src,public}
cd "$PROJECT_NAME"

# Initialize package.json
cat > package.json << 'PACKAGE_EOF'
{
  "name": "ws-project",
  "version": "1.0.0",
  "description": "WebSocket server with rooms, broadcast, and reconnection",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js",
    "dev": "node --watch src/server.js"
  },
  "keywords": ["websocket", "realtime"],
  "license": "MIT"
}
PACKAGE_EOF

# Update project name in package.json
sed -i "s/\"ws-project\"/\"$PROJECT_NAME\"/" package.json

# Create WebSocket server
cat > src/server.js << 'SERVER_EOF'
const http = require('http');
const express = require('express');
const { WebSocketServer } = require('ws');
const path = require('path');
const crypto = require('crypto');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3000;

// Serve static files
app.use(express.static(path.join(__dirname, '..', 'public')));

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    connections: wss.clients.size,
    rooms: Object.fromEntries(
      [...rooms.entries()].map(([name, members]) => [name, members.size])
    ),
    uptime: process.uptime(),
  });
});

// Room management
const rooms = new Map();       // roomId -> Set<ws>
const clientInfo = new Map();  // ws -> { id, rooms }

function joinRoom(ws, roomId) {
  if (!rooms.has(roomId)) rooms.set(roomId, new Set());
  rooms.get(roomId).add(ws);

  const info = clientInfo.get(ws);
  info.rooms.add(roomId);

  // Notify room members
  broadcastToRoom(roomId, {
    type: 'room:join',
    userId: info.id,
    room: roomId,
    members: getRoomMembers(roomId),
  }, ws);
}

function leaveRoom(ws, roomId) {
  rooms.get(roomId)?.delete(ws);
  if (rooms.get(roomId)?.size === 0) rooms.delete(roomId);

  const info = clientInfo.get(ws);
  if (info) {
    info.rooms.delete(roomId);
    broadcastToRoom(roomId, {
      type: 'room:leave',
      userId: info.id,
      room: roomId,
      members: getRoomMembers(roomId),
    });
  }
}

function leaveAllRooms(ws) {
  const info = clientInfo.get(ws);
  if (!info) return;
  for (const roomId of info.rooms) {
    leaveRoom(ws, roomId);
  }
}

function getRoomMembers(roomId) {
  const members = [];
  rooms.get(roomId)?.forEach(ws => {
    const info = clientInfo.get(ws);
    if (info) members.push(info.id);
  });
  return members;
}

function broadcastToRoom(roomId, data, exclude = null) {
  const msg = JSON.stringify(data);
  rooms.get(roomId)?.forEach(client => {
    if (client !== exclude && client.readyState === 1) {
      client.send(msg);
    }
  });
}

function broadcast(data, exclude = null) {
  const msg = JSON.stringify(data);
  wss.clients.forEach(client => {
    if (client !== exclude && client.readyState === 1) {
      client.send(msg);
    }
  });
}

// WebSocket connection handler
wss.on('connection', (ws, req) => {
  const clientId = crypto.randomUUID().slice(0, 8);
  ws.isAlive = true;

  clientInfo.set(ws, { id: clientId, rooms: new Set() });
  console.log(`[+] Client connected: ${clientId} (total: ${wss.clients.size})`);

  // Send welcome message
  ws.send(JSON.stringify({
    type: 'welcome',
    clientId,
    timestamp: Date.now(),
  }));

  // Handle pong for heartbeat
  ws.on('pong', () => { ws.isAlive = true; });

  // Message handler
  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
      return;
    }

    const info = clientInfo.get(ws);

    switch (msg.type) {
      case 'join':
        if (msg.room) joinRoom(ws, msg.room);
        ws.send(JSON.stringify({ type: 'joined', room: msg.room, members: getRoomMembers(msg.room) }));
        break;

      case 'leave':
        if (msg.room) leaveRoom(ws, msg.room);
        ws.send(JSON.stringify({ type: 'left', room: msg.room }));
        break;

      case 'message':
        const outMsg = {
          type: 'message',
          from: info.id,
          text: msg.text,
          room: msg.room,
          timestamp: Date.now(),
        };
        if (msg.room) {
          broadcastToRoom(msg.room, outMsg, ws);
        } else {
          broadcast(outMsg, ws);
        }
        break;

      case 'ping':
        ws.send(JSON.stringify({ type: 'pong', timestamp: Date.now() }));
        break;

      default:
        ws.send(JSON.stringify({ type: 'error', message: `Unknown type: ${msg.type}` }));
    }
  });

  // Cleanup on disconnect
  ws.on('close', (code, reason) => {
    console.log(`[-] Client disconnected: ${clientId} (code: ${code})`);
    leaveAllRooms(ws);
    clientInfo.delete(ws);
  });

  ws.on('error', (err) => {
    console.error(`[!] Client error: ${clientId}`, err.message);
  });
});

// Heartbeat — detect dead connections every 30s
const heartbeatInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) {
      const info = clientInfo.get(ws);
      console.log(`[x] Terminating dead connection: ${info?.id}`);
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(heartbeatInterval));

// Graceful shutdown
function shutdown(signal) {
  console.log(`\n${signal} received. Shutting down gracefully...`);
  clearInterval(heartbeatInterval);

  wss.clients.forEach(ws => {
    ws.send(JSON.stringify({ type: 'server:shutdown' }));
    ws.close(1012, 'Server shutting down');
  });

  setTimeout(() => {
    wss.clients.forEach(ws => ws.terminate());
    server.close(() => {
      console.log('Server stopped.');
      process.exit(0);
    });
  }, 3000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Start server
server.listen(PORT, () => {
  console.log(`🌐 WebSocket server running on http://localhost:${PORT}`);
  console.log(`📊 Health check: http://localhost:${PORT}/health`);
});
SERVER_EOF

# Create client HTML page
cat > public/index.html << 'CLIENT_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WebSocket Client</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
    h1 { margin-bottom: 10px; }
    .status { padding: 8px 16px; border-radius: 4px; margin-bottom: 16px; font-weight: 500; }
    .status.connected { background: #d4edda; color: #155724; }
    .status.disconnected { background: #f8d7da; color: #721c24; }
    .status.connecting { background: #fff3cd; color: #856404; }
    .controls { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
    input, button { padding: 8px 12px; border: 1px solid #ccc; border-radius: 4px; font-size: 14px; }
    button { background: #007bff; color: white; border: none; cursor: pointer; }
    button:hover { background: #0056b3; }
    button:disabled { background: #6c757d; cursor: not-allowed; }
    #messages { border: 1px solid #ddd; border-radius: 4px; padding: 12px; height: 400px;
      overflow-y: auto; background: #f8f9fa; font-family: monospace; font-size: 13px; }
    .msg { padding: 2px 0; border-bottom: 1px solid #eee; }
    .msg.system { color: #6c757d; }
    .msg.error { color: #dc3545; }
    .msg.sent { color: #007bff; }
    .msg.received { color: #28a745; }
  </style>
</head>
<body>
  <h1>🔌 WebSocket Client</h1>
  <div id="status" class="status disconnected">Disconnected</div>

  <div class="controls">
    <input id="room" type="text" placeholder="Room name" value="general" />
    <button id="joinBtn" onclick="joinRoom()">Join Room</button>
    <button id="leaveBtn" onclick="leaveRoom()">Leave Room</button>
  </div>

  <div class="controls">
    <input id="message" type="text" placeholder="Type a message..." style="flex:1"
      onkeydown="if(event.key==='Enter')sendMessage()" />
    <button onclick="sendMessage()">Send</button>
  </div>

  <div id="messages"></div>

  <script>
    let ws = null;
    let clientId = null;
    let currentRoom = null;
    let attempt = 0;
    const maxRetries = 10;
    const messageQueue = [];

    function log(text, cls = '') {
      const el = document.getElementById('messages');
      const div = document.createElement('div');
      div.className = `msg ${cls}`;
      div.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
      el.appendChild(div);
      el.scrollTop = el.scrollHeight;
    }

    function setStatus(text, cls) {
      const el = document.getElementById('status');
      el.textContent = text;
      el.className = `status ${cls}`;
    }

    function connect() {
      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = `${protocol}//${location.host}`;
      setStatus('Connecting...', 'connecting');
      log('Connecting to server...', 'system');

      ws = new WebSocket(url);

      ws.onopen = () => {
        attempt = 0;
        setStatus('Connected', 'connected');
        log('Connected to server', 'system');
        // Flush queued messages
        while (messageQueue.length && ws.readyState === WebSocket.OPEN) {
          ws.send(messageQueue.shift());
        }
        // Rejoin room if we were in one
        if (currentRoom) {
          ws.send(JSON.stringify({ type: 'join', room: currentRoom }));
        }
      };

      ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        switch (msg.type) {
          case 'welcome':
            clientId = msg.clientId;
            log(`Assigned ID: ${clientId}`, 'system');
            break;
          case 'message':
            log(`[${msg.room || 'global'}] ${msg.from}: ${msg.text}`, 'received');
            break;
          case 'room:join':
            log(`${msg.userId} joined ${msg.room} (members: ${msg.members.join(', ')})`, 'system');
            break;
          case 'room:leave':
            log(`${msg.userId} left ${msg.room}`, 'system');
            break;
          case 'joined':
            log(`Joined room: ${msg.room} (members: ${msg.members.join(', ')})`, 'system');
            break;
          case 'left':
            log(`Left room: ${msg.room}`, 'system');
            break;
          case 'pong':
            break; // heartbeat response
          case 'server:shutdown':
            log('Server is shutting down, will reconnect...', 'system');
            break;
          case 'error':
            log(`Error: ${msg.message}`, 'error');
            break;
          default:
            log(`Unknown: ${JSON.stringify(msg)}`, 'system');
        }
      };

      ws.onclose = (e) => {
        setStatus('Disconnected', 'disconnected');
        log(`Disconnected (code: ${e.code}, reason: ${e.reason || 'none'})`, 'system');
        ws = null;
        if (e.code !== 1000 && attempt < maxRetries) {
          scheduleReconnect();
        }
      };

      ws.onerror = () => {
        log('Connection error', 'error');
      };
    }

    function scheduleReconnect() {
      const base = 500;
      const max = 30000;
      const delay = Math.min(base * Math.pow(2, attempt), max);
      const jitter = delay * (0.5 + Math.random() * 0.5);
      attempt++;
      log(`Reconnecting in ${Math.round(jitter)}ms (attempt ${attempt}/${maxRetries})...`, 'system');
      setTimeout(connect, jitter);
    }

    function safeSend(data) {
      const msg = JSON.stringify(data);
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(msg);
      } else {
        messageQueue.push(msg);
      }
    }

    function joinRoom() {
      const room = document.getElementById('room').value.trim();
      if (!room) return;
      currentRoom = room;
      safeSend({ type: 'join', room });
    }

    function leaveRoom() {
      if (!currentRoom) return;
      safeSend({ type: 'leave', room: currentRoom });
      currentRoom = null;
    }

    function sendMessage() {
      const input = document.getElementById('message');
      const text = input.value.trim();
      if (!text) return;
      const msg = { type: 'message', text, room: currentRoom };
      safeSend(msg);
      log(`[${currentRoom || 'global'}] you: ${text}`, 'sent');
      input.value = '';
    }

    // Heartbeat
    setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'ping' }));
      }
    }, 25000);

    // Connect on load
    connect();
  </script>
</body>
</html>
CLIENT_EOF

echo "📦 Installing dependencies..."
npm init -y > /dev/null 2>&1 || true
npm install --save ws express 2>&1 | tail -1

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "📁 Structure:"
echo "   $PROJECT_NAME/"
echo "   ├── package.json"
echo "   ├── src/"
echo "   │   └── server.js      # WebSocket server with rooms & heartbeat"
echo "   └── public/"
echo "       └── index.html     # Client with auto-reconnection"
echo ""
echo "🚀 To start:"
echo "   cd $PROJECT_NAME"
echo "   npm start"
echo ""
echo "   Then open http://localhost:3000 in your browser."
