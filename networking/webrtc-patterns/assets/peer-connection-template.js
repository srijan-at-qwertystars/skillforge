/**
 * peer-connection-template.js — Copy-paste RTCPeerConnection setup with error handling
 *
 * A comprehensive, production-ready RTCPeerConnection wrapper with:
 *   - ICE server configuration
 *   - Automatic ICE restart on failure
 *   - Candidate queueing (handles candidates arriving before remote description)
 *   - Connection state monitoring
 *   - Media track management
 *   - Stats collection
 *   - Event-driven architecture
 *
 * Usage:
 *   import { PeerConnectionManager } from './peer-connection-template.js';
 *
 *   const manager = new PeerConnectionManager({
 *     iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
 *     onIceCandidate: (candidate) => signaling.send({ type: 'candidate', candidate }),
 *     onTrack: (event) => { remoteVideo.srcObject = event.streams[0]; },
 *     onConnectionStateChange: (state) => console.log('State:', state),
 *     onError: (error) => console.error('Error:', error)
 *   });
 *
 *   // Caller
 *   await manager.addLocalStream(localStream);
 *   const offer = await manager.createOffer();
 *   signaling.send({ type: 'offer', sdp: offer });
 *
 *   // Callee
 *   await manager.addLocalStream(localStream);
 *   const answer = await manager.handleOffer(remoteSdp);
 *   signaling.send({ type: 'answer', sdp: answer });
 */

'use strict';

class PeerConnectionManager {
  /**
   * @param {Object} options
   * @param {RTCIceServer[]} options.iceServers - ICE server configuration
   * @param {Function} options.onIceCandidate - Called with each ICE candidate
   * @param {Function} options.onTrack - Called when remote track is received
   * @param {Function} [options.onConnectionStateChange] - Called on state changes
   * @param {Function} [options.onError] - Called on errors
   * @param {Function} [options.onNegotiationNeeded] - Called when renegotiation is needed
   * @param {Function} [options.onDataChannel] - Called when remote data channel opens
   * @param {string} [options.iceTransportPolicy='all'] - 'all' or 'relay'
   * @param {number} [options.iceCandidatePoolSize=5] - Pre-gathered candidates
   * @param {number} [options.maxRestarts=5] - Maximum ICE restart attempts
   * @param {number} [options.restartDelayMs=3000] - Delay before ICE restart
   */
  constructor(options) {
    this.options = {
      iceTransportPolicy: 'all',
      iceCandidatePoolSize: 5,
      maxRestarts: 5,
      restartDelayMs: 3000,
      ...options
    };

    this.pc = null;
    this.candidateQueue = [];
    this.restartCount = 0;
    this.restartTimer = null;
    this.closed = false;
    this.localStream = null;
    this.statsInterval = null;

    this._createPeerConnection();
  }

