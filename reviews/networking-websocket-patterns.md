# Review: websocket-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

Excellent skill with standard description format. Covers WebSocket protocol fundamentals (upgrade handshake, frame types, close codes), server implementations (Node.js ws, Socket.IO, Python websockets, Go nhooyr.io/websocket), client with resilient reconnection (exponential backoff + jitter), authentication patterns (query param, first-message, cookie-based), heartbeat/keepalive (protocol and application level, Nginx config), reconnection strategies with state recovery, message patterns (RPC, pub/sub, rooms), scaling with Redis pub/sub and sticky sessions, binary data (protobuf/MessagePack), error handling, security (origin checking, rate limiting), testing (Node.js test runner, wscat, artillery/k6), and Socket.IO vs raw WebSocket decision guide.
