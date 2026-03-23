---
name: node-streams
description:
  positive: "Use when user works with Node.js streams, asks about Readable, Writable, Transform, Duplex streams, pipeline, backpressure, Web Streams API, or streaming data processing in Node."
  negative: "Do NOT use for browser Fetch API streaming (without Node context), Kafka/message streaming (use kafka-event-streaming skill), or Python async iterators."
---

# Node.js Streams

## Stream Fundamentals

Four stream types in `node:stream`:

| Type | Description | Example |
|------|-------------|---------|
| **Readable** | Source of data | `fs.createReadStream()`, `http.IncomingMessage` |
| **Writable** | Destination for data | `fs.createWriteStream()`, `http.ServerResponse` |
| **Duplex** | Both readable and writable | `net.Socket`, `zlib` streams |
| **Transform** | Duplex that modifies data in transit | `zlib.createGzip()`, `crypto.createCipheriv()` |

All streams are `EventEmitter` instances. Default mode is **binary** (Buffer/string). Enable **object mode** for arbitrary JS objects via `{ objectMode: true }`.

## Creating Streams

```js
const { Readable } = require('node:stream');

// From array or generator
const s1 = Readable.from(['chunk1', 'chunk2']);
const s2 = Readable.from((function* () { yield 'a'; yield 'b'; })());

// From async iterator
async function* fetchPages(urls) {
  for (const url of urls) yield await (await fetch(url)).text();
}
const s3 = Readable.from(fetchPages(urls));
```

### Custom Readable

```js
class CounterStream extends Readable {
  constructor(max, opts) { super(opts); this.max = max; this.i = 0; }
  _read() {
    this.push(this.i >= this.max ? null : String(this.i++));
  }
}
```

### Custom Writable with batching

```js
class BatchWriter extends Writable {
  constructor(size, opts) {
    super({ ...opts, objectMode: true });
    this.batch = []; this.size = size;
  }
  _write(chunk, _enc, cb) {
    this.batch.push(chunk);
    if (this.batch.length >= this.size) { this._flush(cb); } else cb();
  }
  _final(cb) { this.batch.length ? this._flush(cb) : cb(); }
  _flush(cb) { console.log('Flush:', this.batch.length); this.batch = []; cb(); }
}
```

## Readable Streams

**Push mode (flowing):** Data emitted via `'data'` events. Activated by `resume()`, `pipe()`, or `'data'` listener.
**Pull mode (paused):** Call `read()` explicitly. Default mode.

```js
// Flowing
readable.on('data', (chunk) => process(chunk));

// Paused
readable.on('readable', () => {
  let chunk;
  while ((chunk = readable.read()) !== null) process(chunk);
});
```

**highWaterMark** controls buffer size before backpressure: 16 KB binary default, 64 KB for file streams, 16 objects in object mode.

**Prefer `for await...of`** for consumption:

```js
const rl = require('node:readline');
const lines = rl.createInterface({ input: fs.createReadStream('data.txt'), crlfDelay: Infinity });
for await (const line of lines) { /* line-by-line, constant memory */ }
```

## Writable Streams

`write()` returns `false` when buffer exceeds highWaterMark. Wait for `'drain'` before resuming:

```js
const { once } = require('node:events');
for (const item of data) {
  if (!writable.write(item)) await once(writable, 'drain');
}
writable.end();
```

**cork/uncork** batch multiple small writes into one system call:

```js
writable.cork();
writable.write('header\n');
writable.write('row1\n');
process.nextTick(() => writable.uncork());
```

**`_writev`** in custom Writable handles multiple buffered chunks at once:

```js
class EfficientWriter extends Writable {
  _writev(chunks, cb) {
    fs.appendFile('out.log', chunks.map(({ chunk }) => chunk).join(''), cb);
  }
}
```

## Transform Streams

```js
const { Transform } = require('node:stream');

const toUpper = new Transform({
  transform(chunk, _enc, cb) { cb(null, chunk.toString().toUpperCase()); }
});
```

### flush for final output

