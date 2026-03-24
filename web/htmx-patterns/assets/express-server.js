/**
 * Express Server Template for htmx Applications
 *
 * Features:
 * - htmx-aware middleware (request detection, Vary header, cache control)
 * - Partial template rendering helpers
 * - OOB (out-of-band) swap helpers
 * - HX-Trigger response header helpers
 * - Error handling with htmx-friendly responses
 * - CSRF protection setup
 * - Example CRUD routes
 *
 * Usage:
 *   npm install express ejs cookie-parser
 *   node express-server.js
 */

const express = require('express');
const path = require('path');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3000;

// ─── View Engine Setup ──────────────────────────────────────────────
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'templates'));

// ─── Middleware ─────────────────────────────────────────────────────
app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'static')));

// ─── htmx Detection Middleware ──────────────────────────────────────
app.use((req, res, next) => {
  req.isHtmx = req.headers['hx-request'] === 'true';
  req.htmxTarget = req.headers['hx-target'] || '';
  req.htmxTrigger = req.headers['hx-trigger'] || '';
  req.htmxBoosted = req.headers['hx-boosted'] === 'true';
  req.htmxCurrentUrl = req.headers['hx-current-url'] || '';

  if (req.isHtmx) {
    res.set('Vary', 'HX-Request');
    res.set('Cache-Control', 'no-store');
  }

  // Render partial or full page based on htmx request
  res.renderPartial = function (partialView, fullView, data = {}) {
    const template = req.isHtmx ? partialView : fullView;
    return res.render(template, data);
  };

  next();
});

// ─── CSRF Middleware ────────────────────────────────────────────────
function generateCsrfToken() {
  return crypto.randomBytes(32).toString('hex');
}

app.use((req, res, next) => {
  if (!req.cookies._csrf) {
    const token = generateCsrfToken();
    res.cookie('_csrf', token, { httpOnly: true, sameSite: 'strict' });
    req.csrfToken = token;
  } else {
    req.csrfToken = req.cookies._csrf;
  }
  res.locals.csrfToken = req.csrfToken;
  next();
});

app.use((req, res, next) => {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  const token = req.headers['x-csrf-token'] || req.body?._csrf;
  if (token !== req.csrfToken) {
    return res.status(403).send('<p class="text-red-600">CSRF token mismatch</p>');
  }
  next();
});

// ─── htmx Response Helpers ──────────────────────────────────────────

/**
 * Trigger client-side events via HX-Trigger header.
 * @param {Response} res - Express response
 * @param {Object|string} events - Event name or { eventName: eventData }
 * @param {'afterSettle'|'afterSwap'|null} timing - When to trigger
 */
function hxTrigger(res, events, timing = null) {
  const value = typeof events === 'string' ? events : JSON.stringify(events);
  const header = timing === 'afterSettle' ? 'HX-Trigger-After-Settle'
               : timing === 'afterSwap'   ? 'HX-Trigger-After-Swap'
               : 'HX-Trigger';
  res.set(header, value);
}

/** Client-side redirect (htmx handles it). */
function hxRedirect(res, url) {
  res.set('HX-Redirect', url);
  return res.status(204).send('');
}

/** Full page refresh. */
function hxRefresh(res) {
  res.set('HX-Refresh', 'true');
  return res.status(204).send('');
}

/** Override client's hx-target from server. */
function hxRetarget(res, selector) {
  res.set('HX-Retarget', selector);
}

/** Override client's hx-swap from server. */
function hxReswap(res, strategy) {
  res.set('HX-Reswap', strategy);
}

/** Push or replace URL in browser history. */
function hxPushUrl(res, url) {
  res.set('HX-Push-Url', url);
}

function hxReplaceUrl(res, url) {
  res.set('HX-Replace-Url', url);
}

// ─── OOB Helpers ────────────────────────────────────────────────────

/**
 * Render a template and wrap it as an OOB swap element.
 * @param {string} template - EJS template path
 * @param {Object} data - Template data
 * @param {string} targetId - DOM element ID to target
 * @param {string} swap - OOB swap strategy (default: 'true' = outerHTML)
 * @returns {Promise<string>} Rendered OOB HTML
 */
function renderOob(template, data, targetId, swap = 'true') {
  return new Promise((resolve, reject) => {
    app.render(template, data, (err, html) => {
      if (err) return reject(err);
      resolve(`<div id="${targetId}" hx-swap-oob="${swap}">${html}</div>`);
    });
  });
}

