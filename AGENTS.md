# TBD development rules

- macOS 14+, Apple silicon. Swift for the native host; TypeScript for Chat and tooling (no new .js/.mjs).
- No secrets, tokens, personal names, machine names or local user paths in this repository.
- Do not launch development builds against live user data, sockets or credential stores.
- No vendor telemetry. No editing of other apps' configuration files (Claude, Codex, editors).
- Agent access to TBD tools goes through the Teal Brick bridge with the agent's own identity.
- Delete build output (DerivedData, `companion/build*.noindex`, `chat/out`) after each build.
