#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: assert-podman-layer-sizes.mjs <podman-history.json>");
  process.exit(2);
}

const maxBytes = Number(process.env.PI_MAX_LAYER_BYTES ?? 256 * 1024 * 1024);
const history = JSON.parse(readFileSync(path, "utf8"));
assert.ok(Array.isArray(history) && history.length > 0, "expected podman history JSON array");

function bytes(value) {
  if (typeof value === "number") return value;
  const match = String(value).trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*(B|kB|KB|MB|MiB|GB|GiB)$/i);
  assert.ok(match, `unrecognized Podman layer size: ${value}`);
  const units = { b: 1, kb: 1000, kib: 1024, mb: 1_000_000, mib: 1024 ** 2, gb: 1_000_000_000, gib: 1024 ** 3 };
  return Number(match[1]) * units[match[2].toLowerCase()];
}

const layers = history.map((entry) => ({
  command: entry.CreatedBy ?? entry.createdBy ?? entry.created_by ?? "<unknown>",
  size: bytes(entry.Size ?? entry.size),
}));
const largest = Math.max(...layers.map((layer) => layer.size));
console.log(`${layers.length} Podman layers; largest ${(largest / 1048576).toFixed(1)} MiB; limit ${(maxBytes / 1048576).toFixed(1)} MiB`);

for (const layer of layers.filter(({ size }) => size > maxBytes)) {
  console.error(`${(layer.size / 1048576).toFixed(1)} MiB: ${layer.command}`);
}
assert.ok(layers.every(({ size }) => size <= maxBytes), "image contains a layer above the transport-safe limit");
