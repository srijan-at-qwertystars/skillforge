# Advanced WebRTC Patterns

## Table of Contents

- [Simulcast](#simulcast)
- [Scalable Video Coding (SVC)](#scalable-video-coding-svc)
- [Bandwidth Estimation](#bandwidth-estimation)
- [Congestion Control](#congestion-control)
- [Insertable Streams (Encoded Transform)](#insertable-streams-encoded-transform)
- [End-to-End Encryption (E2EE)](#end-to-end-encryption-e2ee)
- [SFU Integration: Janus](#sfu-integration-janus)
- [SFU Integration: mediasoup](#sfu-integration-mediasoup)
- [SFU Integration: Pion](#sfu-integration-pion)
- [Advanced Codec Negotiation](#advanced-codec-negotiation)
- [Scalable Architectures](#scalable-architectures)

---

## Simulcast

Simulcast sends multiple encodings of the same video track at different resolutions and
bitrates, allowing an SFU to forward the most appropriate layer to each receiver based on
their network conditions and viewport size.

### Configuration

```javascript
const sender = pc.addTrack(videoTrack, stream);
const params = sender.getParameters();

params.encodings = [
  {
    rid: 'q',                       // quarter resolution
    maxBitrate: 150_000,
    scaleResolutionDownBy: 4,
    maxFramerate: 15
  },
  {
    rid: 'h',                       // half resolution
    maxBitrate: 500_000,
    scaleResolutionDownBy: 2,
    maxFramerate: 30
  },
  {
    rid: 'f',                       // full resolution
    maxBitrate: 2_500_000,
    scaleResolutionDownBy: 1,
    maxFramerate: 30
  }
];

await sender.setParameters(params);
```

### SDP Munging for Simulcast (Legacy Browsers)

Some older browser versions require SDP manipulation to enable simulcast. With modern
Unified Plan, the `rid` approach above is preferred. If you must munge:

```javascript
function enableSimulcastInSDP(sdp) {
  // Add a=simulcast and a=rid lines to the video m-section
  const lines = sdp.split('\r\n');
  const videoIdx = lines.findIndex(l => l.startsWith('m=video'));
  if (videoIdx === -1) return sdp;

  const insertIdx = lines.findIndex((l, i) => i > videoIdx && l.startsWith('m='));
  const pos = insertIdx === -1 ? lines.length - 1 : insertIdx;

  lines.splice(pos, 0,
    'a=rid:q send',
    'a=rid:h send',
    'a=rid:f send',
    'a=simulcast:send q;h;f'
  );
  return lines.join('\r\n');
}
```

### Dynamic Layer Control

SFUs can request specific layers. On the client side, you can also enable/disable layers:

```javascript
async function toggleLayer(rid, active) {
  const sender = pc.getSenders().find(s => s.track?.kind === 'video');
  const params = sender.getParameters();
  const encoding = params.encodings.find(e => e.rid === rid);
  if (encoding) {
    encoding.active = active;
    await sender.setParameters(params);
  }
}

// Disable high-res layer when user minimizes video
await toggleLayer('f', false);
```

### Browser Support Notes

- **Chrome**: Full simulcast support with rid-based configuration
- **Firefox**: Supports simulcast but may require `a=simulcast` in SDP for some SFUs
- **Safari**: Simulcast support added in Safari 17+; older versions limited to single encoding

---

## Scalable Video Coding (SVC)

SVC encodes a single bitstream with hierarchical layers. Unlike simulcast's separate
streams, SVC uses a single encoded stream with temporal and spatial layers that can be
selectively dropped by an SFU.

### SVC Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `L1T3` | 1 spatial, 3 temporal layers | Bandwidth adaptation only |
| `L2T3` | 2 spatial, 3 temporal layers | Resolution + framerate |
| `L3T3` | 3 spatial, 3 temporal layers | Full scalability |
| `L2T1` | 2 spatial, 1 temporal | Resolution adaptation |
| `S2T3` | 2 simulcast-like, 3 temporal (K-SVC) | SFU-friendly variant |

### Enabling SVC with VP9/AV1

```javascript
const sender = pc.addTrack(videoTrack, stream);
const params = sender.getParameters();

params.encodings = [{
  scalabilityMode: 'L3T3',        // 3 spatial + 3 temporal layers
  maxBitrate: 2_500_000
}];

await sender.setParameters(params);
```

### Querying Supported Scalability Modes

```javascript
const capabilities = RTCRtpSender.getCapabilities('video');
const vp9Codec = capabilities.codecs.find(c => c.mimeType === 'video/VP9');
// Chrome exposes scalabilityModes on the codec capability
console.log(vp9Codec?.scalabilityModes);
// e.g., ['L1T1', 'L1T2', 'L1T3', 'L2T1', 'L2T2', 'L2T3', 'L3T1', 'L3T2', 'L3T3']
```

### SVC vs Simulcast Decision Matrix

| Factor | Simulcast | SVC |
|--------|-----------|-----|
| Encoding overhead | Higher (3 separate encodes) | Lower (single encode) |
| Bandwidth usage | Higher total upload | More efficient |
| SFU complexity | Simpler forwarding logic | Needs SVC-aware SFU |
| Codec support | VP8, VP9, H.264 | VP9, AV1 only |
| Browser support | Broad | Limited (Chrome/Edge best) |
| Layer switching | Keyframe needed | Instant layer drop |

---

## Bandwidth Estimation

WebRTC uses bandwidth estimation (BWE) to dynamically adapt sending bitrate to available
network capacity. Understanding BWE helps build adaptive quality systems.

### Monitoring Available Bandwidth

```javascript
async function getEstimatedBandwidth() {
  const stats = await pc.getStats();
  let result = {};

  stats.forEach(report => {
    // Outbound bandwidth estimation
    if (report.type === 'outbound-rtp' && report.kind === 'video') {
      result.targetBitrate = report.targetBitrate;         // BWE target
      result.totalBytesSent = report.bytesSent;
      result.retransmittedBytesSent = report.retransmittedBytesSent;
    }

    // Transport-level stats
    if (report.type === 'transport') {
      result.availableOutgoingBitrate = report.availableOutgoingBitrate;
      result.availableIncomingBitrate = report.availableIncomingBitrate;
    }

    // Active candidate pair RTT
    if (report.type === 'candidate-pair' && report.state === 'succeeded') {
      result.currentRoundTripTime = report.currentRoundTripTime;
      result.availableOutgoingBitrate = report.availableOutgoingBitrate;
    }
  });

  return result;
}
```

### Adaptive Bitrate Control

```javascript
class AdaptiveBitrateController {
  constructor(sender, options = {}) {
    this.sender = sender;
    this.minBitrate = options.minBitrate || 100_000;
    this.maxBitrate = options.maxBitrate || 2_500_000;
    this.stepDown = options.stepDown || 0.7;    // reduce by 30%
    this.stepUp = options.stepUp || 1.1;        // increase by 10%
    this.interval = null;
  }

  start(pc, intervalMs = 2000) {
    this.interval = setInterval(async () => {
      const stats = await pc.getStats();
      let packetLoss = 0, rtt = 0;

      stats.forEach(report => {
        if (report.type === 'outbound-rtp' && report.kind === 'video') {
          const total = report.packetsSent || 1;
          packetLoss = (report.packetsLost || 0) / total;
        }
        if (report.type === 'candidate-pair' && report.state === 'succeeded') {
          rtt = report.currentRoundTripTime || 0;
        }
      });

      await this.adjust(packetLoss, rtt);
    }, intervalMs);
  }

  async adjust(packetLoss, rtt) {
    const params = this.sender.getParameters();
    const encoding = params.encodings[0];
    if (!encoding) return;

    let current = encoding.maxBitrate || this.maxBitrate;

    if (packetLoss > 0.05 || rtt > 0.3) {
      current = Math.max(this.minBitrate, current * this.stepDown);
    } else if (packetLoss < 0.01 && rtt < 0.1) {
      current = Math.min(this.maxBitrate, current * this.stepUp);
    }

    encoding.maxBitrate = Math.round(current);
    await this.sender.setParameters(params);
  }

  stop() {
    if (this.interval) clearInterval(this.interval);
  }
}

// Usage
const sender = pc.getSenders().find(s => s.track?.kind === 'video');
const abc = new AdaptiveBitrateController(sender);
abc.start(pc);
```

### GCC (Google Congestion Control) Internals

Chrome uses GCC for BWE, which combines:

1. **Delay-based estimation**: Monitors inter-arrival time variation of packets
2. **Loss-based estimation**: Reduces bitrate on packet loss
3. **REMB / Transport-CC**: Receiver sends feedback to sender

The final estimate is the minimum of delay-based and loss-based estimates.

---

## Congestion Control

### Transport-CC vs REMB

| Feature | REMB | Transport-CC |
|---------|------|-------------|
| Feedback | Receiver-side BWE | Sender-side BWE |
| Granularity | Per-SSRC | Per-packet |
| SDP line | `a=rtcp-fb:* goog-remb` | `a=extmap:N transport-cc` |
| Accuracy | Good | Better |
| Standard | Deprecated | RFC 8888 draft |

### Enabling Transport-CC

```javascript
// Usually enabled by default in modern browsers
// Verify via SDP:
const offer = await pc.createOffer();
console.log(offer.sdp.includes('transport-cc')); // should be true
```

### Network Emulation for Testing

```javascript
// Chrome DevTools: Network conditions
// Or programmatically with a TURN server that supports bandwidth limiting

// Test with constrained bitrate
const params = sender.getParameters();
params.encodings[0].maxBitrate = 300_000; // simulate poor network
await sender.setParameters(params);
```

### DSCP Marking for QoS

```javascript
// Set priority for network QoS (if network supports DSCP)
const params = sender.getParameters();
params.encodings[0].networkPriority = 'high'; // 'very-low', 'low', 'medium', 'high'
params.encodings[0].priority = 'high';
await sender.setParameters(params);
```

---

## Insertable Streams (Encoded Transform)

The Encoded Transform API (formerly Insertable Streams) allows JavaScript to process
encoded media frames between encoding and packetization (sender) or between
depacketization and decoding (receiver). This enables E2EE, custom codecs, watermarking,
and more.

### Architecture

```
Sender:
  Camera → Encoder → [Transform] → Packetizer → Network

Receiver:
  Network → Depacketizer → [Transform] → Decoder → Display
```

### Basic Encoded Transform

```javascript
// Sender-side transform
const sender = pc.addTrack(videoTrack, stream);

const senderStreams = sender.createEncodedStreams();
const transformStream = new TransformStream({
  transform(encodedFrame, controller) {
    // Access raw encoded frame data
    const data = new Uint8Array(encodedFrame.data);

    // Example: Add a watermark byte sequence
    const newData = new Uint8Array(data.length + 4);
    newData.set(data);
    newData.set([0xDE, 0xAD, 0xBE, 0xEF], data.length);

    encodedFrame.data = newData.buffer;
    controller.enqueue(encodedFrame);
  }
});

senderStreams.readable
  .pipeThrough(transformStream)
  .pipeTo(senderStreams.writable);
```

### Worker-Based Transform (Recommended)

For performance, run transforms in a Web Worker:

```javascript
// main.js
const worker = new Worker('transform-worker.js');

const sender = pc.addTrack(videoTrack, stream);
const senderTransform = new RTCRtpScriptTransform(worker, {
  operation: 'encrypt',
  key: encryptionKey
});
sender.transform = senderTransform;

const receiver = pc.getReceivers().find(r => r.track.kind === 'video');
const receiverTransform = new RTCRtpScriptTransform(worker, {
  operation: 'decrypt',
  key: encryptionKey
});
receiver.transform = receiverTransform;
```

```javascript
// transform-worker.js
onrtctransform = (event) => {
  const { readable, writable } = event.transformer;
  const { operation, key } = event.transformer.options;

  const transform = new TransformStream({
    async transform(frame, controller) {
      if (operation === 'encrypt') {
        frame.data = await encrypt(frame.data, key);
      } else {
        frame.data = await decrypt(frame.data, key);
      }
      controller.enqueue(frame);
    }
  });

  readable.pipeThrough(transform).pipeTo(writable);
};
```

---

## End-to-End Encryption (E2EE)

E2EE ensures media is encrypted from sender to receiver, even through SFU relay servers.
The SFU forwards encrypted packets it cannot read.

### SFrame-Based E2EE

```javascript
// Using the SFrame transform approach
class E2EEManager {
  constructor() {
    this.keyMaterial = null;
    this.cryptoKey = null;
    this.frameCounter = 0;
  }

  async setKey(password) {
    const encoder = new TextEncoder();
    this.keyMaterial = await crypto.subtle.importKey(
      'raw', encoder.encode(password), 'PBKDF2', false, ['deriveKey']
    );

    this.cryptoKey = await crypto.subtle.deriveKey(
      { name: 'PBKDF2', salt: encoder.encode('webrtc-e2ee'), iterations: 100000, hash: 'SHA-256' },
      this.keyMaterial,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt']
    );
  }

  async encryptFrame(frame) {
    const iv = new Uint8Array(12);
    const counter = this.frameCounter++;
    new DataView(iv.buffer).setUint32(8, counter);

    const data = new Uint8Array(frame.data);

    // Keep first few bytes unencrypted for SFU to parse RTP header extensions
    const headerBytes = frame.type === 'key' ? 10 : 3;
    const header = data.slice(0, headerBytes);
    const payload = data.slice(headerBytes);

    const encrypted = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv, additionalData: header },
      this.cryptoKey, payload
    );

    const result = new Uint8Array(header.length + encrypted.byteLength + iv.byteLength);
    result.set(header);
    result.set(new Uint8Array(encrypted), header.length);
    result.set(iv, header.length + encrypted.byteLength);

    frame.data = result.buffer;
    return frame;
  }

  async decryptFrame(frame) {
    const data = new Uint8Array(frame.data);

    const headerBytes = frame.type === 'key' ? 10 : 3;
    const header = data.slice(0, headerBytes);
    const iv = data.slice(data.length - 12);
    const encrypted = data.slice(headerBytes, data.length - 12);

    const decrypted = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv, additionalData: header },
      this.cryptoKey, encrypted
    );

    const result = new Uint8Array(header.length + decrypted.byteLength);
    result.set(header);
    result.set(new Uint8Array(decrypted), header.length);

    frame.data = result.buffer;
    return frame;
  }
}
```

### Key Ratcheting for Forward Secrecy

```javascript
class KeyRatchet {
  constructor(initialKey) {
    this.currentKey = initialKey;
    this.keyIndex = 0;
    this.oldKeys = new Map(); // keep old keys for late packets
  }

  async ratchet() {
    const rawKey = await crypto.subtle.exportKey('raw', this.currentKey);
    const hash = await crypto.subtle.digest('SHA-256', rawKey);

    this.oldKeys.set(this.keyIndex, this.currentKey);
    this.keyIndex++;

    this.currentKey = await crypto.subtle.importKey(
      'raw', hash, { name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']
    );

    // Clean up old keys after grace period
    if (this.oldKeys.size > 5) {
      const oldest = Math.min(...this.oldKeys.keys());
      this.oldKeys.delete(oldest);
    }

    return { key: this.currentKey, index: this.keyIndex };
  }
}
```

---

## SFU Integration: Janus

[Janus](https://janus.conf.meetecho.com/) is a general-purpose WebRTC gateway written in
C. It uses a plugin architecture for different use cases.

### Janus Signaling (HTTP + WebSocket)

```javascript
class JanusSession {
  constructor(serverUrl) {
    this.serverUrl = serverUrl;
    this.sessionId = null;
    this.handleId = null;
    this.ws = null;
    this.transactions = new Map();
  }

  async connect() {
    this.ws = new WebSocket(this.serverUrl, 'janus-protocol');

    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.transaction && this.transactions.has(msg.transaction)) {
        this.transactions.get(msg.transaction)(msg);
        this.transactions.delete(msg.transaction);
      }
      this.handleEvent(msg);
    };

    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });

    // Create session
    const sessionResp = await this.sendRequest({ janus: 'create' });
    this.sessionId = sessionResp.data.id;

    // Keep-alive
    this.keepAliveInterval = setInterval(() => {
      this.send({ janus: 'keepalive', session_id: this.sessionId });
    }, 25000);
  }

  async attachPlugin(plugin) {
    const resp = await this.sendRequest({
      janus: 'attach',
      session_id: this.sessionId,
      plugin: plugin   // e.g., 'janus.plugin.videoroom'
    });
    this.handleId = resp.data.id;
    return this.handleId;
  }

  async sendMessage(body, jsep = null) {
    const msg = {
      janus: 'message',
      session_id: this.sessionId,
      handle_id: this.handleId,
      body: body
    };
    if (jsep) msg.jsep = jsep;
    return this.sendRequest(msg);
  }

  sendRequest(msg) {
    return new Promise((resolve) => {
      const transaction = Math.random().toString(36).substr(2, 12);
      msg.transaction = transaction;
      this.transactions.set(transaction, resolve);
      this.ws.send(JSON.stringify(msg));
    });
  }

  send(msg) {
    this.ws.send(JSON.stringify(msg));
  }

  handleEvent(msg) {
    if (msg.janus === 'event') {
      // Handle plugin-specific events
      if (msg.plugindata?.data) {
        this.onPluginEvent?.(msg.plugindata.data, msg.jsep);
      }
    }
  }

  destroy() {
    clearInterval(this.keepAliveInterval);
    this.send({ janus: 'destroy', session_id: this.sessionId });
    this.ws.close();
  }
}

// Usage with VideoRoom plugin
const janus = new JanusSession('wss://janus.example.com/ws');
await janus.connect();
await janus.attachPlugin('janus.plugin.videoroom');

// Join a room
const joinResp = await janus.sendMessage({
  request: 'join',
  room: 1234,
  ptype: 'publisher',
  display: 'Alice'
});
```

---

## SFU Integration: mediasoup

[mediasoup](https://mediasoup.org/) is a Node.js SFU with a C++ media worker. It uses a
"router" model where producers and consumers connect through server-side routers.

### Server-Side Setup

```javascript
const mediasoup = require('mediasoup');

async function createMediasoupRouter() {
  const worker = await mediasoup.createWorker({
    rtcMinPort: 40000,
    rtcMaxPort: 49999,
    logLevel: 'warn'
  });

  const router = await worker.createRouter({
    mediaCodecs: [
      { kind: 'audio', mimeType: 'audio/opus', clockRate: 48000, channels: 2 },
      {
        kind: 'video', mimeType: 'video/VP9', clockRate: 90000,
        parameters: { 'profile-id': 2 }   // profile 2 for SVC
      },
      { kind: 'video', mimeType: 'video/H264', clockRate: 90000,
        parameters: { 'packetization-mode': 1, 'profile-level-id': '42e01f' }
      }
    ]
  });

  return { worker, router };
}
```

### Client-Side mediasoup Integration

```javascript
import { Device } from 'mediasoup-client';

class MediasoupClient {
  constructor(signaling) {
    this.signaling = signaling;
    this.device = new Device();
    this.sendTransport = null;
    this.recvTransport = null;
  }

  async connect(routerRtpCapabilities) {
    await this.device.load({ routerRtpCapabilities });

    this.sendTransport = await this.createTransport('produce');
    this.recvTransport = await this.createTransport('consume');
  }

  async createTransport(direction) {
    const transportOptions = await this.signaling.request('createTransport', {
      direction,
      rtpCapabilities: this.device.rtpCapabilities
    });

    const transport = direction === 'produce'
      ? this.device.createSendTransport(transportOptions)
      : this.device.createRecvTransport(transportOptions);

    transport.on('connect', async ({ dtlsParameters }, callback, errback) => {
      try {
        await this.signaling.request('connectTransport', {
          transportId: transport.id, dtlsParameters
        });
        callback();
      } catch (err) { errback(err); }
    });

    if (direction === 'produce') {
      transport.on('produce', async ({ kind, rtpParameters }, callback, errback) => {
        try {
          const { id } = await this.signaling.request('produce', {
            transportId: transport.id, kind, rtpParameters
          });
          callback({ id });
        } catch (err) { errback(err); }
      });
    }

    return transport;
  }

  async produce(track) {
    const producer = await this.sendTransport.produce({
      track,
      encodings: track.kind === 'video' ? [
        { rid: 'r0', maxBitrate: 100_000, scalabilityMode: 'L1T3' },
        { rid: 'r1', maxBitrate: 300_000, scalabilityMode: 'L1T3' },
        { rid: 'r2', maxBitrate: 900_000, scalabilityMode: 'L1T3' }
      ] : undefined,
      codecOptions: track.kind === 'audio'
        ? { opusStereo: true, opusDtx: true }
        : { videoGoogleStartBitrate: 1000 }
    });

    return producer;
  }

  async consume(producerId) {
    const consumerOptions = await this.signaling.request('consume', {
      producerId,
      transportId: this.recvTransport.id,
      rtpCapabilities: this.device.rtpCapabilities
    });

    const consumer = await this.recvTransport.consume(consumerOptions);
    return consumer;
  }
}
```

---

## SFU Integration: Pion

[Pion](https://github.com/pion/webrtc) is a Go implementation of WebRTC. It is ideal for
building custom SFUs, MCUs, or media processing pipelines in Go.

### Basic Pion SFU

```go
package main

import (
    "encoding/json"
    "fmt"
    "net/http"
    "sync"

    "github.com/gorilla/websocket"
    "github.com/pion/webrtc/v4"
)

type Room struct {
    mu    sync.RWMutex
    peers map[string]*Peer
}

type Peer struct {
    pc     *webrtc.PeerConnection
    tracks []*webrtc.TrackLocalStaticRTP
}

var upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

func main() {
    room := &Room{peers: make(map[string]*Peer)}

    http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
        conn, _ := upgrader.Upgrade(w, r, nil)
        handlePeer(conn, room)
    })

    fmt.Println("SFU listening on :8080")
    http.ListenAndServe(":8080", nil)
}

func handlePeer(conn *websocket.Conn, room *Room) {
    config := webrtc.Configuration{
        ICEServers: []webrtc.ICEServer{
            {URLs: []string{"stun:stun.l.google.com:19302"}},
        },
    }

    pc, _ := webrtc.NewPeerConnection(config)

    // Handle incoming tracks and forward to other peers
    pc.OnTrack(func(remoteTrack *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
        localTrack, _ := webrtc.NewTrackLocalStaticRTP(
            remoteTrack.Codec().RTPCodecCapability,
            remoteTrack.ID(),
            remoteTrack.StreamID(),
        )

        room.mu.Lock()
        // Add local track and forward to all other peers
        for _, peer := range room.peers {
            peer.pc.AddTrack(localTrack)
        }
        room.mu.Unlock()

        // Forward RTP packets
        buf := make([]byte, 1500)
        for {
            n, _, err := remoteTrack.Read(buf)
            if err != nil {
                return
            }
            localTrack.Write(buf[:n])
        }
    })

    // Signaling message handling
    for {
        _, raw, err := conn.ReadMessage()
        if err != nil {
            return
        }

        var msg map[string]interface{}
        json.Unmarshal(raw, &msg)

        switch msg["type"] {
        case "offer":
            sdp := webrtc.SessionDescription{
                Type: webrtc.SDPTypeOffer,
                SDP:  msg["sdp"].(string),
            }
            pc.SetRemoteDescription(sdp)
            answer, _ := pc.CreateAnswer(nil)
            pc.SetLocalDescription(answer)

            resp, _ := json.Marshal(map[string]string{
                "type": "answer",
                "sdp":  answer.SDP,
            })
            conn.WriteMessage(websocket.TextMessage, resp)

        case "candidate":
            candidateJSON, _ := json.Marshal(msg["candidate"])
            candidate := webrtc.ICECandidateInit{}
            json.Unmarshal(candidateJSON, &candidate)
            pc.AddICECandidate(candidate)
        }
    }
}
```

---

## Advanced Codec Negotiation

### Codec Preference Order

```javascript
function setCodecPreferences(pc, mimeType, kind = 'video') {
  const transceivers = pc.getTransceivers();

  for (const transceiver of transceivers) {
    if (transceiver.receiver.track?.kind !== kind) continue;

    const capabilities = RTCRtpReceiver.getCapabilities(kind);
    if (!capabilities) continue;

    const preferred = capabilities.codecs.filter(c =>
      c.mimeType.toLowerCase() === mimeType.toLowerCase()
    );
    const rest = capabilities.codecs.filter(c =>
      c.mimeType.toLowerCase() !== mimeType.toLowerCase()
    );

    transceiver.setCodecPreferences([...preferred, ...rest]);
  }
}

// Prefer AV1 with VP9 fallback
setCodecPreferences(pc, 'video/AV1');
```

### Hardware Acceleration Detection

```javascript
async function detectHWAcceleration(pc) {
  const stats = await pc.getStats();
  const info = {};

  stats.forEach(report => {
    if (report.type === 'outbound-rtp' && report.kind === 'video') {
      info.encoderImplementation = report.encoderImplementation;
      // 'ExternalEncoder' = HW, 'libvpx' / 'OpenH264' = SW
      info.isHardwareAccelerated = report.encoderImplementation === 'ExternalEncoder'
        || report.encoderImplementation?.includes('VideoToolbox')
        || report.encoderImplementation?.includes('NVENC');
    }
    if (report.type === 'inbound-rtp' && report.kind === 'video') {
      info.decoderImplementation = report.decoderImplementation;
    }
  });

  return info;
}
```

---

## Scalable Architectures

### Cascaded SFU Topology

For geo-distributed deployments, cascade SFUs across regions:

```
Region A (US-East)          Region B (EU-West)
┌──────────────────┐        ┌──────────────────┐
│  SFU Node A      │◄──────►│  SFU Node B      │
│  ┌────────────┐  │  RTP   │  ┌────────────┐  │
│  │ Room 1234  │  │ relay  │  │ Room 1234  │  │
│  │ Alice, Bob │  │        │  │ Carol, Dan │  │
│  └────────────┘  │        │  └────────────┘  │
└──────────────────┘        └──────────────────┘
```

### Load Balancing Strategy

```javascript
// Client-side SFU selection based on latency probing
async function selectBestSFU(sfuEndpoints) {
  const results = await Promise.all(
    sfuEndpoints.map(async (endpoint) => {
      const start = performance.now();
      try {
        await fetch(`${endpoint}/health`, { signal: AbortSignal.timeout(3000) });
        return { endpoint, latency: performance.now() - start };
      } catch {
        return { endpoint, latency: Infinity };
      }
    })
  );

  return results.sort((a, b) => a.latency - b.latency)[0].endpoint;
}
```

### Horizontal Scaling with Redis Pub/Sub

```javascript
// SFU node coordination via Redis
const Redis = require('ioredis');
const pub = new Redis();
const sub = new Redis();

// When a new producer joins, notify all SFU nodes
async function onProducerAdded(roomId, producerId, sdp) {
  await pub.publish('sfu:producers', JSON.stringify({
    event: 'producer-added',
    roomId, producerId, sdp,
    nodeId: process.env.NODE_ID
  }));
}

// Each SFU node subscribes and creates relay consumers
sub.subscribe('sfu:producers');
sub.on('message', (channel, message) => {
  const data = JSON.parse(message);
  if (data.nodeId === process.env.NODE_ID) return; // skip self

  if (data.event === 'producer-added') {
    createRelayConsumer(data.roomId, data.producerId, data.sdp);
  }
});
```
