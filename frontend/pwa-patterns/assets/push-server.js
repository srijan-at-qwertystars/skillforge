/**
 * Push Notification Server — Node.js + Express + web-push
 *
 * Endpoints:
 *   GET  /api/vapid-public-key   — Get VAPID public key for client subscription
 *   POST /api/push/subscribe     — Store a push subscription
 *   POST /api/push/unsubscribe   — Remove a push subscription
 *   POST /api/push/send          — Send notification to all subscribers
 *   POST /api/push/send/:id      — Send notification to specific subscriber
 *
 * Setup:
 *   1. npm install express web-push cors dotenv
 *   2. npx web-push generate-vapid-keys >> .env
 *   3. Edit .env with your keys (see below)
 *   4. node push-server.js
 *
 * .env file:
 *   VAPID_PUBLIC_KEY=BEl62i...
 *   VAPID_PRIVATE_KEY=UGXp...
 *   VAPID_SUBJECT=mailto:admin@example.com
 *   PORT=3000
 */

require('dotenv').config();
const express = require('express');
const webpush = require('web-push');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

// ─── VAPID Configuration ─────────────────────────────────────

const { VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT } = process.env;

if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
  console.error('❌ Missing VAPID keys. Generate with: npx web-push generate-vapid-keys');
  process.exit(1);
}

webpush.setVapidDetails(
  VAPID_SUBJECT || 'mailto:admin@example.com',
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY
);

// ─── Subscription Storage ────────────────────────────────────
// In production, replace with a database (PostgreSQL, MongoDB, etc.)

const subscriptions = new Map(); // endpoint → subscription object

// ─── Routes ──────────────────────────────────────────────────

// Return VAPID public key for client-side subscription
app.get('/api/vapid-public-key', (req, res) => {
  res.json({ publicKey: VAPID_PUBLIC_KEY });
});

// Subscribe — store push subscription
app.post('/api/push/subscribe', (req, res) => {
  const subscription = req.body;
  if (!subscription?.endpoint) {
    return res.status(400).json({ error: 'Invalid subscription: missing endpoint' });
  }
  const id = Buffer.from(subscription.endpoint).toString('base64url').slice(-16);
  subscriptions.set(subscription.endpoint, { id, ...subscription, createdAt: new Date() });
  console.log(`✅ Subscribed: ${id} (total: ${subscriptions.size})`);
  res.status(201).json({ id, message: 'Subscribed' });
});

// Unsubscribe — remove push subscription
app.post('/api/push/unsubscribe', (req, res) => {
  const { endpoint } = req.body;
  if (!endpoint) {
    return res.status(400).json({ error: 'Missing endpoint' });
  }
  subscriptions.delete(endpoint);
  console.log(`🗑️  Unsubscribed (total: ${subscriptions.size})`);
  res.json({ message: 'Unsubscribed' });
});

// Send notification to all subscribers
app.post('/api/push/send', async (req, res) => {
  const { title = 'Notification', body = '', url = '/', tag, actions } = req.body;
  const payload = JSON.stringify({ title, body, url, tag, actions });

  const results = { sent: 0, failed: 0, removed: 0 };
  const expired = [];

  await Promise.allSettled(
    Array.from(subscriptions.values()).map(async (sub) => {
      try {
        await webpush.sendNotification(sub, payload);
        results.sent++;
      } catch (err) {
        results.failed++;
        // Remove expired/invalid subscriptions (410 Gone, 404 Not Found)
        if (err.statusCode === 410 || err.statusCode === 404) {
          expired.push(sub.endpoint);
          results.removed++;
        } else {
          console.error(`Push failed (${err.statusCode}): ${err.message}`);
        }
      }
    })
  );

  // Clean up expired subscriptions
  expired.forEach((ep) => subscriptions.delete(ep));

  console.log(`📬 Push sent: ${results.sent} ok, ${results.failed} failed, ${results.removed} removed`);
  res.json(results);
});

// Send to specific subscriber by ID
app.post('/api/push/send/:id', async (req, res) => {
  const { id } = req.params;
  const sub = Array.from(subscriptions.values()).find((s) => s.id === id);
  if (!sub) {
    return res.status(404).json({ error: 'Subscriber not found' });
  }

  const { title = 'Notification', body = '', url = '/' } = req.body;
  try {
    await webpush.sendNotification(sub, JSON.stringify({ title, body, url }));
    res.json({ message: 'Sent' });
  } catch (err) {
    if (err.statusCode === 410) {
      subscriptions.delete(sub.endpoint);
      return res.status(410).json({ error: 'Subscription expired' });
    }
    res.status(500).json({ error: err.message });
  }
});

// List subscribers (admin/debug)
app.get('/api/push/subscribers', (req, res) => {
  const subs = Array.from(subscriptions.values()).map(({ id, createdAt }) => ({ id, createdAt }));
  res.json({ count: subs.length, subscribers: subs });
});

// ─── Start Server ────────────────────────────────────────────

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Push server running on http://localhost:${PORT}`);
  console.log(`   VAPID public key: ${VAPID_PUBLIC_KEY.slice(0, 20)}...`);
  console.log(`   Endpoints:`);
  console.log(`     GET  /api/vapid-public-key`);
  console.log(`     POST /api/push/subscribe`);
  console.log(`     POST /api/push/unsubscribe`);
  console.log(`     POST /api/push/send         { title, body, url }`);
  console.log(`     POST /api/push/send/:id     { title, body, url }`);
  console.log(`     GET  /api/push/subscribers`);
});
