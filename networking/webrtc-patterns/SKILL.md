---
name: webrtc-patterns
description: >
  Expert guidance for building WebRTC applications including RTCPeerConnection setup,
  signaling server patterns, ICE/STUN/TURN configuration, SDP offer/answer negotiation,
  media track constraints, data channels, screen sharing, recording with MediaRecorder,
  architecture selection (SFU vs mesh vs MCU), and advanced patterns like simulcast,
  SVC, bandwidth estimation, congestion control, insertable streams, and end-to-end
  encryption. Includes production-ready signaling server implementations, TURN server
  deployment, troubleshooting guides, and SFU integration (Janus, mediasoup, Pion).
  Triggers: WebRTC, peer connection, RTCPeerConnection, getUserMedia, ICE candidate,
  STUN/TURN, SDP offer/answer, media streaming peer-to-peer, data channel, screen sharing,
  getDisplayMedia, MediaRecorder WebRTC, signaling server, peer-to-peer video call,
  RTCDataChannel, RTCSessionDescription, addTrack, ontrack, icecandidate event,
  SRTP, DTLS, simulcast, SFU architecture, mesh topology WebRTC, coturn, mediasoup,
  Janus, Pion, ICE restart, bandwidth estimation, congestion control, E2EE WebRTC,
  insertable streams, encoded transform, WebRTC getStats, WebRTC troubleshooting,
  TURN server setup, WebRTC certificate, WebRTC nginx, scalable video coding, SVC.
  NOT for: HLS/DASH streaming, server-side video processing, FFmpeg encoding,
  WebSocket-only communication, general HTTP streaming, media server transcoding
  without WebRTC, or plain video element playback.
---

# WebRTC Patterns

## Core Concepts

WebRTC enables real-time P2P audio, video, and data in browsers via three APIs: **`RTCPeerConnection`** (connection lifecycle), **`getUserMedia`** (media capture), and **`RTCDataChannel`** (arbitrary data). All major browsers support it natively; use `webrtc-adapter` (adapter.js) for cross-browser normalization.

## RTCPeerConnection Setup

```javascript
import adapter from 'webrtc-adapter';

const config = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'turn:turn.example.com:3478', username: 'user', credential: 'pass' }
  ],
  iceTransportPolicy: 'all',  // 'relay' to force TURN
  bundlePolicy: 'max-bundle',
  rtcpMuxPolicy: 'require'
};
const pc = new RTCPeerConnection(config);

// Key events
pc.onicecandidate = ({ candidate }) => {
  if (candidate) sendToSignaling({ type: 'candidate', candidate });
};
pc.oniceconnectionstatechange = () => {
  // States: new, checking, connected, completed, disconnected, failed, closed
  if (pc.iceConnectionState === 'failed') handleReconnection();
};
pc.ontrack = (event) => { remoteVideo.srcObject = event.streams[0]; };
pc.onnegotiationneeded = async () => { await createAndSendOffer(); };
```

## Signaling Patterns

WebRTC does NOT define a signaling protocol. You must implement one (WebSocket, HTTP polling, SSE, etc.) to exchange SDP and ICE candidates.

### SDP Offer/Answer Flow

```
Caller                    Signaling Server               Callee
  |-- createOffer() -------->|                              |
  |-- setLocalDescription -->|                              |
  |                          |--- offer SDP --------------->|
  |                          |                  setRemoteDescription()
  |                          |                  createAnswer()
  |                          |                  setLocalDescription()
  |                          |<-- answer SDP ---------------|
  |<- setRemoteDescription --|                              |
  |                                                         |
  |<============ ICE candidates exchanged =================>|
```

### Offer/Answer Implementation

