# bm/ workspace — BinauralMeet client + server

This folder holds sibling repos worked on together, each with its own remote —
there is no monorepo tooling tying them together:

- `binaural-meet/` — the client app (React + MobX + mediasoup-client)
- `bmMediasoupServer/` — the signaling/mediasoup server the client talks to
- `vrcss/` — a separate, lighter mediasoup-client-based client

**Before doing anything nontrivial in this workspace, run `docs/bin/doc`.**
It prints how to look things up plus a generated index of every topic
(workspace layout, dev-environment/sandbox specifics, established architecture
rules). Read only the section you need via `docs/bin/doc show <topic>#<id>` —
don't read whole files or re-derive things that are already documented there.
Writing rules for that tree: `docs/bin/doc show rules`.

Dated history (what changed, when, why) lives in `docs/CHANGELOG.md` —
`docs/bin/doc log` to browse it.
