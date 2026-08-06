#!/usr/bin/env node
// Drive a real pi-web conversation and report what the agent actually did.
//
// Run INSIDE the pi-web container:
//   podman exec -it pi-web node /opt/tests/chat.mjs /tmp/prompt.txt --json /tmp/out.json
//
// This talks to pi-web's own HTTP API exactly as the browser does, so a pass
// here means the real path works — not that a mock answered. Asserting on the
// tool calls rather than on the prose is deliberate: a model claiming "I
// successfully created the file" is not evidence, the tool result is.
import { readFileSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const positional = args.filter((a) => !a.startsWith("--"));
const opt = (n, d) => { const i = args.indexOf("--" + n); return i >= 0 ? args[i + 1] : d; };

const BASE = opt("base", "http://127.0.0.1:30141");
const PROMPT = readFileSync(positional[0], "utf8");
const MODEL = opt("model", process.env.PI_TEST_MODEL || "deepseek/deepseek-v4-flash");
const PROVIDER = opt("provider", process.env.PI_TEST_PROVIDER || "openrouter");
const CWD = opt("cwd", process.env.PI_TEST_CWD || `${process.env.HOME}/pi-cwd-${new Date().toISOString().slice(0, 10).replace(/-/g, "")}`);
const OUT = opt("json");
const TIMEOUT = parseInt(opt("timeout", "280000"), 10);
// pi-web emits no idle event, only turn_end. Without a quiescence timer every
// run would burn the full timeout instead of finishing in seconds.
const QUIET = parseInt(opt("quiet", "6000"), 10);

const t0 = Date.now();
const post = (p, b) =>
  fetch(BASE + p, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) });

const created = await post("/api/agent/new", { cwd: CWD, provider: PROVIDER, modelId: MODEL, type: "ensure_session" })
  .then((r) => r.json());
if (!created.sessionId) {
  console.error("SESSION_CREATE_FAILED", JSON.stringify(created).slice(0, 400));
  process.exit(2);
}
const id = created.sessionId;

const events = await fetch(`${BASE}/api/agent/${id}/events`);
const reader = events.body.getReader();
const decoder = new TextDecoder();

let buf = "", text = "", usage = null, done = false, sawTurnEnd = false, last = Date.now();
const calls = [], errors = [];
// Results are correlated by toolCallId, never by arrival order. The agent
// issues tool calls in parallel, so two starts routinely arrive before either
// end; pairing a result with the most recently started call attaches it to the
// wrong arguments, and the transcript then reads exactly like a cross-read bug
// in the application. That misattribution is indistinguishable from a real
// defect by eye, which is the whole reason this map exists.
const byId = new Map();

const pump = (async () => {
  while (true) {
    const { value, done: fin } = await reader.read();
    if (fin) break;
    buf += decoder.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const chunk = buf.slice(0, i);
      buf = buf.slice(i + 2);
      for (const line of chunk.split("\n")) {
        if (!line.startsWith("data:")) continue;
        let e;
        try { e = JSON.parse(line.slice(5).trim()); } catch { continue; }
        const a = e.assistantMessageEvent;
        if (a?.type === "text_delta" && typeof a.delta === "string") text += a.delta;
        if (e.type === "tool_execution_start") {
          const c = { id: e.toolCallId, tool: e.toolName, args: e.args };
          calls.push(c);
          byId.set(e.toolCallId, c);
        }
        if (e.type === "tool_execution_end") {
          const c = byId.get(e.toolCallId);
          if (c) { c.isError = !!e.result?.isError; c.result = JSON.stringify(e.result).slice(0, 1500); }
          else errors.push("UNMATCHED_TOOL_END " + e.toolCallId);
        }
        if (e.type === "message_end" && e.message?.usage) usage = e.message.usage;
        if (e.type === "turn_end") sawTurnEnd = true;
        if (e.type === "turn_start") sawTurnEnd = false;
        if (e.type === "error" || e.error) errors.push(JSON.stringify(e).slice(0, 400));
        last = Date.now();
      }
    }
    if (done) break;
  }
})();

const quiesce = new Promise((res) => {
  const t = setInterval(() => {
    if (sawTurnEnd && Date.now() - last > QUIET) { clearInterval(t); done = true; res(); }
  }, 1000);
});

await post(`/api/agent/${id}`, { type: "prompt", message: PROMPT });
await Promise.race([pump, quiesce, new Promise((r) => setTimeout(r, TIMEOUT))]);

// A call with no result never completed — a timeout, a crash, or a run cut
// short. Reporting it as an empty result would read as "the tool returned
// nothing", which is a different and much less alarming claim.
const pending = calls.filter((c) => c.result === undefined).map((c) => `${c.tool}#${c.id}`);

const result = {
  sessionId: id, model: MODEL, cwd: CWD, durationMs: Date.now() - t0, completed: done,
  toolCalls: calls.map((c) => ({ id: c.id, tool: c.tool, args: c.args, isError: c.isError, result: (c.result || "").slice(0, 800) })),
  assistant: text.trim(), usage, errors, incomplete: pending,
};
if (OUT) writeFileSync(OUT, JSON.stringify(result, null, 1));

console.log(`completed=${done} duration=${result.durationMs}ms toolCalls=${calls.length} tokens=${usage?.totalTokens ?? "?"}`);
if (pending.length) console.log(`INCOMPLETE (no result event): ${pending.join(", ")}`);
console.log("--- TOOL CALLS ---");
calls.forEach((c, i) =>
  console.log(`${i + 1}. ${c.tool}${c.isError ? " [ERROR]" : ""} ${JSON.stringify(c.args).slice(0, 300)}\n   -> ${c.result === undefined ? "(no result event)" : c.result.slice(0, 400)}`));
console.log("--- ASSISTANT ---");
console.log(text.trim() || "(none)");
if (errors.length) { console.log("--- STREAM ERRORS ---"); console.log(errors.join("\n")); }
