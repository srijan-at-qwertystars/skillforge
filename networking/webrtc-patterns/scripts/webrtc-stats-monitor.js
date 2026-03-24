#!/usr/bin/env node
//
// webrtc-stats-monitor.js — Parse and display WebRTC getStats() output
//
// Usage:
//   chmod +x webrtc-stats-monitor.js
//   node webrtc-stats-monitor.js [options]
//
//   Modes:
//     --file <path>     Parse a JSON stats dump (from chrome://webrtc-internals export)
//     --listen <port>   Start HTTP server to receive live stats POSTs (default: 9090)
//     --interval <ms>   Stats display refresh interval in ms (default: 2000)
//
// Examples:
//   node webrtc-stats-monitor.js --file stats-dump.json
//   node webrtc-stats-monitor.js --listen 9090
//
//   # From browser, POST stats periodically:
//   #   const stats = await pc.getStats();
//   #   const data = [];
//   #   stats.forEach(r => data.push(r));
//   #   fetch('http://localhost:9090/stats', {
//   #     method: 'POST',
//   #     headers: { 'Content-Type': 'application/json' },
//   #     body: JSON.stringify(data)
//   #   });
//

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

// --- Argument Parsing ---
const args = process.argv.slice(2);
let mode = 'listen';
let filePath = null;
let listenPort = 9090;
let intervalMs = 2000;

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--file':     mode = 'file'; filePath = args[++i]; break;
    case '--listen':   mode = 'listen'; listenPort = parseInt(args[++i]) || 9090; break;
    case '--interval': intervalMs = parseInt(args[++i]) || 2000; break;
    case '--help':
      console.log(`
webrtc-stats-monitor.js — Parse and display WebRTC getStats() output

Usage:
  node webrtc-stats-monitor.js --file <path>      Parse a JSON stats dump
  node webrtc-stats-monitor.js --listen <port>     Receive live stats (default: 9090)

Options:
  --file <path>       JSON file exported from chrome://webrtc-internals
  --listen <port>     HTTP server port for live stats (default: 9090)
  --interval <ms>     Refresh interval in ms (default: 2000)
  --help              Show this help
`);
      process.exit(0);
  }
}

