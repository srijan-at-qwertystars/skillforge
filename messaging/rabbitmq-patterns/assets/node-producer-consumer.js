/**
 * RabbitMQ Producer/Consumer with channel pooling and error handling.
 *
 * Requirements: npm install amqplib uuid
 *
 * Usage:
 *   node node-producer-consumer.js produce --count 100
 *   node node-producer-consumer.js consume --queue orders.processing
 */

'use strict';

const amqplib = require('amqplib');
const { randomUUID } = require('crypto');
const { EventEmitter } = require('events');

// ─── Configuration ───

const CONFIG = {
  url: process.env.RABBITMQ_URL || 'amqp://admin:changeme@localhost:5672/production',
  exchange: 'orders',
  exchangeType: 'topic',
  queue: 'orders.processing',
  routingKey: 'order.created',
  dlxExchange: 'dlx',
  dlqQueue: 'orders.dead-letters',
  prefetch: 10,
  reconnectDelay: 5000,
  maxReconnectAttempts: 50,
  channelPoolSize: 5,
  publishTimeout: 10000,
};

// ─── Connection Manager ───

class ConnectionManager extends EventEmitter {
  constructor(url, options = {}) {
    super();
    this.url = url;
    this.reconnectDelay = options.reconnectDelay || 5000;
    this.maxAttempts = options.maxReconnectAttempts || 50;
    this.connection = null;
    this._closing = false;
    this._reconnectAttempt = 0;
  }

  async connect() {
    if (this.connection) return this.connection;

    try {
      this.connection = await amqplib.connect(this.url, {
        heartbeat: 60,
        channelMax: 2047,
      });

      this._reconnectAttempt = 0;
      console.log('[ConnectionManager] Connected to RabbitMQ');

      this.connection.on('error', (err) => {
        console.error('[ConnectionManager] Connection error:', err.message);
      });

      this.connection.on('close', () => {
        console.warn('[ConnectionManager] Connection closed');
        this.connection = null;
        if (!this._closing) {
          this._scheduleReconnect();
        }
      });

      this.emit('connected', this.connection);
      return this.connection;
    } catch (err) {
      console.error('[ConnectionManager] Failed to connect:', err.message);
      this.connection = null;
      if (!this._closing) {
        this._scheduleReconnect();
      }
      throw err;
    }
  }

  _scheduleReconnect() {
    if (this._reconnectAttempt >= this.maxAttempts) {
      console.error('[ConnectionManager] Max reconnect attempts reached');
      this.emit('maxReconnects');
      return;
    }

    this._reconnectAttempt++;
    const delay = Math.min(
      this.reconnectDelay * Math.pow(1.5, this._reconnectAttempt - 1),
      30000
    );

    console.log(
      `[ConnectionManager] Reconnecting in ${Math.round(delay / 1000)}s (attempt ${this._reconnectAttempt}/${this.maxAttempts})`
    );

    setTimeout(async () => {
      try {
        await this.connect();
      } catch (err) {
        // connect() already handles scheduling the next reconnect
      }
    }, delay);
  }

  async close() {
    this._closing = true;
    if (this.connection) {
      await this.connection.close();
      this.connection = null;
      console.log('[ConnectionManager] Connection closed gracefully');
    }
  }
}

// ─── Channel Pool ───

class ChannelPool {
  constructor(connectionManager, poolSize = 5) {
    this.connMgr = connectionManager;
    this.poolSize = poolSize;
    this._channels = [];
    this._index = 0;
  }

  async initialize() {
    const conn = this.connMgr.connection;
    if (!conn) throw new Error('No connection available');

    this._channels = [];
    for (let i = 0; i < this.poolSize; i++) {
      const ch = await conn.createConfirmChannel();
      ch.on('error', (err) => {
        console.error(`[ChannelPool] Channel ${i} error:`, err.message);
        this._replaceChannel(i);
      });
      ch.on('close', () => {
        console.warn(`[ChannelPool] Channel ${i} closed`);
      });
      this._channels.push(ch);
    }

    console.log(`[ChannelPool] Initialized ${this.poolSize} confirm channels`);
  }

