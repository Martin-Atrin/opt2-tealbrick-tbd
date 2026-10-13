import test from "node:test";
import assert from "node:assert/strict";
import { isAnthropicHost, modelEnv } from "../src/agent/modelEnv.ts";

/** C142 local-first: a non-Anthropic Messages server gets the gateway settings; Anthropic stays as it was. */

test("Anthropic: only the base URL (unchanged behaviour)", () => {
  assert.deepEqual(modelEnv({ model: "claude-opus-5-5", baseUrl: "https://api.anthropic.com" }), { ANTHROPIC_BASE_URL: "https://api.anthropic.com" });
  assert.deepEqual(modelEnv({ model: "claude-opus-5-5" }), {});
  assert.equal(isAnthropicHost("https://api.anthropic.com/"), true);
  assert.equal(isAnthropicHost("http://localhost:11434"), false);
  assert.equal(isAnthropicHost("not a url"), false);
});

test("local Ollama: no experimental betas, every alias pinned to the local model, stable prompt prefix", () => {
  assert.deepEqual(modelEnv({ model: "gpt-oss:20b", baseUrl: "http://localhost:11434" }), {
    ANTHROPIC_BASE_URL: "http://localhost:11434",
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "gpt-oss:20b",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "gpt-oss:20b",
    ANTHROPIC_DEFAULT_OPUS_MODEL: "gpt-oss:20b",
    CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
  });
});