/**
 * Send primary content + multiple OOB updates in one response.
 * @param {Response} res - Express response
 * @param {string} primaryHtml - Main response HTML
 * @param {string[]} oobParts - Array of OOB HTML strings
 * @param {number} status - HTTP status code
 */
function sendWithOob(res, primaryHtml, oobParts = [], status = 200) {
  const html = [primaryHtml, ...oobParts].join('\n');
  res.status(status).send(html);
}

// ─── In-Memory Data Store (replace with DB) ─────────────────────────
let contacts = [
  { id: 1, name: 'Alice Johnson', email: 'alice@example.com' },
  { id: 2, name: 'Bob Smith', email: 'bob@example.com' },
  { id: 3, name: 'Carol Williams', email: 'carol@example.com' },
];
let nextId = 4;

// ─── Routes ─────────────────────────────────────────────────────────

app.get('/', (req, res) => {
  res.renderPartial('partials/_home', 'index', {
    contacts,
    contactCount: contacts.length,
  });
});

// List / search contacts
app.get('/contacts', (req, res) => {
  const q = (req.query.q || '').toLowerCase();
  const filtered = q
    ? contacts.filter(c => c.name.toLowerCase().includes(q) || c.email.toLowerCase().includes(q))
    : contacts;

  res.renderPartial('contacts/_list', 'contacts/index', {
    contacts: filtered,
    query: q,
    contactCount: contacts.length,
  });
});

// Create contact
app.post('/contacts', async (req, res) => {
  const { name, email } = req.body;
  const errors = [];

  if (!name || name.trim().length < 2) errors.push('Name must be at least 2 characters');
  if (!email || !email.includes('@')) errors.push('Valid email is required');
  if (contacts.find(c => c.email === email)) errors.push('Email already exists');

  if (errors.length) {
    hxRetarget(res, '#contact-form');
    hxReswap(res, 'outerHTML');
    return res.status(422).render('contacts/_form', { errors, values: req.body });
  }

  const contact = { id: nextId++, name: name.trim(), email: email.trim() };
  contacts.push(contact);

  const rowHtml = await renderView('contacts/_row', { contact });
  const countOob = `<span id="contact-count" hx-swap-oob="true">${contacts.length}</span>`;

  hxTrigger(res, { showToast: `${contact.name} added` }, 'afterSettle');
  sendWithOob(res, rowHtml, [countOob], 201);
});

// Update contact (inline edit)
app.put('/contacts/:id', (req, res) => {
  const contact = contacts.find(c => c.id === parseInt(req.params.id));
  if (!contact) return res.status(404).send('<p>Not found</p>');

  const { name, email } = req.body;
  if (name) contact.name = name.trim();
  if (email) contact.email = email.trim();

  hxTrigger(res, { showToast: 'Contact updated' });
  res.render('contacts/_row', { contact });
});

// Delete contact
app.delete('/contacts/:id', async (req, res) => {
  const idx = contacts.findIndex(c => c.id === parseInt(req.params.id));
  if (idx === -1) return res.status(404).send('<p>Not found</p>');

  contacts.splice(idx, 1);

  const countOob = `<span id="contact-count" hx-swap-oob="true">${contacts.length}</span>`;
  hxTrigger(res, { showToast: 'Contact deleted' });
  sendWithOob(res, '', [countOob]);
});

// Edit form (for inline editing)
app.get('/contacts/:id/edit', (req, res) => {
  const contact = contacts.find(c => c.id === parseInt(req.params.id));
  if (!contact) return res.status(404).send('<p>Not found</p>');
  res.render('contacts/_edit_form', { contact });
});

// ─── Render Helper ──────────────────────────────────────────────────
function renderView(template, data) {
  return new Promise((resolve, reject) => {
    app.render(template, data, (err, html) => {
      if (err) return reject(err);
      resolve(html);
    });
  });
}

// ─── Error Handling ─────────────────────────────────────────────────
app.use((err, req, res, _next) => {
  console.error(err.stack);
  const status = err.status || 500;
  const message = status === 500 ? 'Internal server error' : err.message;

  if (req.isHtmx) {
    hxRetarget(res, '#notifications');
    hxReswap(res, 'innerHTML');
    return res.status(status).send(
      `<div class="bg-red-100 text-red-700 px-4 py-2 rounded">${message}</div>`
    );
  }
  res.status(status).render('error', { message, status });
});

// ─── Start Server ───────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`htmx server running at http://localhost:${PORT}`);
});

module.exports = app;
