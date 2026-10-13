/**
 * Environment for the Claude Agent SDK's model connection. Anthropic itself needs only the base URL
 * (when set). Any other Anthropic-compatible server (local Ollama, a gateway) gets the settings the
 * Claude Code gateway rules ask for: no experimental beta fields (a non-Anthropic server may answer
 * 400), every model alias pinned to the one model the server has, and a stable system prompt so a
 * local KV cache is reused. Source: code.claude.com/docs/en/llm-gateway-protocol and model-config.
 */
export function isAnthropicHost(baseUrl: string): boolean {
  try { return new URL(baseUrl).hostname.toLowerCase() === "api.anthropic.com"; } catch { return false; }
}

export function modelEnv(model: { model: string; baseUrl?: string }): Record<string, string> {
  if (!model.baseUrl) return {};
  if (isAnthropicHost(model.baseUrl)) return { ANTHROPIC_BASE_URL: model.baseUrl };
  return {
    ANTHROPIC_BASE_URL: model.baseUrl,
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: model.model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: model.model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model.model,
    CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
  };
}
