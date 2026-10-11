# TBD — Teal Brick desktop (opt2)

TBD is the free Teal Brick desktop app for macOS 14+ on Apple silicon.
It is one native app with three parts:

- **Chat** (`chat/`): React UI in a WKWebView, with a bundled Node 24 helper over private stdio.
- **Companion** (`companion/`): the native host (Xcode project). Screen timeline, daily and weekly review.
- **Listening**: local speech-to-text (being rewritten as a Teal Brick Swift package).

In Teal Brick, TBD is registered as an **agent card**. The person signs in to Portal;
TBD's default agent has its own agent identity. The person's credential never reaches an agent.

Status: opt2 build in progress. See `AGENTS.md` for the working rules.

## Donor code and licences

- `chat/` started from KYBER Studio (MIT, see `chat/LICENSE`).
- `companion/` is a fork of Dayflow 2.5.4 (MIT, see `companion/LICENSE`).