// --- Stats Analysis ---
function analyzeStats(reports) {
  const result = {
    timestamp: new Date().toISOString(),
    connection: null,
    video: { inbound: null, outbound: null },
    audio: { inbound: null, outbound: null },
    candidates: { local: [], remote: [], selectedPair: null },
    warnings: []
  };

  for (const report of reports) {
    switch (report.type) {
      case 'candidate-pair':
        if (report.state === 'succeeded' || report.nominated) {
          result.connection = {
            state: report.state,
            rttMs: ((report.currentRoundTripTime || 0) * 1000).toFixed(1),
            availableBitrate: formatBitrate(report.availableOutgoingBitrate),
            bytesSent: formatBytes(report.bytesSent),
            bytesReceived: formatBytes(report.bytesReceived),
            requestsSent: report.requestsSent,
            responsesReceived: report.responsesReceived
          };
          result.candidates.selectedPair = {
            localCandidateId: report.localCandidateId,
            remoteCandidateId: report.remoteCandidateId
          };
        }
        break;

      case 'inbound-rtp': {
        const stats = {
          packetsReceived: report.packetsReceived || 0,
          packetsLost: report.packetsLost || 0,
          lossRate: report.packetsReceived > 0
            ? ((report.packetsLost / (report.packetsReceived + report.packetsLost)) * 100).toFixed(2) + '%'
            : '0%',
          jitterMs: ((report.jitter || 0) * 1000).toFixed(1),
          bytesReceived: formatBytes(report.bytesReceived),
          codec: report.codecId
        };

        if (report.kind === 'video') {
          stats.resolution = `${report.frameWidth || '?'}x${report.frameHeight || '?'}`;
          stats.fps = report.framesPerSecond || 0;
          stats.framesDecoded = report.framesDecoded || 0;
          stats.framesDropped = report.framesDropped || 0;
          stats.decoder = report.decoderImplementation || 'unknown';
          stats.nackCount = report.nackCount || 0;
          stats.pliCount = report.pliCount || 0;

          if (report.framesDropped > 0 && report.framesDecoded > 0) {
            const dropRate = report.framesDropped / (report.framesDecoded + report.framesDropped);
            if (dropRate > 0.05) {
              result.warnings.push(`High frame drop rate: ${(dropRate * 100).toFixed(1)}%`);
            }
          }
          result.video.inbound = stats;
        } else {
          stats.audioLevel = report.audioLevel;
          result.audio.inbound = stats;
        }
        break;
      }

      case 'outbound-rtp': {
        const stats = {
          packetsSent: report.packetsSent || 0,
          bytesSent: formatBytes(report.bytesSent),
          targetBitrate: formatBitrate(report.targetBitrate),
          retransmittedBytes: formatBytes(report.retransmittedBytesSent),
          nackCount: report.nackCount || 0,
          codec: report.codecId
        };

        if (report.kind === 'video') {
          stats.resolution = `${report.frameWidth || '?'}x${report.frameHeight || '?'}`;
          stats.fps = report.framesPerSecond || 0;
          stats.framesEncoded = report.framesEncoded || 0;
          stats.encoder = report.encoderImplementation || 'unknown';
          stats.qualityLimitation = report.qualityLimitationReason || 'none';
          stats.pliCount = report.pliCount || 0;

          if (report.qualityLimitationReason && report.qualityLimitationReason !== 'none') {
            result.warnings.push(`Quality limited by: ${report.qualityLimitationReason}`);
          }

          if (report.qualityLimitationDurations) {
            stats.limitationDurations = report.qualityLimitationDurations;
          }
          result.video.outbound = stats;
        } else {
          result.audio.outbound = stats;
        }
        break;
      }

      case 'local-candidate':
        result.candidates.local.push({
          id: report.id,
          type: report.candidateType,
          protocol: report.protocol,
          address: report.address,
          port: report.port,
          networkType: report.networkType
        });
        break;

      case 'remote-candidate':
        result.candidates.remote.push({
          id: report.id,
          type: report.candidateType,
          protocol: report.protocol,
          address: report.address,
          port: report.port
        });
        break;
    }
  }

  // Generate warnings for common issues
  if (result.connection) {
    const rtt = parseFloat(result.connection.rttMs);
    if (rtt > 300) result.warnings.push(`High RTT: ${rtt}ms`);
    if (rtt > 1000) result.warnings.push(`CRITICAL: RTT > 1s — call quality severely impacted`);
  }

  if (result.video.inbound) {
    const loss = parseFloat(result.video.inbound.lossRate);
    if (loss > 5) result.warnings.push(`High video packet loss: ${loss}%`);
    if (result.video.inbound.fps < 10 && result.video.inbound.fps > 0) {
      result.warnings.push(`Low incoming FPS: ${result.video.inbound.fps}`);
    }
  }

  if (result.audio.inbound) {
    const loss = parseFloat(result.audio.inbound.lossRate);
    if (loss > 3) result.warnings.push(`Audio packet loss: ${loss}%`);
  }

  return result;
}