  async _replaceChannel(index) {
    try {
      const conn = this.connMgr.connection;
      if (!conn) return;
      const ch = await conn.createConfirmChannel();
      ch.on('error', (err) => {
        console.error(`[ChannelPool] Replacement channel ${index} error:`, err.message);
        this._replaceChannel(index);
      });
      this._channels[index] = ch;
      console.log(`[ChannelPool] Replaced channel ${index}`);
    } catch (err) {
      console.error(`[ChannelPool] Failed to replace channel ${index}:`, err.message);
    }
  }

  getChannel() {
    if (this._channels.length === 0) {
      throw new Error('No channels available');
    }
    const ch = this._channels[this._index % this._channels.length];
    this._index++;
    return ch;
  }

  async closeAll() {
    for (const ch of this._channels) {
      try {
        if (ch) await ch.close();
      } catch (err) {
        // Ignore close errors during shutdown
      }
    }
    this._channels = [];
  }
}

// ─── Topology Setup ───

async function setupTopology(channel) {
  // Dead letter exchange and queue
  await channel.assertExchange(CONFIG.dlxExchange, 'direct', { durable: true });
  await channel.assertQueue(CONFIG.dlqQueue, {
    durable: true,
    arguments: { 'x-queue-type': 'quorum' },
  });
  await channel.bindQueue(CONFIG.dlqQueue, CONFIG.dlxExchange, CONFIG.routingKey);

  // Main exchange and queue
  await channel.assertExchange(CONFIG.exchange, CONFIG.exchangeType, { durable: true });
  await channel.assertQueue(CONFIG.queue, {
    durable: true,
    arguments: {
      'x-queue-type': 'quorum',
      'x-delivery-limit': 5,
      'x-dead-letter-exchange': CONFIG.dlxExchange,
      'x-dead-letter-routing-key': CONFIG.routingKey,
      'x-max-length': 100000,
      'x-overflow': 'reject-publish',
    },
  });
  await channel.bindQueue(CONFIG.queue, CONFIG.exchange, 'order.created.#');

  console.log('[Topology] Exchanges, queues, and bindings declared');
}

// ─── Producer ───

async function produce(count) {
  const connMgr = new ConnectionManager(CONFIG.url, {
    reconnectDelay: CONFIG.reconnectDelay,
    maxReconnectAttempts: CONFIG.maxReconnectAttempts,
  });

  await connMgr.connect();

  const pool = new ChannelPool(connMgr, CONFIG.channelPoolSize);
  await pool.initialize();

  // Setup topology on first channel
  await setupTopology(pool.getChannel());

  let published = 0;
  let failed = 0;

  const publishPromises = [];

  for (let i = 0; i < count; i++) {
    const message = {
      id: randomUUID(),
      type: 'order.created',
      sequence: i + 1,
      timestamp: new Date().toISOString(),
      data: {
        item: `item-${i + 1}`,
        quantity: (i % 10) + 1,
        price: parseFloat((9.99 + i * 0.5).toFixed(2)),
      },
    };

    const ch = pool.getChannel();
    const body = Buffer.from(JSON.stringify(message));

    const publishPromise = new Promise((resolve) => {
      try {
        ch.publish(
          CONFIG.exchange,
          `order.created.us`,
          body,
          {
            persistent: true,
            contentType: 'application/json',
            messageId: message.id,
            timestamp: Math.floor(Date.now() / 1000),
            headers: { produced_at: new Date().toISOString() },
          },
          (err) => {
            if (err) {
              console.error(`[Producer] Nacked ${message.id}:`, err.message);
              failed++;
            } else {
              published++;
              if (published % 100 === 0 || published === count) {
                console.log(`[Producer] Published ${published}/${count}`);
              }
            }
            resolve();
          }
        );
      } catch (err) {
        console.error(`[Producer] Publish error:`, err.message);
        failed++;
        resolve();
      }
    });

    publishPromises.push(publishPromise);

    // Batch wait every 1000 messages to avoid buffering too many
    if (publishPromises.length >= 1000) {
      await Promise.all(publishPromises);
      publishPromises.length = 0;
    }
  }

  // Wait for remaining confirms
  await Promise.all(publishPromises);

  console.log(`[Producer] Done. Published: ${published}, Failed: ${failed}`);

  await pool.closeAll();
  await connMgr.close();
}

