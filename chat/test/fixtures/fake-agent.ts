// Fake default agent for tests: speaks the helper<->agent protocol.
import { createInterface } from "node:readline";
const out = (m: unknown) => process.stdout.write(`${JSON.stringify(m)}\n`);
const env = { hasKey: process.env.ANTHROPIC_API_KEY === "sk-test", leaked: Object.keys(process.env).filter((k) => /TOKEN|TBO|PORTAL|SECRET/i.test(k)) };
createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.type === "init") return out({ type: "ready" });
  if (m.type === "turn") {
    out({ type: "event", id: m.id, event: { kind: "session", sessionId: "sess-1" } });
    out({ type: "event", id: m.id, event: { kind: "activity", label: "Thinking" } });
    out({ type: "event", id: m.id, event: { kind: "delta", text: "Hello " } });
    out({ type: "permission_request", id: m.id, reqId: "p1", tool: "Bash", detail: "Run: ls", input: { command: "ls" } });
    (globalThis as any).pending = m;
  }
  if (m.type === "permission") {
    const t = (globalThis as any).pending;
    out({ type: "event", id: t.id, event: { kind: "delta", text: m.allow ? "allowed" : "denied" } });
    out({ type: "done", id: t.id, sessionId: "sess-1", reply: `${t.text}|${m.allow}|${JSON.stringify(env)}` });
  }
});