// --- Display ---
function displayStats(analysis) {
  console.clear();
  console.log('╔══════════════════════════════════════════════════════════════╗');
  console.log('║              WebRTC Stats Monitor                           ║');
  console.log('╚══════════════════════════════════════════════════════════════╝');
  console.log(`  Timestamp: ${analysis.timestamp}\n`);

  if (analysis.connection) {
    console.log('┌─ Connection ────────────────────────────────────────────────┐');
    const c = analysis.connection;
    console.log(`│  RTT: ${c.rttMs}ms  |  Bandwidth: ${c.availableBitrate}`);
    console.log(`│  Sent: ${c.bytesSent}  |  Received: ${c.bytesReceived}`);
    console.log('└─────────────────────────────────────────────────────────────┘');
  }

  if (analysis.video.inbound || analysis.video.outbound) {
    console.log('\n┌─ Video ──────────────────────────────────────────────────────┐');
    if (analysis.video.outbound) {
      const v = analysis.video.outbound;
      console.log(`│  ↑ OUT: ${v.resolution} @ ${v.fps}fps | ${v.targetBitrate} | ${v.encoder}`);
      console.log(`│         ${v.framesEncoded} frames | Quality: ${v.qualityLimitation}`);
    }
    if (analysis.video.inbound) {
      const v = analysis.video.inbound;
      console.log(`│  ↓ IN:  ${v.resolution} @ ${v.fps}fps | Loss: ${v.lossRate} | ${v.decoder}`);
      console.log(`│         ${v.framesDecoded} decoded, ${v.framesDropped} dropped | Jitter: ${v.jitterMs}ms`);
    }
    console.log('└──────────────────────────────────────────────────────────────┘');
  }

  if (analysis.audio.inbound || analysis.audio.outbound) {
    console.log('\n┌─ Audio ──────────────────────────────────────────────────────┐');
    if (analysis.audio.outbound) {
      const a = analysis.audio.outbound;
      console.log(`│  ↑ OUT: ${a.packetsSent} packets | ${a.bytesSent}`);
    }
    if (analysis.audio.inbound) {
      const a = analysis.audio.inbound;
      console.log(`│  ↓ IN:  Loss: ${a.lossRate} | Jitter: ${a.jitterMs}ms | ${a.packetsReceived} packets`);
    }
    console.log('└──────────────────────────────────────────────────────────────┘');
  }

  if (analysis.candidates.selectedPair) {
    console.log('\n┌─ ICE Candidates ─────────────────────────────────────────────┐');
    const local = analysis.candidates.local.find(
      c => c.id === analysis.candidates.selectedPair.localCandidateId
    );
    const remote = analysis.candidates.remote.find(
      c => c.id === analysis.candidates.selectedPair.remoteCandidateId
    );
    if (local) {
      console.log(`│  Local:  ${local.type} ${local.protocol} ${local.address}:${local.port} (${local.networkType || 'unknown'})`);
    }
    if (remote) {
      console.log(`│  Remote: ${remote.type} ${remote.protocol} ${remote.address}:${remote.port}`);
    }
    console.log(`│  Total candidates: ${analysis.candidates.local.length} local, ${analysis.candidates.remote.length} remote`);
    console.log('└──────────────────────────────────────────────────────────────┘');
  }

  if (analysis.warnings.length > 0) {
    console.log('\n┌─ ⚠ Warnings ─────────────────────────────────────────────────┐');
    for (const w of analysis.warnings) {
      console.log(`│  ⚠ ${w}`);
    }
    console.log('└──────────────────────────────────────────────────────────────┘');
  }
}

// --- Utilities ---
function formatBitrate(bps) {
  if (!bps) return 'N/A';
  if (bps > 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`;
  if (bps > 1_000) return `${(bps / 1_000).toFixed(0)} kbps`;
  return `${bps} bps`;
}

function formatBytes(bytes) {
  if (!bytes) return '0 B';
  if (bytes > 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
  if (bytes > 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  if (bytes > 1_000) return `${(bytes / 1_000).toFixed(1)} KB`;
  return `${bytes} B`;
}

// --- Main ---
if (mode === 'file') {
  if (!filePath) {
    console.error('Error: --file requires a path argument');
    process.exit(1);
  }

  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const data = JSON.parse(raw);

    // Handle both array-of-reports and chrome://webrtc-internals format
    let reports;
    if (Array.isArray(data)) {
      reports = data;
    } else if (data.PeerConnections) {
      // chrome://webrtc-internals dump format
      const pcId = Object.keys(data.PeerConnections)[0];
      const pcData = data.PeerConnections[pcId];
      reports = pcData?.stats ? Object.values(pcData.stats).map(s => s.values?.[s.values.length - 1] || s) : [];
      console.log(`Parsed chrome://webrtc-internals dump for PC: ${pcId}`);
    } else {
      reports = Object.values(data);
    }

    const analysis = analyzeStats(reports);
    displayStats(analysis);

    // Also output raw JSON analysis
    console.log('\n--- Raw Analysis (JSON) ---');
    console.log(JSON.stringify(analysis, null, 2));
  } catch (err) {
    console.error(`Error reading file: ${err.message}`);
    process.exit(1);
  }
} else {
  // Live stats server mode
  console.log(`WebRTC Stats Monitor listening on http://localhost:${listenPort}`);
  console.log(`POST stats to http://localhost:${listenPort}/stats`);
  console.log('');

  const server = http.createServer((req, res) => {
    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    if (req.method === 'POST' && req.url === '/stats') {
      let body = '';
      req.on('data', chunk => { body += chunk; });
      req.on('end', () => {
        try {
          const reports = JSON.parse(body);
          const analysis = analyzeStats(Array.isArray(reports) ? reports : [reports]);
          displayStats(analysis);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ status: 'ok', warnings: analysis.warnings }));
        } catch (err) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: err.message }));
        }
      });
    } else if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
    } else {
      res.writeHead(404);
      res.end('Not found. POST stats to /stats');
    }
  });

  server.listen(listenPort);
}
