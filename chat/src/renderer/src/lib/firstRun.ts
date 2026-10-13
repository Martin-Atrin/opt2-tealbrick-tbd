import type { FirstRunState } from "../../../shared/ipc";

/**
 * Chat's first-run checks (PARITY WP5). The person is already signed in and has a workspace when
 * Chat shows (SignIn and WorkspacePicker come first), so two things remain: a model for TBD's
 * agent (Settings → Models, an Anthropic connection with the person's own key), and, optionally,
 * the agent's own connection to the workspace for Teal Brick apps (the agent card; the person's
 * token never goes to the agent).
 */

export type FirstRunAction = "models" | "connect";

export interface FirstRunStep {
  id: "signin" | "model" | "connect";
  /** The short name in the StepFlow step row ("2-Model"). */
  name: string;
  title: string;
  done: boolean;
  detail?: string;
  action?: FirstRunAction;
  optional?: boolean;
}

export function firstRunSteps(state: FirstRunState): FirstRunStep[] {
  return [
    { id: "signin", name: "Signed in", title: "Signed in to Teal Brick, workspace chosen", done: true },
    state.model.ready
      ? { id: "model", name: "Model", title: "Model for TBD's agent", done: true }
      : { id: "model", name: "Model", title: "Model for TBD's agent", done: false, detail: state.model.note ?? "Choose a model for TBD's agent in Settings → Models.", action: "models" },
    state.agentConnected
      ? { id: "connect", name: "Connect", title: "TBD's agent connected to your workspace", done: true, optional: true }
      : { id: "connect", name: "Connect", title: "Connect TBD's agent to your workspace", done: false, optional: true, detail: "Optional: lets the agent use Teal Brick apps (memory, connected accounts). Your timeline and transcripts work without it.", action: "connect" },
  ];
}

/** Shown while the agent cannot answer, and in an empty conversation while an optional step is open. */
export function showFirstRun(steps: FirstRunStep[], conversationEmpty: boolean): boolean {
  if (steps.some((s) => !s.done && !s.optional)) return true;
  return conversationEmpty && steps.some((s) => !s.done);
}
