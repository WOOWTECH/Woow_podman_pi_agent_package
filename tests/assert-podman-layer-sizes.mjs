#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const path = process.argv[2];
if (!path) {
  console.error("usage: assert-podman-layer-sizes.mjs <extracted-oci-layout>");
  process.exit(2);
}

const maxBytes = Number(process.env.PI_MAX_LAYER_BYTES ?? 256 * 1024 * 1024);
const layout = JSON.parse(readFileSync(join(path, "index.json"), "utf8"));
assert.ok(layout.manifests?.length, "expected OCI image layout index");
const manifestDescriptor = layout.manifests[0];
const manifest = JSON.parse(readFileSync(join(path, "blobs/sha256", manifestDescriptor.digest.split(":")[1]), "utf8"));
const layers = manifest.layers.map((layer, index) => ({
  index,
  digest: layer.digest,
  size: statSync(join(path, "blobs/sha256", layer.digest.split(":")[1])).size,
}));
const largest = Math.max(...layers.map((layer) => layer.size));
console.log(`${layers.length} compressed OCI layers; largest ${(largest / 1048576).toFixed(1)} MiB; limit ${(maxBytes / 1048576).toFixed(1)} MiB`);

for (const layer of layers.filter(({ size }) => size > maxBytes)) {
  console.error(`layer ${layer.index} ${layer.digest} is ${(layer.size / 1048576).toFixed(1)} MiB`);
}
assert.ok(layers.every(({ size }) => size <= maxBytes), "image contains a compressed OCI layer above the transport-safe limit");
