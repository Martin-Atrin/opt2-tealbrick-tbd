# opt2-tealbrick-tbd

Teal Brick opt2: TBD desktop app (macOS), free.

**Status: opt2 build (clean-room v2 of Teal Brick), work in progress.** This repository is part of the opt2 build and lives under `Martin-Atrin` during the build; it moves to the Teal Brick organisation as one clean commit when opt2 is released. It is not the current production system.

Owner lane: Lead · TBD Desktop.

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

## No secrets policy

This repository is public. It must never contain secrets or personal data:

- No API keys, tokens, passwords, private keys, deployment secrets, `.env` files or connection strings. Use `.env.example` with placeholder values only.
- Runtime secrets live in the deployment platform (Railway variables, Woodpecker secrets) and are copied between services without printing them.
- No personal names, private agent configurations or customer data.
- Every push runs a secret scan (`.woodpecker/secret-scan.yaml`, gitleaks). GitHub secret scanning with push protection is enabled. Optional local guard: `pre-commit install`.
- If a secret is committed anyway: rotate it first, then remove it from history.

## CI

Woodpecker CI (shared opt2 pipeline template from `opt2-tealbrick-platform`).

## Language

New code is TypeScript (Node 24+). Swift for the native macOS host and speech-to-text.
