/**
 * Handling for an agent refusing a signed-in user with 403 `agent_not_granted`.
 *
 * The policy bundle a session carries is issued at sign-in or refresh and its
 * agent grants are computed at that moment. An agent created afterwards is not
 * in it, so the very first request to a new agent is refused even though the
 * workspace owner did grant it. One forced refresh re-issues the bundle with
 * current grants; only if that still fails is the user actually not granted.
 *
 * Kept free of Electron and network imports so it can be unit tested.
 */

export const NOT_GRANTED_MESSAGE =
  "You don't have access to this agent yet. Ask the workspace owner to grant it in Portal, then refresh agents.";

/** Whether an HTTP failure from an agent means "your bundle does not grant this agent". */
export function isAgentNotGranted(status: number, body: string): boolean {
  if (status !== 403) return false;
  // An HTML 403 is a deployment-protection page, not the agent's grant check.
  if (/^\s*<(!doctype|html)/i.test(body)) return false;
  return true;
}

function statusOf(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null)?.status;
  return typeof status === "number" ? status : undefined;
}

function bodyOf(error: unknown): string {
  const body = (error as { body?: unknown } | null)?.body;
  if (typeof body === "string") return body;
  try {
    return JSON.stringify(body ?? "");
  } catch {
    return "";
  }
}

/**
 * Run a request; on `agent_not_granted` force one session refresh and run it
 * once more. The refresh is attempted at most once per call, and a failed
 * refresh (null) surfaces the original refusal.
 */
export async function retryAfterGrantRefresh<T>(
  run: () => Promise<T>,
  refresh: () => Promise<unknown>,
  log: (line: string) => void = () => {},
): Promise<T> {
  try {
    return await run();
  } catch (error) {
    const status = statusOf(error);
    if (status === undefined || !isAgentNotGranted(status, bodyOf(error))) throw error;
    log("[auth] agent has no grant in the current bundle; refreshing and retrying once");
    const renewed = await refresh();
    if (!renewed) throw error;
    return await run();
  }
}
