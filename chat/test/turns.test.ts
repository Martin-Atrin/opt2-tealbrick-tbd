import { test } from "node:test";
import assert from "node:assert/strict";
import { createTurnRouter, questionCards } from "../src/main/turns.ts";
import type { TurnCallbacks } from "../src/main/defaultAgent.ts";
import type { AgentQuestion } from "../src/agent/protocol.ts";

/**
 * PARITY WP1: question cards. The agent's AskUserQuestion must reach the window as cards, the
 * first send must return askedQuestion, and the answering send must receive the rest of the turn.
 */

const pick: AgentQuestion = {
  question: "Which day should I summarise?",
  header: "Day",
  options: [{ label: "Today", description: "Since 4 AM" }, { label: "Yesterday" }],
  multiSelect: false,
};
const format: AgentQuestion = { question: "Which format?", options: [{ label: "Bullets" }, { label: "Prose" }] };

function fakeAgent() {
  const answers: [string, Record<string, string> | null][] = [];
  let turn: (TurnCallbacks & { text: string; content?: unknown }) | null = null;
  let finish: (r: { sessionId: string; reply: string; turnId: string }) => void = () => {};
  let fail: (e: Error) => void = () => {};
  return {
    answers,
    get turn() { return turn!; },
    finish: (reply: string) => finish({ sessionId: "sess-1", reply, turnId: "t1" }),
    fail: (message: string) => fail(new Error(message)),
    agent: {
      sendTurn: (input: TurnCallbacks & { text: string; content?: unknown }) => {
        turn = input;
        return new Promise<{ sessionId: string; reply: string; turnId: string }>((resolve, reject) => { finish = resolve; fail = reject; });
      },
      answer: (reqId: string, a: Record<string, string> | null) => { answers.push([reqId, a]); },
    },
  };
}

function setup(timeoutMs?: number) {
  const fake = fakeAgent();
  const events: [string, string, Record<string, unknown>][] = [];
  const router = createTurnRouter({ agent: () => fake.agent, emit: (streamId, channel, payload) => events.push([streamId, channel, payload]), questionTimeoutMs: timeoutMs });
  return { fake, events, router };
}

test("question cards: one card per question, option ids are indexes, free text allowed", () => {
  assert.deepEqual(questionCards("q7", [pick, format]), [
    { requestId: "q7.0", prompt: "Which day should I summarise?", options: [{ id: "0", label: "Today", description: "Since 4 AM" }, { id: "1", label: "Yesterday" }], allowFreeform: true },
    { requestId: "q7.1", prompt: "Which format?", options: [{ id: "0", label: "Bullets" }, { id: "1", label: "Prose" }], allowFreeform: true },
  ]);
});

test("a plain turn streams to its own send and resolves with the reply", async () => {
  const { fake, events, router } = setup();
  const sent = router.start({ text: "hi", streamId: "s1" });
  fake.turn.onTurn?.({ sessionId: "sess-1", turnId: "t1" });
  fake.turn.onDelta("Hello");
  fake.finish("Hello");
  assert.deepEqual(await sent, { reply: "Hello", sessionId: "sess-1", streamIndex: 0, askedQuestion: false });
  assert.deepEqual(events, [
    ["s1", "studio:turn", { sessionId: "sess-1", turnId: "t1" }],
    ["s1", "studio:delta", { text: "Hello" }],
  ]);
});

test("attached files reach the agent as content blocks beside the text", async () => {
  const { fake, router } = setup();
  const content = [{ type: "text" as const, text: "look" }, { type: "image" as const, source: { type: "base64" as const, media_type: "image/png" as const, data: "aGk=" } }];
  const sent = router.start({ text: "look", content, streamId: "s1" });
  assert.equal(fake.turn.text, "look");
  assert.deepEqual(fake.turn.content, content);
  fake.finish("A picture.");
  assert.equal((await sent).reply, "A picture.");
});