  _createPeerConnection() {
    const config = {
      iceServers: this.options.iceServers || [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' }
      ],
      iceTransportPolicy: this.options.iceTransportPolicy,
      bundlePolicy: 'max-bundle',
      rtcpMuxPolicy: 'require',
      iceCandidatePoolSize: this.options.iceCandidatePoolSize
    };

    this.pc = new RTCPeerConnection(config);

    // --- ICE Candidate Handling ---
    this.pc.onicecandidate = ({ candidate }) => {
      if (candidate && this.options.onIceCandidate) {
        this.options.onIceCandidate(candidate);
      }
    };

    // --- Connection State ---
    this.pc.oniceconnectionstatechange = () => {
      const state = this.pc.iceConnectionState;

      this.options.onConnectionStateChange?.(state);

      switch (state) {
        case 'connected':
        case 'completed':
          this.restartCount = 0; // reset on successful connection
          break;
        case 'disconnected':
          this._scheduleRestart();
          break;
        case 'failed':
          this._scheduleRestart();
          break;
        case 'closed':
          this._cleanup();
          break;
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc.connectionState;
      if (state === 'failed') {
        this.options.onError?.(new Error('Connection failed'));
        this._scheduleRestart();
      }
    };

    this.pc.onicegatheringstatechange = () => {
      // Useful for debugging
    };

    // --- Remote Tracks ---
    this.pc.ontrack = (event) => {
      this.options.onTrack?.(event);
    };

    // --- Negotiation ---
    this.pc.onnegotiationneeded = () => {
      this.options.onNegotiationNeeded?.();
    };

    // --- Data Channels ---
    this.pc.ondatachannel = (event) => {
      this.options.onDataChannel?.(event.channel);
    };
  }

  // --- Offer/Answer ---

  /**
   * Create and set local offer
   * @param {RTCOfferOptions} [offerOptions]
   * @returns {Promise<RTCSessionDescriptionInit>}
   */
  async createOffer(offerOptions = {}) {
    try {
      const offer = await this.pc.createOffer({
        offerToReceiveAudio: true,
        offerToReceiveVideo: true,
        ...offerOptions
      });
      await this.pc.setLocalDescription(offer);
      return this.pc.localDescription;
    } catch (err) {
      this.options.onError?.(new Error(`createOffer failed: ${err.message}`));
      throw err;
    }
  }

  /**
   * Handle incoming offer and return answer
   * @param {RTCSessionDescriptionInit} offer
   * @returns {Promise<RTCSessionDescriptionInit>}
   */
  async handleOffer(offer) {
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription(offer));
      await this._drainCandidateQueue();

      const answer = await this.pc.createAnswer();
      await this.pc.setLocalDescription(answer);
      return this.pc.localDescription;
    } catch (err) {
      this.options.onError?.(new Error(`handleOffer failed: ${err.message}`));
      throw err;
    }
  }

  /**
   * Handle incoming answer
   * @param {RTCSessionDescriptionInit} answer
   */
  async handleAnswer(answer) {
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription(answer));
      await this._drainCandidateQueue();
    } catch (err) {
      this.options.onError?.(new Error(`handleAnswer failed: ${err.message}`));
      throw err;
    }
  }

  // --- ICE Candidates ---

  /**
   * Add a remote ICE candidate (queues if remote description not yet set)
   * @param {RTCIceCandidateInit} candidate
   */
  async addIceCandidate(candidate) {
    try {
      if (this.pc.remoteDescription) {
        await this.pc.addIceCandidate(new RTCIceCandidate(candidate));
      } else {
        this.candidateQueue.push(candidate);
      }
    } catch (err) {
      // Non-fatal: candidate may be for a removed m-line
      if (!err.message.includes('not found')) {
        this.options.onError?.(new Error(`addIceCandidate failed: ${err.message}`));
      }
    }
  }

  async _drainCandidateQueue() {
    for (const candidate of this.candidateQueue) {
      try {
        await this.pc.addIceCandidate(new RTCIceCandidate(candidate));
      } catch (err) {
        // Skip invalid candidates
      }
    }
    this.candidateQueue = [];
  }

  // --- ICE Restart ---

  _scheduleRestart() {
    if (this.closed) return;
    if (this.restartTimer) return;
    if (this.restartCount >= this.options.maxRestarts) {
      this.options.onError?.(new Error('Max ICE restarts exceeded'));
      return;
    }

    const delay = Math.min(
      this.options.restartDelayMs * Math.pow(2, this.restartCount),
      30000
    );

    this.restartTimer = setTimeout(async () => {
      this.restartTimer = null;

      if (this.closed) return;
      if (['connected', 'completed'].includes(this.pc.iceConnectionState)) return;

      this.restartCount++;

      try {
        const offer = await this.pc.createOffer({ iceRestart: true });
        await this.pc.setLocalDescription(offer);
        this.options.onIceCandidate?.(null); // signal restart
        this.options.onNegotiationNeeded?.();
      } catch (err) {
        this.options.onError?.(new Error(`ICE restart failed: ${err.message}`));
      }
    }, delay);
  }

  // --- Media ---

  /**
   * Add a local media stream
   * @param {MediaStream} stream
   */
  async addLocalStream(stream) {
    this.localStream = stream;
    stream.getTracks().forEach(track => {
      this.pc.addTrack(track, stream);
    });
  }

  /**
   * Replace a track (e.g., switch camera) without renegotiation
   * @param {string} kind - 'audio' or 'video'
   * @param {MediaStreamTrack} newTrack
   */
  async replaceTrack(kind, newTrack) {
    const sender = this.pc.getSenders().find(s => s.track?.kind === kind);
    if (!sender) {
      throw new Error(`No ${kind} sender found`);
    }
    await sender.replaceTrack(newTrack);
  }

  /**
   * Mute/unmute a local track
   * @param {string} kind - 'audio' or 'video'
   * @param {boolean} enabled
   */
  setTrackEnabled(kind, enabled) {
    const sender = this.pc.getSenders().find(s => s.track?.kind === kind);
    if (sender?.track) {
      sender.track.enabled = enabled;
    }
  }

  // --- Data Channels ---

  /**
   * Create a data channel
   * @param {string} label
   * @param {RTCDataChannelInit} [options]
   * @returns {RTCDataChannel}
   */
  createDataChannel(label, options = {}) {
    return this.pc.createDataChannel(label, {
      ordered: true,
      ...options
    });
  }

  // --- Stats ---

  /**
   * Get connection stats summary
   * @returns {Promise<Object>}
   */
  async getStats() {
    const stats = await this.pc.getStats();
    const summary = {
      connection: null,
      video: { inbound: null, outbound: null },
      audio: { inbound: null, outbound: null }
    };

    stats.forEach(report => {
      if (report.type === 'candidate-pair' && (report.state === 'succeeded' || report.nominated)) {
        summary.connection = {
          rttMs: (report.currentRoundTripTime || 0) * 1000,
          availableBitrate: report.availableOutgoingBitrate
        };
      }
      if (report.type === 'inbound-rtp') {
        summary[report.kind].inbound = {
          packetsLost: report.packetsLost,
          jitter: report.jitter,
          framesPerSecond: report.framesPerSecond,
          resolution: report.kind === 'video' ? `${report.frameWidth}x${report.frameHeight}` : null
        };
      }
      if (report.type === 'outbound-rtp') {
        summary[report.kind].outbound = {
          targetBitrate: report.targetBitrate,
          qualityLimitation: report.qualityLimitationReason,
          resolution: report.kind === 'video' ? `${report.frameWidth}x${report.frameHeight}` : null
        };
      }
    });

    return summary;
  }

  /**
   * Start periodic stats monitoring
   * @param {Function} callback - Called with stats summary
   * @param {number} [intervalMs=2000]
   */
  startStatsMonitoring(callback, intervalMs = 2000) {
    this.stopStatsMonitoring();
    this.statsInterval = setInterval(async () => {
      try {
        const stats = await this.getStats();
        callback(stats);
      } catch {
        // Connection may be closed
      }
    }, intervalMs);
  }

  stopStatsMonitoring() {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
      this.statsInterval = null;
    }
  }

  // --- Lifecycle ---

  /**
   * Get the current connection state
   */
  get connectionState() {
    return this.pc?.connectionState || 'closed';
  }

  get iceConnectionState() {
    return this.pc?.iceConnectionState || 'closed';
  }

  get signalingState() {
    return this.pc?.signalingState || 'closed';
  }

  /**
   * Close the peer connection and clean up
   */
  close() {
    this.closed = true;
    this._cleanup();

    if (this.pc) {
      this.pc.getSenders().forEach(sender => {
        if (sender.track) sender.track.stop();
      });
      this.pc.close();
      this.pc = null;
    }
  }

  _cleanup() {
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    this.stopStatsMonitoring();
    this.candidateQueue = [];
  }
}

// --- Export ---
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { PeerConnectionManager };
}

// For ES modules:
// export { PeerConnectionManager };