```javascript
// Caller
async function createAndSendOffer() {
  const offer = await pc.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: true });
  await pc.setLocalDescription(offer);
  sendToSignaling({ type: 'offer', sdp: pc.localDescription });
}

// Callee: receive offer, send answer
async function handleOffer(offer) {
  await pc.setRemoteDescription(new RTCSessionDescription(offer));
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  sendToSignaling({ type: 'answer', sdp: pc.localDescription });
}

// Both: handle ICE candidates with queueing for robustness
let candidateQueue = [];
async function handleCandidate(candidate) {
  if (pc.remoteDescription) {
    await pc.addIceCandidate(new RTCIceCandidate(candidate));
  } else {
    candidateQueue.push(candidate);
  }
}
async function drainCandidates() {
  for (const c of candidateQueue) await pc.addIceCandidate(c);
  candidateQueue = [];
}
// Call drainCandidates() immediately after setRemoteDescription()
```

## ICE / STUN / TURN Configuration

| Server Type | Purpose | When Needed |
|-------------|---------|-------------|
| **STUN** | Discovers public IP/port | Always (lightweight, free options exist) |
| **TURN** | Relays media when direct path fails | ~15-20% of real-world connections |

```javascript
const prodConfig = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    {
      urls: [
        'turn:turn.example.com:3478?transport=udp',
        'turn:turn.example.com:3478?transport=tcp',
        'turns:turn.example.com:443?transport=tcp'  // TLS fallback
      ],
      username: 'ephemeral-user',   // use short-lived HMAC-based credentials
      credential: 'ephemeral-pass'
    }
  ],
  iceCandidatePoolSize: 5  // pre-gather for faster setup
};
```

## Media Tracks and Constraints

```javascript
const stream = await navigator.mediaDevices.getUserMedia({
  audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  video: {
    width: { ideal: 1280, max: 1920 }, height: { ideal: 720, max: 1080 },
    frameRate: { ideal: 30, max: 60 }, facingMode: 'user'
  }
});
stream.getTracks().forEach(track => pc.addTrack(track, stream));

// Replace track without renegotiation (e.g., switch camera)
const sender = pc.getSenders().find(s => s.track?.kind === 'video');
const newStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
await sender.replaceTrack(newStream.getVideoTracks()[0]);

// Mute audio (track still sent, but silent)
stream.getAudioTracks()[0].enabled = false;
```

## Screen Sharing

```javascript
async function startScreenShare() {
  const screen = await navigator.mediaDevices.getDisplayMedia({
    video: { cursor: 'always', displaySurface: 'monitor' },
    audio: true  // system audio (Chrome only)
  });
  const screenTrack = screen.getVideoTracks()[0];
  const sender = pc.getSenders().find(s => s.track?.kind === 'video');
  await sender.replaceTrack(screenTrack);
  screenTrack.onended = async () => {
    const cam = await navigator.mediaDevices.getUserMedia({ video: true });
    await sender.replaceTrack(cam.getVideoTracks()[0]);
  };
}
```

## Data Channels

```javascript
// Caller creates data channel BEFORE offer
const dc = pc.createDataChannel('chat', { ordered: true, maxRetransmits: 3 });
dc.onopen = () => dc.send(JSON.stringify({ msg: 'hello' }));
dc.onmessage = (e) => console.log('Received:', e.data);
dc.onclose = () => console.log('Channel closed');

// Callee listens for incoming data channels
pc.ondatachannel = (event) => {
  event.channel.onmessage = (e) => console.log('Got:', e.data);
};

// Binary data (file transfer)
dc.binaryType = 'arraybuffer';
dc.send(new Uint8Array([1, 2, 3]).buffer);
```

## Recording with MediaRecorder

```javascript
const recorder = new MediaRecorder(stream, {
  mimeType: 'video/webm;codecs=vp9,opus', videoBitsPerSecond: 2_500_000
});
const chunks = [];
recorder.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data); };
recorder.onstop = () => {
  const blob = new Blob(chunks, { type: 'video/webm' });
  downloadLink.href = URL.createObjectURL(blob);
};
recorder.start(1000); // timeslice: emit data every 1s
```

## Architecture Patterns

### Mesh (P2P): Each peer connects to every other (N-1 connections). Best for ≤4 participants, lowest latency, no server cost. Scales O(n²).

### SFU (Selective Forwarding Unit): Each peer uploads one stream; SFU selectively forwards. Best for 5–100+ users. Supports simulcast/SVC. Open-source: mediasoup, LiveKit, Janus, ion-sfu.

