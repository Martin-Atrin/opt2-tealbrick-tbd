import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import type { AgentConfig, AgentEvent, AgentToHelper, HelperToAgent } from "../agent/protocol";

/**
 * Supervisor for TBD's default agent process (C24: TBD Chat talks only to it).
 *
 * The helper (person side) starts the agent with an allow-listed environment:
 * the user's model key and nothing else that matters. The person token never
 * crosses this boundary (CREDENTIALS §12). Tool calls that change this Mac
 * come back here as permission requests and go to the person's consent card.
 */

export const DEFAULT_AGENT_ID = "tbd-default";

export interface TurnCallbacks {
  onDelta(text: string): void;
  onReset?(): void;
  onActivity(label: string | null): void;
  onTurn?(turn: { sessionId: string; turnId?: string }): void;
}

export interface DefaultAgentDeps {
  /** Node binary and bundled agent entry. */
  node: string;
  entry: string;
  /** Model route + key, resolved when the agent starts (Settings → Models, task "agent"). */
  model(): Promise<{ model: string; baseUrl?: string; apiKey: string }>;
  /** Everything else the agent needs; no credentials. */
  config(): Promise<Omit<AgentConfig, "model">>;
  /** Decide one tool call (file policy + person consent, SEC-04); message is shown to the agent on deny. */
  permission(req: { tool: string; detail: string; input: Record<string, unknown> }): Promise<{ allow: boolean; message?: string }>;
  /** For tests: spawn replacement. */
  spawnProcess?: typeof spawn;
}

interface PendingTurn extends TurnCallbacks {
  resolve(result: { sessionId: string; reply: string }): void;
  reject(error: Error): void;
  sessionId: string;
}

export function createDefaultAgent(deps: DefaultAgentDeps) {
  let child: ChildProcessWithoutNullStreams | null = null;
  let starting: Promise<void> | null = null;
  const turns = new Map<string, PendingTurn>();

  const send = (m: HelperToAgent) => child?.stdin.write(`${JSON.stringify(m)}\n`);

  function failAll(message: string): void {
    for (const [id, t] of turns) { t.reject(new Error(message)); turns.delete(id); }
  }

  async function start(): Promise<void> {
    const route = await deps.model();
    const rest = await deps.config();
    const env: Record<string, string> = {
      PATH: "/usr/bin:/bin",
      HOME: process.env.HOME ?? "",
      TMPDIR: process.env.TMPDIR ?? "/tmp",
      ANTHROPIC_API_KEY: route.apiKey,
    };
    const proc = (deps.spawnProcess ?? spawn)(deps.node, [deps.entry], { env, stdio: ["pipe", "pipe", "pipe"] }) as ChildProcessWithoutNullStreams;
    child = proc;
    proc.stderr.on("data", () => { /* agent logs stay local; never forwarded with content */ });
    const ready = new Promise<void>((resolve, reject) => {
      const lines = createInterface({ input: proc.stdout });
      lines.on("line", (line) => {
        let m: AgentToHelper;
        try { m = JSON.parse(line) as AgentToHelper; } catch { return; }
        if (m.type === "ready") { resolve(); return; }
        handle(m);
      });
      proc.once("exit", (code) => {
        if (child === proc) child = null;
        reject(new Error(`The agent stopped (exit ${code ?? "signal"}).`));
        failAll("The agent stopped. Send your message again.");
      });
      proc.once("error", (e) => reject(e));
    });
    send({ type: "init", config: { ...rest, model: { model: route.model, baseUrl: route.baseUrl } } });
    await ready;
  }

  function handle(m: AgentToHelper): void {
    if (m.type === "event") {
      const t = turns.get(m.id);
      if (!t) return;
      const e: AgentEvent = m.event;
      if (e.kind === "delta") t.onDelta(e.text);
      else if (e.kind === "reset") t.onReset?.();
      else if (e.kind === "activity") t.onActivity(e.label);
      else if (e.kind === "session") { t.sessionId = e.sessionId; t.onTurn?.({ sessionId: e.sessionId, turnId: m.id }); }
    } else if (m.type === "permission_request") {
      void deps.permission({ tool: m.tool, detail: m.detail, input: m.input ?? {} })
        .then((d) => send({ type: "permission", reqId: m.reqId, allow: d.allow, message: d.message }))
        .catch(() => send({ type: "permission", reqId: m.reqId, allow: false }));
    } else if (m.type === "done") {
      const t = turns.get(m.id);
      if (t) { turns.delete(m.id); t.resolve({ sessionId: m.sessionId, reply: m.reply }); }
    } else if (m.type === "error") {
      if (!m.id) return;
      const t = turns.get(m.id);
      if (t) { turns.delete(m.id); t.reject(new Error(m.message)); }
    }
  }

  async function ensure(): Promise<void> {
    if (child) return;
    if (!starting) starting = start().finally(() => { starting = null; });
    await starting;
  }

  return {
    async sendTurn(input: { text: string; sessionId?: string } & TurnCallbacks): Promise<{ sessionId: string; reply: string; turnId: string }> {
      await ensure();
      const id = randomUUID();
      const result = await new Promise<{ sessionId: string; reply: string }>((resolve, reject) => {
        turns.set(id, { ...input, resolve, reject, sessionId: input.sessionId ?? "" });
        send({ type: "turn", id, text: input.text, sessionId: input.sessionId });
      });
      return { ...result, turnId: id };
    },
    cancel(turnId?: string): void {
      if (turnId) send({ type: "cancel", id: turnId });
      else for (const id of turns.keys()) send({ type: "cancel", id });
    },
    stop(): void {
      if (!child) return;
      send({ type: "shutdown" });
      const c = child;
      child = null;
      setTimeout(() => c.kill("SIGTERM"), 1000).unref();
      failAll("The agent was stopped.");
    },
    running: () => child !== null,
  };
}

export type DefaultAgent = ReturnType<typeof createDefaultAgent>;
