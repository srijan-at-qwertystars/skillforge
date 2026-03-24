# WebRTC Troubleshooting Guide

## Table of Contents

- [ICE Failures](#ice-failures)
- [STUN/TURN Diagnostics](#stunturn-diagnostics)
- [Firewall Traversal](#firewall-traversal)
- [NAT Issues](#nat-issues)
- [Certificate Errors](#certificate-errors)
- [getStats() Analysis](#getstats-analysis)
- [OpenTelemetry (OTEL) Debugging](#opentelemetry-otel-debugging)
- [Browser Quirks: Safari](#browser-quirks-safari)
- [Browser Quirks: Firefox](#browser-quirks-firefox)
- [Browser Quirks: Chrome/Edge](#browser-quirks-chromeedge)
- [Common Failure Patterns](#common-failure-patterns)
- [Debugging Tools and Techniques](#debugging-tools-and-techniques)

---

## ICE Failures

### ICE Connection States

```
new → checking → connected → completed
                     ↓
               disconnected → failed
                     ↓
                   closed
```

### Diagnosing ICE Failures

```javascript
pc.oniceconnectionstatechange = () => {
  console.log(`ICE state: ${pc.iceConnectionState}`);

  switch (pc.iceConnectionState) {
    case 'checking':
      console.log('ICE checking — candidates being tested');
      break;
    case 'connected':
      logSelectedCandidatePair();
      break;
    case 'disconnected':
      console.warn('ICE disconnected — may recover automatically');
      startReconnectionTimer();
      break;
    case 'failed':
      console.error('ICE failed — all candidate pairs exhausted');
      collectDiagnostics();
      break;
  }
};

pc.onicegatheringstatechange = () => {
  console.log(`ICE gathering: ${pc.iceGatheringState}`);
  // 'new' → 'gathering' → 'complete'
};

async function logSelectedCandidatePair() {
  const stats = await pc.getStats();
  stats.forEach(report => {
    if (report.type === 'candidate-pair' && report.state === 'succeeded') {
      console.log('Selected pair:', {
        local: report.localCandidateId,
        remote: report.remoteCandidateId,
        protocol: report.protocol,
        rtt: report.currentRoundTripTime
      });
    }
  });
}
```

### Common ICE Failure Causes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Stuck in `checking` | Candidates not reaching peer | Check signaling delivery |
| Immediate `failed` | No valid candidates | Add TURN server |
| `failed` after `checking` | Firewall blocking UDP | Add TURN/TCP or TURNS |
| `disconnected` → `failed` | Network change (WiFi→cellular) | ICE restart |
| No candidates gathered | getUserMedia not called first | Request media before offer |

### ICE Restart

```javascript
async function iceRestart() {
  console.log('Performing ICE restart...');
  const offer = await pc.createOffer({ iceRestart: true });
  await pc.setLocalDescription(offer);
  sendToSignaling({ type: 'offer', sdp: pc.localDescription });
}

// Automatic restart with backoff
let restartAttempts = 0;
const MAX_RESTARTS = 5;

function scheduleRestart() {
  if (restartAttempts >= MAX_RESTARTS) {
    console.error('Max ICE restarts reached, giving up');
    closeAndReportError();
    return;
  }
  const delay = Math.min(1000 * Math.pow(2, restartAttempts), 30000);
  restartAttempts++;
  setTimeout(iceRestart, delay);
}
```

### Candidate Filtering Debug

```javascript
pc.onicecandidate = ({ candidate }) => {
  if (!candidate) {
    console.log('ICE gathering complete');
    return;
  }

  const { type, protocol, address, port, relatedAddress } = candidate;
  console.log(`Candidate: ${type} ${protocol} ${address}:${port}`, {
    relatedAddress,  // only for srflx/relay
    foundation: candidate.foundation,
    priority: candidate.priority,
    component: candidate.component
  });

  // Detect mDNS candidates (privacy-obfuscated)
  if (address?.endsWith('.local')) {
    console.log('mDNS candidate — real IP hidden by browser');
  }

  sendToSignaling({ type: 'candidate', candidate });
};
```

---

## STUN/TURN Diagnostics

### Testing TURN Server Connectivity

```javascript
async function testTurnServer(url, username, credential) {
  const testPc = new RTCPeerConnection({
    iceServers: [{ urls: url, username, credential }],
    iceTransportPolicy: 'relay'  // force TURN only
  });

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      testPc.close();
      reject(new Error('TURN test timed out — server unreachable'));
    }, 10000);

    let relayCandidate = false;

    testPc.onicecandidate = ({ candidate }) => {
      if (candidate?.type === 'relay') {
        relayCandidate = true;
        clearTimeout(timeout);
        testPc.close();
        resolve({
          success: true,
          relayAddress: candidate.address,
          relayPort: candidate.port,
          protocol: candidate.protocol
        });
      }
    };

    testPc.onicegatheringstatechange = () => {
      if (testPc.iceGatheringState === 'complete' && !relayCandidate) {
        clearTimeout(timeout);
        testPc.close();
        reject(new Error('TURN test failed — no relay candidates'));
      }
    };

    // Create a dummy data channel to trigger ICE
    testPc.createDataChannel('test');
    testPc.createOffer().then(o => testPc.setLocalDescription(o));
  });
}

// Usage
try {
  const result = await testTurnServer(
    'turn:turn.example.com:3478',
    'user', 'pass'
  );
  console.log('TURN OK:', result);
} catch (err) {
  console.error('TURN FAILED:', err.message);
}
```

### HMAC-Based Ephemeral TURN Credentials

```javascript
// Server-side (Node.js)
const crypto = require('crypto');

function generateTurnCredentials(username, secret, ttl = 86400) {
  const timestamp = Math.floor(Date.now() / 1000) + ttl;
  const tempUsername = `${timestamp}:${username}`;
  const hmac = crypto.createHmac('sha1', secret);
  hmac.update(tempUsername);
  const credential = hmac.digest('base64');
  return { username: tempUsername, credential };
}

// coturn config: use-auth-secret, static-auth-secret=YOUR_SECRET
```

### CLI TURN Server Testing

```bash
# Install turnutils
sudo apt-get install coturn

# Test STUN
turnutils_stunclient stun.l.google.com

# Test TURN
turnutils_uclient -u user -w pass -T turn.example.com

# Test TURNS (TLS)
turnutils_uclient -u user -w pass -S -p 443 turn.example.com
```

---

## Firewall Traversal

### Required Ports

| Protocol | Port | Purpose |
|----------|------|---------|
| UDP | 3478 | STUN/TURN |
| TCP | 3478 | TURN/TCP |
| UDP | 443 | TURN over DTLS |
| TCP | 443 | TURNS (TLS) — firewall-friendly |
| UDP | 49152-65535 | Media (RTP/RTCP), narrower range configurable |
| TCP | 80/443 | Signaling (WebSocket/HTTPS) |

### Corporate Firewall Strategy

```javascript
// Aggressive fallback configuration
const firewallFriendlyConfig = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    {
      urls: [
        'turn:turn.example.com:3478?transport=udp',   // try UDP first
        'turn:turn.example.com:3478?transport=tcp',   // TCP fallback
        'turns:turn.example.com:443?transport=tcp'    // TLS on 443 — best firewall traversal
      ],
      username: 'user',
      credential: 'pass'
    }
  ],
  // If behind very restrictive firewall, force relay
  iceTransportPolicy: 'relay'
};
```

### Firewall Detection

```javascript
async function detectFirewallRestrictions() {
  const results = { stun: false, turnUdp: false, turnTcp: false, turns: false };

  const tests = [
    { name: 'stun', config: { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] }, expectedType: 'srflx' },
    { name: 'turnUdp', config: { iceServers: [{ urls: 'turn:turn.example.com:3478?transport=udp', username: 'u', credential: 'p' }], iceTransportPolicy: 'relay' }, expectedType: 'relay' },
    { name: 'turnTcp', config: { iceServers: [{ urls: 'turn:turn.example.com:3478?transport=tcp', username: 'u', credential: 'p' }], iceTransportPolicy: 'relay' }, expectedType: 'relay' },
    { name: 'turns', config: { iceServers: [{ urls: 'turns:turn.example.com:443?transport=tcp', username: 'u', credential: 'p' }], iceTransportPolicy: 'relay' }, expectedType: 'relay' }
  ];

  for (const test of tests) {
    try {
      const pc = new RTCPeerConnection(test.config);
      pc.createDataChannel('test');
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pc.close(); reject(); }, 5000);
        pc.onicecandidate = ({ candidate }) => {
          if (candidate?.type === test.expectedType) {
            results[test.name] = true;
            clearTimeout(timer);
            pc.close();
            resolve();
          }
        };
        pc.onicegatheringstatechange = () => {
          if (pc.iceGatheringState === 'complete') {
            clearTimeout(timer);
            pc.close();
            resolve();
          }
        };
      });
    } catch { /* test failed */ }
  }

  return results;
}
```

---

## NAT Issues

### NAT Types and WebRTC Compatibility

| NAT Type | Description | Direct P2P | Needs TURN |
|----------|-------------|------------|------------|
| Full Cone | Any external host can send to mapped port | ✅ | Rarely |
| Address-Restricted | Only known IP can send | ✅ | Sometimes |
| Port-Restricted | Only known IP:port can send | Usually ✅ | Sometimes |
| Symmetric | Different mapping per destination | ❌ | Usually |

### Symmetric NAT Detection

```javascript
async function detectSymmetricNAT() {
  const stun1 = { urls: 'stun:stun1.l.google.com:19302' };
  const stun2 = { urls: 'stun:stun2.l.google.com:19302' };

  async function getReflexiveCandidate(stunServer) {
    const pc = new RTCPeerConnection({ iceServers: [stunServer] });
    pc.createDataChannel('nat-test');
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    return new Promise((resolve) => {
      const timer = setTimeout(() => { pc.close(); resolve(null); }, 5000);
      pc.onicecandidate = ({ candidate }) => {
        if (candidate?.type === 'srflx') {
          clearTimeout(timer);
          pc.close();
          resolve({ address: candidate.address, port: candidate.port });
        }
      };
    });
  }

  const [result1, result2] = await Promise.all([
    getReflexiveCandidate(stun1),
    getReflexiveCandidate(stun2)
  ]);

  if (!result1 || !result2) return { type: 'unknown', needsTurn: true };

  if (result1.address === result2.address && result1.port === result2.port) {
    return { type: 'cone', needsTurn: false };
  } else {
    return { type: 'symmetric', needsTurn: true };
  }
}
```

### Double-NAT / Carrier-Grade NAT (CGNAT)

Signs of CGNAT:
- STUN reflexive address is in `100.64.0.0/10` range
- Multiple NAT layers add latency
- Always needs TURN relay

```javascript
function isCGNAT(address) {
  const parts = address.split('.').map(Number);
  return parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}
```

---

## Certificate Errors

### DTLS Certificate Issues

WebRTC uses DTLS for media encryption. Certificate problems manifest as:
- ICE connects but media doesn't flow
- `connectionState` goes to `failed` after `connected`
- OTEL traces show DTLS handshake failures

### Self-Signed Certificate Fingerprint Verification

```javascript
// The SDP contains certificate fingerprints
// a=fingerprint:sha-256 AB:CD:EF:...
// If fingerprints don't match, DTLS fails silently

// Debug: Extract and compare fingerprints
function extractFingerprint(sdp) {
  const match = sdp.match(/a=fingerprint:(\S+)\s+(\S+)/);
  return match ? { algorithm: match[1], hash: match[2] } : null;
}

const localFp = extractFingerprint(pc.localDescription.sdp);
const remoteFp = extractFingerprint(pc.remoteDescription.sdp);
console.log('Local fingerprint:', localFp);
console.log('Remote fingerprint:', remoteFp);
```

### HTTPS Requirement

```
getUserMedia() requires a secure context (HTTPS or localhost).
Symptoms of HTTP usage:
- navigator.mediaDevices is undefined
- getUserMedia throws NotAllowedError
- No ICE candidates generated

Solutions:
- Use localhost for development
- Use self-signed certs (see scripts/generate-certificates.sh)
- Use ngrok/cloudflared for quick HTTPS tunnels
```

---

## getStats() Analysis

### Key Stats Reports

```javascript
async function comprehensiveStatsAnalysis(pc) {
  const stats = await pc.getStats();
  const analysis = {
    connection: {},
    video: { inbound: {}, outbound: {} },
    audio: { inbound: {}, outbound: {} },
    candidates: []
  };

  stats.forEach(report => {
    switch (report.type) {
      case 'candidate-pair':
        if (report.state === 'succeeded' || report.nominated) {
          analysis.connection = {
            rtt: report.currentRoundTripTime,
            availableBandwidth: report.availableOutgoingBitrate,
            bytesSent: report.bytesSent,
            bytesReceived: report.bytesReceived,
            requestsSent: report.requestsSent,
            responsesReceived: report.responsesReceived,
            consentRequestsSent: report.consentRequestsSent,
            state: report.state,
            nominated: report.nominated
          };
        }
        break;

      case 'inbound-rtp':
        analysis[report.kind].inbound = {
          packetsReceived: report.packetsReceived,
          packetsLost: report.packetsLost,
          jitter: report.jitter,
          bytesReceived: report.bytesReceived,
          framesDecoded: report.framesDecoded,
          framesDropped: report.framesDropped,
          frameWidth: report.frameWidth,
          frameHeight: report.frameHeight,
          framesPerSecond: report.framesPerSecond,
          totalDecodeTime: report.totalDecodeTime,
          decoderImplementation: report.decoderImplementation,
          nackCount: report.nackCount,
          pliCount: report.pliCount,
          firCount: report.firCount,
          jitterBufferDelay: report.jitterBufferDelay
        };
        break;

      case 'outbound-rtp':
        analysis[report.kind].outbound = {
          packetsSent: report.packetsSent,
          bytesSent: report.bytesSent,
          targetBitrate: report.targetBitrate,
          framesEncoded: report.framesEncoded,
          frameWidth: report.frameWidth,
          frameHeight: report.frameHeight,
          framesPerSecond: report.framesPerSecond,
          totalEncodeTime: report.totalEncodeTime,
          encoderImplementation: report.encoderImplementation,
          qualityLimitationReason: report.qualityLimitationReason,
          qualityLimitationDurations: report.qualityLimitationDurations,
          nackCount: report.nackCount,
          pliCount: report.pliCount,
          retransmittedBytesSent: report.retransmittedBytesSent,
          retransmittedPacketsSent: report.retransmittedPacketsSent
        };
        break;

      case 'local-candidate':
      case 'remote-candidate':
        analysis.candidates.push({
          side: report.type.replace('-candidate', ''),
          type: report.candidateType,
          protocol: report.protocol,
          address: report.address,
          port: report.port,
          networkType: report.networkType
        });
        break;
    }
  });

  return analysis;
}
```

### Quality Limitation Analysis

```javascript
async function analyzeQualityLimitations(pc) {
  const stats = await pc.getStats();

  stats.forEach(report => {
    if (report.type !== 'outbound-rtp' || report.kind !== 'video') return;

    const reason = report.qualityLimitationReason;
    const durations = report.qualityLimitationDurations;

    console.log(`Current limitation: ${reason}`);
    // 'none' — no limitation
    // 'bandwidth' — network constrained
    // 'cpu' — encoder too slow
    // 'other' — unknown

    if (durations) {
      const total = Object.values(durations).reduce((a, b) => a + b, 0);
      for (const [reason, time] of Object.entries(durations)) {
        console.log(`  ${reason}: ${((time / total) * 100).toFixed(1)}%`);
      }
    }

    if (reason === 'cpu') {
      console.warn('RECOMMENDATION: Lower resolution, switch to hardware encoder, or use a simpler codec');
    } else if (reason === 'bandwidth') {
      console.warn('RECOMMENDATION: Enable simulcast, reduce bitrate, or switch to SVC');
    }
  });
}
```

### Periodic Stats Collection

```javascript
class StatsCollector {
  constructor(pc, intervalMs = 2000) {
    this.pc = pc;
    this.intervalMs = intervalMs;
    this.history = [];
    this.timer = null;
    this.prevStats = null;
  }

  start() {
    this.timer = setInterval(() => this.collect(), this.intervalMs);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
  }

  async collect() {
    const stats = await this.pc.getStats();
    const snapshot = { timestamp: Date.now() };

    stats.forEach(report => {
      if (report.type === 'inbound-rtp' && report.kind === 'video') {
        snapshot.video = {
          packetsLost: report.packetsLost,
          jitter: report.jitter,
          framesPerSecond: report.framesPerSecond,
          framesDropped: report.framesDropped
        };
      }
    });

    this.history.push(snapshot);

    // Detect degradation
    if (this.history.length >= 3) {
      const recent = this.history.slice(-3);
      const avgFps = recent.reduce((s, h) =>
        s + (h.video?.framesPerSecond || 0), 0) / 3;

      if (avgFps < 10 && avgFps > 0) {
        this.onDegradation?.({ type: 'low-fps', avgFps });
      }
    }

    // Keep last 5 minutes
    const cutoff = Date.now() - 5 * 60 * 1000;
    this.history = this.history.filter(h => h.timestamp > cutoff);
  }
}
```

---

## OpenTelemetry (OTEL) Debugging

### Instrumenting WebRTC with OTEL

```javascript
import { trace, context, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('webrtc-client');

async function tracedCreateOffer(pc) {
  return tracer.startActiveSpan('webrtc.createOffer', async (span) => {
    try {
      const offer = await pc.createOffer();
      span.setAttribute('sdp.type', offer.type);
      span.setAttribute('sdp.length', offer.sdp.length);
      span.setStatus({ code: SpanStatusCode.OK });
      return offer;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
    } finally {
      span.end();
    }
  });
}

async function tracedSetRemoteDescription(pc, desc) {
  return tracer.startActiveSpan('webrtc.setRemoteDescription', async (span) => {
    span.setAttribute('sdp.type', desc.type);
    try {
      await pc.setRemoteDescription(desc);
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
    } finally {
      span.end();
    }
  });
}
```

### OTEL Metrics for WebRTC

```javascript
import { metrics } from '@opentelemetry/api';

const meter = metrics.getMeter('webrtc-client');

const rttHistogram = meter.createHistogram('webrtc.rtt', {
  description: 'Round-trip time in seconds',
  unit: 's'
});

const packetLossCounter = meter.createCounter('webrtc.packets_lost', {
  description: 'Total packets lost'
});

const bitrateGauge = meter.createObservableGauge('webrtc.bitrate', {
  description: 'Current video bitrate'
});

// Report metrics from getStats()
async function reportMetrics(pc) {
  const stats = await pc.getStats();
  stats.forEach(report => {
    if (report.type === 'candidate-pair' && report.state === 'succeeded') {
      rttHistogram.record(report.currentRoundTripTime || 0);
    }
    if (report.type === 'inbound-rtp') {
      packetLossCounter.add(report.packetsLost || 0, { kind: report.kind });
    }
  });
}
```

### Server-Side OTEL for SFU

```javascript
// mediasoup OTEL instrumentation
const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');

const provider = new NodeTracerProvider();
provider.addSpanProcessor(
  new BatchSpanProcessor(new OTLPTraceExporter({ url: 'http://otel-collector:4318/v1/traces' }))
);
provider.register();

const tracer = trace.getTracer('mediasoup-sfu');

// Trace transport creation
async function createTracedTransport(router, options) {
  return tracer.startActiveSpan('sfu.createTransport', async (span) => {
    const transport = await router.createWebRtcTransport(options);
    span.setAttribute('transport.id', transport.id);
    span.setAttribute('transport.protocol', 'webrtc');

    transport.on('dtlsstatechange', (state) => {
      span.addEvent('dtls_state_change', { state });
      if (state === 'failed') {
        span.setStatus({ code: SpanStatusCode.ERROR, message: 'DTLS failed' });
      }
    });

    transport.on('icestatechange', (state) => {
      span.addEvent('ice_state_change', { state });
    });

    span.end();
    return transport;
  });
}
```

---

## Browser Quirks: Safari

### Codec Issues

```javascript
// Safari has limited VP9 support (decoder only, no encoder until Safari 17)
// Safari prefers H.264 with specific profiles
function getSafariSafeCodecPreferences(pc) {
  if (adapter.browserDetails.browser !== 'safari') return;

  const transceiver = pc.getTransceivers().find(t =>
    t.receiver.track?.kind === 'video' || t.sender.track?.kind === 'video'
  );
  if (!transceiver) return;

  const codecs = RTCRtpReceiver.getCapabilities('video')?.codecs || [];

  // Safari works best with Baseline H.264
  const h264Baseline = codecs.filter(c =>
    c.mimeType === 'video/H264' &&
    c.sdpFmtpLine?.includes('profile-level-id=42e0')
  );
  const rest = codecs.filter(c =>
    !h264Baseline.includes(c)
  );

  if (h264Baseline.length > 0) {
    transceiver.setCodecPreferences([...h264Baseline, ...rest]);
  }
}
```

### Safari-Specific Issues Checklist

| Issue | Symptom | Workaround |
|-------|---------|------------|
| No VP9 encoding | Black video when VP9 forced | Fall back to H.264 |
| Audio autoplay | Audio doesn't start | `audioElement.play()` on user gesture |
| getDisplayMedia | Not supported on iOS | No workaround on iOS Safari |
| Unified Plan | Older Safari uses Plan B | Use adapter.js |
| addTransceiver | Limited support in older versions | Use addTrack instead |
| Canvas capture | Poor performance | Use lower resolution |
| Simulcast | Limited before Safari 17 | Fall back to single encoding |
| DataChannel | Binary transfer issues | Use ArrayBuffer, not Blob |

### Safari Audio Fix

```javascript
// Safari requires user interaction to start audio playback
document.addEventListener('click', () => {
  const audio = document.querySelector('audio#remote');
  if (audio && audio.paused) {
    audio.play().catch(console.warn);
  }
}, { once: true });

// For programmatic audio context
const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
if (audioCtx.state === 'suspended') {
  document.addEventListener('click', () => audioCtx.resume(), { once: true });
}
```

---

## Browser Quirks: Firefox

### Plan B vs Unified Plan

```javascript
// Firefox always uses Unified Plan (SDP format)
// Chrome migrated from Plan B to Unified Plan in M93+
// adapter.js handles the transition

// Detect SDP format
function detectSDPFormat(sdp) {
  // Unified Plan: multiple m= sections, one per track
  // Plan B: single m=video with multiple SSRCs
  const mLines = (sdp.match(/^m=/gm) || []).length;
  const ssrcGroups = (sdp.match(/^a=ssrc-group/gm) || []).length;

  if (mLines > 2 || sdp.includes('a=mid:')) {
    return 'unified-plan';
  }
  if (ssrcGroups > 0 && mLines <= 2) {
    return 'plan-b';
  }
  return 'unknown';
}
```

### Firefox-Specific Issues

| Issue | Symptom | Workaround |
|-------|---------|------------|
| TURN/TCP | May not work with some TURN servers | Use UDP or TURNS |
| getStats() format | Different stat names | Use adapter.js |
| replaceTrack timing | May trigger renegotiation | Check signaling state first |
| screen share audio | Not supported | Use separate audio stream |
| H.264 profiles | Limited hardware decode support | Use VP8/VP9 |
| RTCRtpSender.getCapabilities | May return incomplete | Feature detect first |

### Firefox Stats Normalization

```javascript
// Firefox may use different stat field names
function normalizeStats(report) {
  // Firefox uses 'framerateMean' instead of 'framesPerSecond' in older versions
  if (report.framerateMean !== undefined && report.framesPerSecond === undefined) {
    report.framesPerSecond = report.framerateMean;
  }

  // Firefox may report bitrate differently
  if (report.bitrateMean !== undefined && report.targetBitrate === undefined) {
    report.targetBitrate = report.bitrateMean;
  }

  return report;
}
```

---

## Browser Quirks: Chrome/Edge

### Chrome-Specific Considerations

| Issue | Details |
|-------|---------|
| Tab capture audio | `getDisplayMedia({audio: true})` captures system audio on Chrome only |
| Hardware encoding | Check `encoderImplementation` in stats — 'ExternalEncoder' = HW |
| Unified Plan | Default since M93, Plan B removed in M117 |
| getStats() deprecation | `callback`-based getStats() removed — use Promise version |
| `chrome://webrtc-internals` | Powerful debug tool — use for all diagnostics |
| Screen share with audio | Tab audio capture supported, window audio is not |

### Using chrome://webrtc-internals

```
1. Open chrome://webrtc-internals in a new tab
2. Key sections:
   - getUserMedia Requests: Shows constraints and results
   - RTCPeerConnection: One per connection
   - Stats Tables: Live updating getStats() data
   - Stats Graphs: Visual bitrate, framerate, packet loss
3. Export: Download the dump as JSON for offline analysis
4. Look for:
   - 'iceConnectionState' transitions
   - 'dtlsState' changes
   - 'qualityLimitationReason' values
   - Packet loss spikes in graphs
```

---

## Common Failure Patterns

### Pattern 1: "No Audio/Video but Connection Succeeds"

```
Symptoms:
  - ICE state: connected/completed
  - Remote video element is black
  - No audio output

Checklist:
  ✓ Is remote stream attached to <video> element?
  ✓ Is <video> element set to autoplay and not muted?
  ✓ Are tracks enabled? (track.enabled === true)
  ✓ Is srcObject set? (not src with blob URL)
  ✓ Safari: Did user interact with page?
  ✓ Are codecs compatible between peers?
```

```javascript
// Debug: check track states
function debugTracks(pc) {
  console.log('Senders:');
  pc.getSenders().forEach(s => {
    console.log(`  ${s.track?.kind}: enabled=${s.track?.enabled}, readyState=${s.track?.readyState}`);
  });
  console.log('Receivers:');
  pc.getReceivers().forEach(r => {
    console.log(`  ${r.track?.kind}: enabled=${r.track?.enabled}, readyState=${r.track?.readyState}`);
  });
}
```

### Pattern 2: "Works Locally but Fails in Production"

```
Common causes:
  1. Missing TURN server (direct P2P blocked by NAT/firewall)
  2. HTTP instead of HTTPS (getUserMedia requires secure context)
  3. WSS not configured (WebSocket over TLS needed in production)
  4. CORS issues on signaling server
  5. TURN credentials expired
  6. DNS resolution failure for TURN server
```

### Pattern 3: "Connection Drops After ~30 Seconds"

```
Likely causes:
  1. TURN server consent freshness failure (ICE consent checks every 30s)
  2. Firewall closing idle UDP connections
  3. NAT binding timeout (symmetric NAT)
  4. Keep-alive not configured on TURN server

Fix:
  - Configure TURN server keep-alive
  - Set NAT binding timeout > 30s
  - Use TCP/TLS as fallback
```

### Pattern 4: "One-Way Audio/Video"

```
Symptoms:
  - One peer sees/hears the other but not vice versa
  - Asymmetric connection

Causes:
  1. addTrack called only on one side
  2. One peer behind symmetric NAT without TURN
  3. Firewall allows outbound UDP but blocks inbound
  4. SDP answer missing media section

Debug:
  - Check both peers' ontrack events fired
  - Compare candidate types (should both have relay if needed)
  - Verify SDP answer contains matching m= lines
```

---

## Debugging Tools and Techniques

### Browser-Specific Debug Pages

| Browser | URL | Features |
|---------|-----|----------|
| Chrome | `chrome://webrtc-internals` | Full stats, graphs, event log |
| Firefox | `about:webrtc` | ICE stats, SDP viewer |
| Safari | Develop menu → WebRTC | Basic logging |
| Edge | `edge://webrtc-internals` | Same as Chrome |

### Programmatic Debug Logger

```javascript
class WebRTCDebugLogger {
  constructor(pc, label = 'pc') {
    this.label = label;
    this.logs = [];

    const events = [
      'iceconnectionstatechange', 'icegatheringstatechange',
      'connectionstatechange', 'signalingstatechange',
      'negotiationneeded', 'icecandidate', 'track', 'datachannel'
    ];

    events.forEach(event => {
      pc.addEventListener(event, (e) => {
        const entry = {
          time: new Date().toISOString(),
          event,
          detail: this.extractDetail(pc, event, e)
        };
        this.logs.push(entry);
        console.log(`[${this.label}] ${event}:`, entry.detail);
      });
    });
  }

  extractDetail(pc, event, e) {
    switch (event) {
      case 'iceconnectionstatechange': return pc.iceConnectionState;
      case 'icegatheringstatechange': return pc.iceGatheringState;
      case 'connectionstatechange': return pc.connectionState;
      case 'signalingstatechange': return pc.signalingState;
      case 'icecandidate': return e.candidate ? {
        type: e.candidate.type,
        protocol: e.candidate.protocol,
        address: e.candidate.address
      } : 'gathering-complete';
      case 'track': return { kind: e.track.kind, id: e.track.id };
      default: return {};
    }
  }

  export() {
    return JSON.stringify(this.logs, null, 2);
  }
}

// Usage
const logger = new WebRTCDebugLogger(pc, 'main-call');
// Later: download logger.export() for analysis
```

### SDP Diff Tool

```javascript
function diffSDP(sdp1, sdp2) {
  const lines1 = sdp1.split('\r\n');
  const lines2 = sdp2.split('\r\n');

  const added = lines2.filter(l => !lines1.includes(l));
  const removed = lines1.filter(l => !lines2.includes(l));

  return { added, removed };
}

// Usage: compare offer vs answer, or before/after renegotiation
const { added, removed } = diffSDP(offer.sdp, answer.sdp);
console.log('Added in answer:', added);
console.log('Removed from offer:', removed);
```