### MCU (Multipoint Control Unit): Server mixes all streams into one composite per participant. Highest server cost, adds mixing latency. Use for low-power clients or compliance recording.

### Choosing an Architecture

| Factor | Mesh | SFU | MCU |
|--------|------|-----|-----|
| Max participants | ~4 | 100+ | 50+ |
| Server cost | None | Moderate | High |
| Latency | Lowest | Low | Higher |
| Client bandwidth | High | Low (upload) | Lowest |
| Recording | Local only | Server-composable | Built-in |

## Error Handling and Reconnection

```javascript
function handleReconnection() {
  if (['disconnected', 'failed'].includes(pc.iceConnectionState)) {
    setTimeout(async () => {
      if (pc.iceConnectionState !== 'connected' && pc.iceConnectionState !== 'completed') {
        const offer = await pc.createOffer({ iceRestart: true });
        await pc.setLocalDescription(offer);
        sendToSignaling({ type: 'offer', sdp: pc.localDescription });
      }
    }, 3000);
  }
}
pc.oniceconnectionstatechange = () => handleReconnection();

function closeConnection() {
  pc.getSenders().forEach(s => { if (s.track) s.track.stop(); });
  pc.close();
}
```

## adapter.js Compatibility

```bash
npm install webrtc-adapter
```

```javascript
import adapter from 'webrtc-adapter';
// adapter.browserDetails.browser => 'chrome' | 'firefox' | 'safari' | 'edge'
// Normalizes: getUserMedia, RTCPeerConnection, Unified Plan SDP, getStats(), ontrack
// Always import before any WebRTC code
```

## Performance Optimization

```javascript
// Simulcast (SFU setups)
const sender = pc.addTrack(videoTrack, stream);
const params = sender.getParameters();
params.encodings = [
  { rid: 'low', maxBitrate: 200_000, scaleResolutionDownBy: 4 },
  { rid: 'mid', maxBitrate: 700_000, scaleResolutionDownBy: 2 },
  { rid: 'high', maxBitrate: 2_500_000 }
];
await sender.setParameters(params);
```

### Stats Monitoring and Codec Preferences

```javascript
async function monitorStats() {
  const stats = await pc.getStats();
  stats.forEach(report => {
    if (report.type === 'inbound-rtp' && report.kind === 'video')
      console.log(`Lost: ${report.packetsLost}, Jitter: ${report.jitter}`);
    if (report.type === 'candidate-pair' && report.state === 'succeeded')
      console.log(`RTT: ${report.currentRoundTripTime}s`);
  });
}

// Prefer VP9 codec
const transceiver = pc.getTransceivers().find(t => t.receiver.track?.kind === 'video');
const codecs = RTCRtpReceiver.getCapabilities('video').codecs;
const vp9 = codecs.filter(c => c.mimeType === 'video/VP9');
transceiver.setCodecPreferences([...vp9, ...codecs.filter(c => c.mimeType !== 'video/VP9')]);
```

## Examples

### Example 1: Simple 1:1 Video Call

**Input:** "Set up a basic peer-to-peer video call"

**Output:**

```javascript
import adapter from 'webrtc-adapter';
const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
pc.ontrack = (e) => { document.getElementById('remote').srcObject = e.streams[0]; };
pc.onicecandidate = ({ candidate }) => {
  if (candidate) signaling.send(JSON.stringify({ type: 'candidate', candidate }));
};
const local = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
document.getElementById('local').srcObject = local;
local.getTracks().forEach(track => pc.addTrack(track, local));
// Caller: createOffer → setLocalDescription → send offer
// Callee: setRemoteDescription(offer) → createAnswer → setLocalDescription → send answer
```

### Example 2: Screen Share Toggle

**Input:** "Add screen share toggle to my WebRTC call"

**Output:**