```js
const csvToJson = new Transform({
  objectMode: true,
  construct(cb) { this.headers = null; this.buf = ''; cb(); },
  transform(chunk, _enc, cb) {
    this.buf += chunk;
    const lines = this.buf.split('\n');
    this.buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      const vals = line.split(',');
      if (!this.headers) { this.headers = vals; continue; }
      this.push(Object.fromEntries(this.headers.map((h, i) => [h, vals[i]])));
    }
    cb();
  },
  flush(cb) {
    if (this.buf.trim() && this.headers) {
      const vals = this.buf.split(',');
      this.push(Object.fromEntries(this.headers.map((h, i) => [h, vals[i]])));
    }
    cb();
  }
});
```

**PassThrough** — use for tapping, metering, or progress tracking without modifying data.

## Pipeline

Always prefer `pipeline()` over `pipe()`. It propagates errors, destroys all streams on failure, and supports AbortController.

### Async pipeline (preferred)

```js
const { pipeline } = require('node:stream/promises');

await pipeline(
  fs.createReadStream('input.csv'),
  csvToJson,
  new Transform({
    objectMode: true,
    transform(record, _enc, cb) { cb(null, JSON.stringify(record) + '\n'); }
  }),
  fs.createWriteStream('output.jsonl')
);
```

### AbortController cancellation

```js
const ac = new AbortController();
setTimeout(() => ac.abort(), 5000);
try {
  await pipeline(source, transform, dest, { signal: ac.signal });
} catch (err) {
  if (err.code === 'ABORT_ERR') console.log('Aborted');
  else throw err;
}
```

### Inline async generators as pipeline stages

```js
await pipeline(
  fs.createReadStream('data.jsonl'),
  async function* (source) {
    for await (const chunk of source) {
      for (const line of chunk.toString().split('\n'))
        if (line.trim()) yield JSON.parse(line);
    }
  },
  async function* (source) {
    for await (const rec of source)
      if (rec.active) yield JSON.stringify(rec) + '\n';
  },
  fs.createWriteStream('active.jsonl')
);
```

## Backpressure

### How it works

1. Writable buffer fills past `highWaterMark` → `write()` returns `false`.
2. Readable pauses (stops `_read`).
3. Writable drains buffer → emits `'drain'` → Readable resumes.

`pipeline()` handles this automatically. For manual writes:

```js
async function pump(readable, writable) {
  for await (const chunk of readable) {
    if (!writable.write(chunk)) await once(writable, 'drain');
  }
  writable.end();
}
```

### highWaterMark tuning

| Scenario | Recommendation |
|----------|---------------|
| High-latency I/O | 64–256 KB to reduce round-trips |
| Memory-constrained | 4–8 KB |
| Object mode (DB rows) | 16–100 objects |
| File processing | 64 KB (match fs block size) |

### pipe vs pipeline

- `pipe()`: No error propagation, leaked streams on error, no cleanup.
- `pipeline()`: Error propagation, auto-destroy, AbortController support. **Always use `pipeline()`.**

## Web Streams API in Node.js

Available globally since Node 18. WHATWG-standard, promise-based.

```js
const webReadable = new ReadableStream({
  start(controller) {
    controller.enqueue('hello');
    controller.close();
  }
});
const webTransform = new TransformStream({
  transform(chunk, controller) { controller.enqueue(chunk.toUpperCase()); }
});
await webReadable.pipeThrough(webTransform).pipeTo(new WritableStream({
  write(chunk) { console.log(chunk); }
}));
```

### Interop with Node streams

```js
const { Readable, Writable } = require('node:stream');
// Node → Web
const webR = Readable.toWeb(nodeReadable);
const webW = Writable.toWeb(nodeWritable);
// Web → Node
const nodeR = Readable.fromWeb(webReadable);
const nodeW = Writable.fromWeb(webWritable);
```

Use Web Streams for cross-platform code (browser + Node) and `fetch()` response bodies. Prefer Node streams for ecosystem compatibility and advanced backpressure control.

## Common Patterns

### JSONL streaming

```js
await pipeline(
  createReadStream('records.jsonl'),
  async function* (source) {
    let buf = '';
    for await (const chunk of source) {
      buf += chunk; const lines = buf.split('\n'); buf = lines.pop();
      for (const l of lines) if (l.trim()) yield JSON.parse(l);
    }
    if (buf.trim()) yield JSON.parse(buf);
  },
  async function* (recs) {
    for await (const r of recs) yield JSON.stringify({ ...r, ts: Date.now() }) + '\n';
  },
  createWriteStream('processed.jsonl')
);
```

### HTTP streaming with compression

