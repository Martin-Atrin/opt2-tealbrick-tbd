import { execFile } from "node:child_process";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/**
 * Listening (transcripts, meetings, dictations) as harness-local tools of TBD's
 * default agent (C5): read-only calls to the bundled `tbd-listen` CLI, run
 * without a shell. Not Teal Brick app operations; they never pass the bridge.
 */

const MAX_OUTPUT = 200_000;

export function runCli(cli: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(cli, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024, env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "" } }, (error, stdout, stderr) => {
      if (error) reject(new Error((stderr || error.message).trim().slice(0, 500)));
      else resolve(stdout.length > MAX_OUTPUT ? `${stdout.slice(0, MAX_OUTPUT)}\n…(truncated)` : stdout);
    });
  });
}

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
const failure = (e: unknown) => ({ content: [{ type: "text" as const, text: `Listening error: ${e instanceof Error ? e.message : String(e)}` }], isError: true });

export function listeningServer(cli: string) {
  return createSdkMcpServer({
    name: "listening",
    version: "1.0.0",
    instructions: "Local transcripts, meetings and dictations recorded by TBD on this Mac. Read-only.",
    tools: [
      tool("search_transcripts", "Full-text search over the person's local transcripts and meetings. Returns matches as JSON.", { query: z.string().min(1).max(200) },
        async ({ query }) => { try { return text(await runCli(cli, ["search", "--json", "--", query])); } catch (e) { return failure(e); } },
        { annotations: { readOnlyHint: true } }),
      tool("show_transcript", "The full transcript of one recording by id, with timestamps and speakers, as JSON.", { id: z.string().min(1).max(100) },
        async ({ id }) => { try { return text(await runCli(cli, ["show", "--format", "json", "--", id])); } catch (e) { return failure(e); } },
        { annotations: { readOnlyHint: true } }),
      tool("list_meetings", "Recent meeting recordings (id, title, date, duration) as JSON.", {},
        async () => { try { return text(await runCli(cli, ["meetings", "--json"])); } catch (e) { return failure(e); } },
        { annotations: { readOnlyHint: true } }),
      tool("recent_dictations", "Recent dictations and voice notes.", { limit: z.number().int().min(1).max(100).optional() },
        async ({ limit }) => { try { return text(await runCli(cli, ["history", "--json", "--limit", String(limit ?? 20)])); } catch (e) { return failure(e); } },
        { annotations: { readOnlyHint: true } }),
    ],
  });
}