```javascript
let isSharing = false, originalTrack = null;
async function toggleScreenShare() {
  const sender = pc.getSenders().find(s => s.track?.kind === 'video');
  if (!isSharing) {
    originalTrack = sender.track;
    const screen = await navigator.mediaDevices.getDisplayMedia({ video: true });
    const track = screen.getVideoTracks()[0];
    await sender.replaceTrack(track);
    track.onended = () => toggleScreenShare();
    isSharing = true;
  } else {
    await sender.replaceTrack(originalTrack);
    isSharing = false;
  }
}
```

### Example 3: File Transfer via Data Channel

**Input:** "Send a file over WebRTC data channel"

**Output:**

```javascript
// Sender
const dc = pc.createDataChannel('file', { ordered: true });
dc.binaryType = 'arraybuffer';
dc.onopen = async () => {
  const file = fileInput.files[0];
  dc.send(JSON.stringify({ name: file.name, size: file.size }));
  const buffer = await file.arrayBuffer();
  const CHUNK = 16384;
  for (let i = 0; i < buffer.byteLength; i += CHUNK) {
    dc.send(buffer.slice(i, i + CHUNK));
    if (dc.bufferedAmount > 1_000_000)
      await new Promise(r => { dc.onbufferedamountlow = r; });
  }
  dc.send(JSON.stringify({ done: true }));
};

// Receiver
pc.ondatachannel = (e) => {
  const ch = e.channel;
  let meta, chunks = [];
  ch.binaryType = 'arraybuffer';
  ch.onmessage = (evt) => {
    if (typeof evt.data === 'string') {
      const msg = JSON.parse(evt.data);
      if (msg.name) meta = msg;
      if (msg.done) {
        const a = document.createElement('a');
        a.href = URL.createObjectURL(new Blob(chunks));
        a.download = meta.name;
        a.click();
      }
    } else chunks.push(evt.data);
  };
};
```

## References

In-depth guides in `references/`:

| File | Topics |
|------|--------|
| [`advanced-patterns.md`](references/advanced-patterns.md) | Simulcast, SVC, bandwidth estimation, congestion control, insertable streams (Encoded Transform), E2EE, Janus/mediasoup/Pion integration, codec negotiation, cascaded SFU topology |
| [`troubleshooting.md`](references/troubleshooting.md) | ICE failures, STUN/TURN diagnostics, firewall traversal, NAT types, certificate errors, getStats() analysis, OTEL instrumentation, Safari/Firefox/Chrome quirks, common failure patterns |
| [`signaling-servers.md`](references/signaling-servers.md) | WebSocket signaling, Socket.IO patterns, HTTP polling fallback, room management, SFU signaling protocols (mediasoup/Janus/LiveKit), scaling with Redis, Kubernetes deployment, security |

## Scripts

Automation scripts in `scripts/` (all executable):

| Script | Purpose |
|--------|---------|
| [`setup-coturn.sh`](scripts/setup-coturn.sh) | Install and configure coturn TURN server with TLS, firewall rules, and ephemeral credentials |
| [`webrtc-stats-monitor.js`](scripts/webrtc-stats-monitor.js) | Node.js tool to parse and display WebRTC getStats() — file mode or live HTTP receiver |
| [`generate-certificates.sh`](scripts/generate-certificates.sh) | Generate self-signed TLS certificates for local WebRTC development (optional local CA) |

## Assets

Production-ready templates in `assets/`:

| Asset | Description |
|-------|-------------|
| [`signaling-server.js`](assets/signaling-server.js) | Complete WebSocket signaling server with room management, heartbeat, and optional JWT auth |
| [`peer-connection-template.js`](assets/peer-connection-template.js) | Copy-paste `PeerConnectionManager` class with ICE restart, candidate queueing, stats |
| [`media-constraints.json`](assets/media-constraints.json) | Presets for HD/SD/audio-only/screen-share constraints, simulcast encodings, codec prefs, ICE configs |
| [`coturn-config.conf`](assets/coturn-config.conf) | Production coturn configuration template with security hardening and documentation |
| [`nginx-webrtc.conf`](assets/nginx-webrtc.conf) | Nginx config for HTTPS + WebSocket proxy, sticky sessions, security headers, TURN TLS proxy |
