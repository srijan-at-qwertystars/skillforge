#!/usr/bin/env -S deno run --allow-hrtime
//
// deno-benchmark.ts — Benchmarking script using Deno.bench()
//
// Usage:
//   deno bench deno-benchmark.ts
//   deno bench --filter="string" deno-benchmark.ts
//
// This file demonstrates common benchmarking patterns with Deno's
// built-in Deno.bench() API. Adapt these patterns to benchmark
// your own code.
//

// ─── String Operations ─────────────────────────────────────────────────

Deno.bench("string concatenation with +", () => {
  let result = "";
  for (let i = 0; i < 100; i++) {
    result += "hello";
  }
});

Deno.bench("string concatenation with template literal", () => {
  let result = "";
  for (let i = 0; i < 100; i++) {
    result = `${result}hello`;
  }
});

Deno.bench("string concatenation with array.join", () => {
  const parts: string[] = [];
  for (let i = 0; i < 100; i++) {
    parts.push("hello");
  }
  const _result = parts.join("");
});

// ─── Array Operations ──────────────────────────────────────────────────

const sampleArray = Array.from({ length: 1000 }, (_, i) => i);

Deno.bench("Array.map()", () => {
  sampleArray.map((x) => x * 2);
});

Deno.bench("for loop", () => {
  const result = new Array(sampleArray.length);
  for (let i = 0; i < sampleArray.length; i++) {
    result[i] = sampleArray[i] * 2;
  }
});

Deno.bench("Array.reduce() sum", () => {
  sampleArray.reduce((acc, x) => acc + x, 0);
});

Deno.bench("for loop sum", () => {
  let sum = 0;
  for (let i = 0; i < sampleArray.length; i++) {
    sum += sampleArray[i];
  }
});

// ─── Object Operations ─────────────────────────────────────────────────

Deno.bench("object spread", () => {
  const obj = { a: 1, b: 2, c: 3 };
  const _copy = { ...obj, d: 4 };
});

Deno.bench("Object.assign", () => {
  const obj = { a: 1, b: 2, c: 3 };
  const _copy = Object.assign({}, obj, { d: 4 });
});

Deno.bench("Map.set/get", () => {
  const map = new Map<string, number>();
  for (let i = 0; i < 100; i++) {
    map.set(`key${i}`, i);
  }
  for (let i = 0; i < 100; i++) {
    map.get(`key${i}`);
  }
});

Deno.bench("Object property access", () => {
  const obj: Record<string, number> = {};
  for (let i = 0; i < 100; i++) {
    obj[`key${i}`] = i;
  }
  for (let i = 0; i < 100; i++) {
    const _v = obj[`key${i}`];
  }
});

// ─── JSON Operations ───────────────────────────────────────────────────

const sampleData = {
  users: Array.from({ length: 50 }, (_, i) => ({
    id: i,
    name: `User ${i}`,
    email: `user${i}@example.com`,
    active: i % 2 === 0,
    tags: ["tag1", "tag2", "tag3"],
  })),
};
const jsonString = JSON.stringify(sampleData);

Deno.bench("JSON.stringify", () => {
  JSON.stringify(sampleData);
});

Deno.bench("JSON.parse", () => {
  JSON.parse(jsonString);
});

Deno.bench("JSON roundtrip (stringify + parse)", () => {
  JSON.parse(JSON.stringify(sampleData));
});

// ─── Encoding ───────────────────────────────────────────────────────────

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const sampleText = "Hello, World! ".repeat(100);
const encodedText = textEncoder.encode(sampleText);

Deno.bench("TextEncoder.encode", () => {
  textEncoder.encode(sampleText);
});

Deno.bench("TextDecoder.decode", () => {
  textDecoder.decode(encodedText);
});

// ─── Crypto ─────────────────────────────────────────────────────────────

Deno.bench("crypto.randomUUID", () => {
  crypto.randomUUID();
});

Deno.bench("crypto.getRandomValues (256 bytes)", () => {
  crypto.getRandomValues(new Uint8Array(256));
});

Deno.bench({
  name: "crypto.subtle.digest SHA-256",
  async fn() {
    const data = textEncoder.encode("benchmark data");
    await crypto.subtle.digest("SHA-256", data);
  },
});

// ─── URL Parsing ────────────────────────────────────────────────────────

Deno.bench("URL parsing", () => {
  new URL("https://example.com/path?query=value&other=123#hash");
});

Deno.bench("URLSearchParams", () => {
  const params = new URLSearchParams("a=1&b=2&c=3&d=4&e=5");
  params.get("c");
  params.has("d");
  params.toString();
});

// ─── Regex ──────────────────────────────────────────────────────────────

const emailRegex = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
const testEmails = [
  "user@example.com",
  "test.user+tag@domain.co.uk",
  "invalid@",
  "also-invalid",
  "valid@test.org",
];

Deno.bench("regex email validation", () => {
  for (const email of testEmails) {
    emailRegex.test(email);
  }
});

// ─── Structured Clone ──────────────────────────────────────────────────

Deno.bench("structuredClone", () => {
  structuredClone(sampleData);
});

Deno.bench("JSON deep clone", () => {
  JSON.parse(JSON.stringify(sampleData));
});

// ─── Grouped Benchmarks ────────────────────────────────────────────────

Deno.bench({
  name: "async: setTimeout(0)",
  async fn() {
    await new Promise((resolve) => setTimeout(resolve, 0));
  },
});

Deno.bench({
  name: "async: queueMicrotask",
  async fn() {
    await new Promise<void>((resolve) => queueMicrotask(resolve));
  },
});

// ─── Bench with Setup (baseline pattern) ────────────────────────────────

Deno.bench({
  name: "sort 1000 numbers",
  fn() {
    const arr = Array.from({ length: 1000 }, () => Math.random());
    arr.sort((a, b) => a - b);
  },
});

Deno.bench({
  name: "filter + map chain",
  fn() {
    sampleArray
      .filter((x) => x % 2 === 0)
      .map((x) => x * 3)
      .filter((x) => x > 500);
  },
});
