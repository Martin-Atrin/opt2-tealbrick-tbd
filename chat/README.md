# TBD Chat

The Chat part of TBD: a React renderer hosted in a WKWebView, and a Node 24
helper that the native host starts over private stdio. Adapted from the
MIT-licensed upstream chat client (copyright notice in `LICENSE`).

Rules:
- TBD is not a second control plane. Portal owns identity and grants; agents own
  their execution; miniapps own their data.
- Credentials stay in the helper process. The renderer receives public session
  fields only.
- No owner (person) credential is ever sent to an agent.

Commands: `npm ci`, `npm run typecheck`, `npm test`, `node scripts/build-tbd.mjs`.