```js
http.createServer(async (req, res) => {
  res.writeHead(200, { 'Content-Encoding': 'gzip', 'Content-Type': 'text/plain' });
  await pipeline(fs.createReadStream('large.log'), zlib.createGzip(), res);
}).listen(3000);
```

## Error Handling

```js
// BAD: pipe() swallows errors, leaks streams
readable.pipe(writable);

// GOOD: pipeline handles errors and cleanup
await pipeline(readable, writable);
```

**`destroy()`** — force-close a stream: `stream.destroy(new Error('reason'))`.

**`finished()`** — detect premature close:

```js
const { finished } = require('node:stream/promises');
try { await finished(stream); }
catch (err) {
  if (err.code === 'ERR_STREAM_PREMATURE_CLOSE') console.log('Closed early');
}
```

## Performance

- **Buffer sizing:** Larger `highWaterMark` = fewer I/O calls but more memory. Benchmark with real data.
- **Object mode overhead:** Each object = one buffer slot regardless of size. Serialize to JSONL for high-throughput pipelines.
- **Zero-copy:** For static files, `fs.createReadStream` piped to response uses `sendfile(2)` internally.

## Async Generators as Streams

### Readable.from with pagination

```js
async function* paginate(fetchFn) {
  let page = 1;
  while (true) {
    const results = await fetchFn(page++);
    if (!results.length) break;
    for (const item of results) yield item;
  }
}
const stream = Readable.from(paginate(fetchUsers), { objectMode: true });
```

### Composable generator stages

```js
const parse = async function* (source) {
  for await (const html of source) yield extractData(html);
};
const filter = (pred) => async function* (source) {
  for await (const item of source) if (pred(item)) yield item;
};

await pipeline(
  Readable.from(urls),
  parse,
  filter((item) => item.score > 0.8),
  async function* (source) {
    for await (const item of source) yield JSON.stringify(item) + '\n';
  },
  createWriteStream('results.jsonl')
);
```

## Real-World Examples

### ETL: CSV → database

```ts
import { pipeline } from 'node:stream/promises';
import { createReadStream } from 'node:fs';
import { Transform, Writable } from 'node:stream';

const csvParser = new Transform({
  objectMode: true,
  construct(cb) { this.headers = null; this.buf = ''; cb(); },
  transform(chunk, _enc, cb) {
    this.buf += chunk;
    const lines = this.buf.split('\n'); this.buf = lines.pop()!;
    for (const line of lines) {
      if (!this.headers) { this.headers = line.split(','); continue; }
      const vals = line.split(',');
      this.push(Object.fromEntries(this.headers.map((h, i) => [h.trim(), vals[i]?.trim()])));
    }
    cb();
  },
  flush(cb) { cb(); }
});
const dbWriter = new Writable({
  objectMode: true,
  async _write(rec, _enc, cb) {
    try { await db.insert('users', rec); cb(); } catch (e) { cb(e as Error); }
  }
});
await pipeline(createReadStream('users.csv'), csvParser, dbWriter);
```

### Compress/decompress

```js
const { createGzip, createGunzip } = require('node:zlib');
await pipeline(createReadStream('data.json'), createGzip(), createWriteStream('data.json.gz'));
await pipeline(createReadStream('data.json.gz'), createGunzip(), createWriteStream('data.json'));
```

### File upload with progress

```js
function createProgressStream(totalSize) {
  let transferred = 0;
  return new PassThrough({
    transform(chunk, _enc, cb) {
      transferred += chunk.length;
      process.stdout.write(`\r${((transferred / totalSize) * 100).toFixed(1)}%`);
      cb(null, chunk);
    }
  });
}
await pipeline(fs.createReadStream('upload.zip'), createProgressStream(size), dest);
```

## Anti-Patterns

**Ignoring backpressure** — always check `write()` return value, await `'drain'`:
```js
// BAD — unbounded memory
for (const item of data) writable.write(JSON.stringify(item));
// GOOD
for (const item of data) {
  if (!writable.write(JSON.stringify(item))) await once(writable, 'drain');
}
```

**Unclosed streams** — use `pipeline()` instead of `pipe()` to auto-destroy on error.

**Listener buildup** — use `pipeline()` or `once()` in request handlers instead of persistent `.on('error')` listeners.

**Loading entire file then streaming** — defeats the purpose. Use `createReadStream()` directly.
