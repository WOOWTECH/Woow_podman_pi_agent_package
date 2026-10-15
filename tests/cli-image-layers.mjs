#!/usr/bin/env node

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const root = process.cwd();
const dockerfile = existsSync(`${root}/Dockerfile`) ? "Dockerfile" : "Containerfile";
const text = readFileSync(`${root}/${dockerfile}`, "utf8");
const expected = {
  claude: { package: "@anthropic-ai/claude-code", version: "2.1.296", binary: "claude" },
  codex: { package: "@openai/codex", version: "0.162.1", binary: "codex" },
};

for (const [name, spec] of Object.entries(expected)) {
  const packageJson = JSON.parse(readFileSync(`${root}/cli-runtime/${name}/package.json`, "utf8"));
  const lock = JSON.parse(readFileSync(`${root}/cli-runtime/${name}/package-lock.json`, "utf8"));
  assert.equal(packageJson.dependencies?.[spec.package], spec.version, `${name} package.json pin`);
  assert.equal(lock.packages?.[""]?.dependencies?.[spec.package], spec.version, `${name} lock pin`);
  assert.match(text, new RegExp(`COPY cli-runtime/${name}/ /opt/pi-clis/${name}/`), `${name} builder copy is separate`);
  assert.match(text, new RegExp(`npm ci --omit=dev --prefix=/opt/pi-clis/${name}`), `${name} builder install is separate`);
  assert.match(text, new RegExp(`COPY --from=piweb-builder /opt/pi-clis/${name} /opt/pi-clis/${name}`), `${name} final image copy is separate`);
  assert.match(text, new RegExp(`/opt/pi-clis/${name}/node_modules/.bin/${spec.binary}`), `${name} pinned binary is version-checked`);
}

assert.doesNotMatch(text, /COPY cli-runtime\/\s+\/opt\/pi-clis\//, "combined CLI builder copy is forbidden");
assert.doesNotMatch(text, /COPY --from=piweb-builder \/opt\/pi-clis\s+\/opt\/pi-clis$/, "combined CLI final copy is forbidden");
assert.match(text, /@earendil-works\/pi-codemode@1\.1\.0/, "pi-codemode stays on the API-compatible version used by pi-coding-agent");

// Omnigent CLI: one hash-locked version, the same in the lock, the build check and the
// runtime check, with Python and the venv in separate runtime layers.
const omnigent = "0.12.0";
const requirements = readFileSync(`${root}/cli-runtime/omnigent/requirements.txt`, "utf8");
assert.match(requirements, new RegExp(`^omnigent==${omnigent.replaceAll(".", "\\.")} \\\\$`, "m"), "omnigent lock pin");
for (const line of requirements.split("\n").filter((l) => /^[A-Za-z0-9]/.test(l))) {
  assert.match(line, /^[A-Za-z0-9_.-]+==\S+/, `every locked requirement is pinned exactly: ${line}`);
}
assert.match(requirements, /--hash=sha256:[0-9a-f]{64}/, "omnigent lock carries hashes");
assert.match(text, /uv pip install .*--require-hashes/, "omnigent install requires hashes");
assert.match(text, /COPY --from=ghcr\.io\/astral-sh\/uv:[0-9.]+@sha256:[0-9a-f]{64} /, "uv is pinned by digest");
assert.equal(text.match(new RegExp(`grep -q '\\^omnigent ${omnigent.replaceAll(".", "\\.")}'`, "g"))?.length, 2, "omni version is checked in both stages");
assert.match(text, /^COPY --from=piweb-builder \/opt\/omnigent\/python \/opt\/omnigent\/python$/m, "omnigent Python layer is separate");
assert.match(text, /^COPY --from=piweb-builder \/opt\/omnigent\/venv \/opt\/omnigent\/venv$/m, "omnigent venv layer is separate");

for (const from of text.match(/^FROM \S+/gm)) {
  if (from === "FROM ${BASE_IMAGE}") continue;
  assert.match(from, /@sha256:[0-9a-f]{64}$/, `base image is pinned by digest: ${from}`);
}
console.log("Claude Code, Codex and omnigent have pinned, separate builder and runtime image layers.");