test("a question parks the send; the answer resumes the turn on the answering stream", async () => {
  const { fake, events, router } = setup();
  const first = router.start({ text: "summarise", streamId: "s1" });
  fake.turn.onTurn?.({ sessionId: "sess-1", turnId: "t1" });
  fake.turn.onQuestion?.({ reqId: "q1", questions: [pick] });
  assert.deepEqual(await first, { reply: "", sessionId: "sess-1", streamIndex: 0, askedQuestion: true });
  assert.deepEqual(events.at(-1), ["s1", "studio:question", { request: questionCards("q1", [pick])[0] }]);
  assert.deepEqual(router.openQuestions(), ["q1"]);

  const second = router.answer({ streamId: "s2", responses: [{ requestId: "q1.0", optionId: "1" }] });
  assert.deepEqual(fake.answers, [["q1", { "Which day should I summarise?": "Yesterday" }]]);
  assert.deepEqual(router.openQuestions(), []);
  fake.turn.onDelta("Yesterday you…");
  fake.finish("Yesterday you…");
  assert.deepEqual(await second, { reply: "Yesterday you…", sessionId: "sess-1", streamIndex: 0, askedQuestion: false });
  assert.deepEqual(events.at(-1), ["s2", "studio:delta", { text: "Yesterday you…" }]);
});

test("several questions: the agent hears back only when every card is answered; free text wins", async () => {
  const { fake, router } = setup();
  const first = router.start({ text: "x", streamId: "s1" });
  fake.turn.onQuestion?.({ reqId: "q2", questions: [pick, format] });
  assert.equal((await first).askedQuestion, true);
  assert.deepEqual(await router.answer({ streamId: "s2", responses: [{ requestId: "q2.1", optionId: "0" }] }), { reply: "", streamIndex: 0, askedQuestion: true });
  assert.deepEqual(fake.answers, []);
  const last = router.answer({ streamId: "s3", responses: [{ requestId: "q2.0", optionId: "0", text: "Last Monday" }] });
  assert.deepEqual(fake.answers, [["q2", { "Which day should I summarise?": "Last Monday", "Which format?": "Bullets" }]]);
  fake.finish("Done");
  assert.equal((await last).reply, "Done");
});

test("an answer to a closed or unknown question is refused with a plain message", async () => {
  const { router } = setup();
  assert.throws(() => router.answer({ streamId: "s9", responses: [{ requestId: "q404.0", optionId: "0" }] }), { message: "This question is no longer open." });
  assert.throws(() => router.answer({ streamId: "s9", responses: [{ requestId: "garbage", optionId: "0" }] }), { message: "This question is no longer open." });
});

test("an unanswered question is refused after the timeout (nothing waits forever)", async () => {
  const { fake, router } = setup(20);
  const first = router.start({ text: "x", streamId: "s1" });
  fake.turn.onQuestion?.({ reqId: "q3", questions: [pick] });
  await first;
  await new Promise((r) => setTimeout(r, 60));
  assert.deepEqual(fake.answers, [["q3", null]]);
  assert.deepEqual(router.openQuestions(), []);
  fake.finish("ok");
});

test("a failed turn rejects the current send and closes its questions", async () => {
  const { fake, router } = setup();
  const first = router.start({ text: "x", streamId: "s1" });
  fake.fail("The agent stopped.");
  await assert.rejects(first, { message: "The agent stopped." });
  assert.deepEqual(router.openQuestions(), []);
});

test("AskUserQuestion is available to the agent and answered on a card, not the consent card", async () => {
  const { AGENT_TOOLS, ASK_TOOL, needsPermission } = await import("../src/agent/protocol.ts");
  assert.equal(ASK_TOOL, "AskUserQuestion");
  assert.equal(AGENT_TOOLS.includes("AskUserQuestion"), true);
  assert.equal(needsPermission("AskUserQuestion"), false);
  assert.equal(needsPermission("Bash"), true);
});