// ─── Consumer ───

async function consume(queue, prefetch) {
  const connMgr = new ConnectionManager(CONFIG.url, {
    reconnectDelay: CONFIG.reconnectDelay,
    maxReconnectAttempts: CONFIG.maxReconnectAttempts,
  });

  let channel = null;
  let processed = 0;
  let errors = 0;
  let shuttingDown = false;

  async function startConsuming() {
    const conn = await connMgr.connect();
    channel = await conn.createChannel();

    channel.on('error', (err) => {
      console.error('[Consumer] Channel error:', err.message);
    });
    channel.on('close', () => {
      console.warn('[Consumer] Channel closed');
      if (!shuttingDown) {
        setTimeout(startConsuming, CONFIG.reconnectDelay);
      }
    });

    await setupTopology(channel);
    await channel.prefetch(prefetch);

    await channel.consume(
      queue,
      async (msg) => {
        if (!msg) return; // Consumer cancelled by broker

        const msgId = msg.properties.messageId || 'unknown';

        try {
          const content = JSON.parse(msg.content.toString());
          console.log(`[Consumer] Processing ${msgId}: ${JSON.stringify(content).slice(0, 100)}`);

          // --- Your processing logic here ---
          await processMessage(content, msg.properties);
          // ---

          channel.ack(msg);
          processed++;
        } catch (err) {
          console.error(`[Consumer] Error processing ${msgId}:`, err.message);
          errors++;

          if (isTransientError(err)) {
            channel.nack(msg, false, true); // Requeue
          } else {
            channel.reject(msg, false); // Send to DLQ
          }
        }
      },
      { noAck: false }
    );

    console.log(`[Consumer] Consuming from ${queue} (prefetch=${prefetch})`);
  }

  // Reconnect on connection events
  connMgr.on('connected', () => {
    if (channel === null && !shuttingDown) {
      startConsuming().catch((err) => {
        console.error('[Consumer] Failed to restart consuming:', err.message);
      });
    }
  });

  // Graceful shutdown
  function shutdown(signal) {
    console.log(`\n[Consumer] Received ${signal} — shutting down...`);
    shuttingDown = true;

    const forceTimeout = setTimeout(() => {
      console.error('[Consumer] Forced shutdown after timeout');
      process.exit(1);
    }, 10000);

    (async () => {
      try {
        if (channel) {
          await channel.cancel(channel.consumers?.[0]?.consumerTag).catch(() => {});
          await channel.close().catch(() => {});
        }
        await connMgr.close();
      } catch (err) {
        // Ignore shutdown errors
      }

      clearTimeout(forceTimeout);
      console.log(`[Consumer] Stopped. Processed: ${processed}, Errors: ${errors}`);
      process.exit(0);
    })();
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  await startConsuming();
}

// ─── Message Processing ───

async function processMessage(message, properties) {
  // Simulate processing delay
  await new Promise((resolve) => setTimeout(resolve, 10));
}

function isTransientError(err) {
  return (
    err.code === 'ECONNRESET' ||
    err.code === 'ETIMEDOUT' ||
    err.message.includes('timeout') ||
    err.message.includes('ECONNREFUSED')
  );
}

// ─── CLI ───

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (command === 'produce') {
    const countIdx = args.indexOf('--count');
    const count = countIdx >= 0 ? parseInt(args[countIdx + 1], 10) : 10;
    await produce(count);
  } else if (command === 'consume') {
    const queueIdx = args.indexOf('--queue');
    const queue = queueIdx >= 0 ? args[queueIdx + 1] : CONFIG.queue;
    const prefetchIdx = args.indexOf('--prefetch');
    const prefetch = prefetchIdx >= 0 ? parseInt(args[prefetchIdx + 1], 10) : CONFIG.prefetch;
    await consume(queue, prefetch);
  } else {
    console.log('Usage:');
    console.log('  node node-producer-consumer.js produce [--count N]');
    console.log('  node node-producer-consumer.js consume [--queue Q] [--prefetch N]');
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('[Fatal]', err);
  process.exit(1);
});
