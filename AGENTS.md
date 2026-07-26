# AGENTS.md

Instructions for AI coding agents working in this repository.

Read [CLAUDE.md](CLAUDE.md) — it is the canonical agent entry point (the name
is historical; the content is tool-agnostic). It covers the XcodeGen workflow
(**never hand-edit the `.xcodeproj`**), build/verify commands, the `AppStore`
architecture, and the always-apply conventions, and links into `docs/` for
depth:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — app structure and data flow
- [docs/BACKEND.md](docs/BACKEND.md) — Supabase migrations and edge functions
- [docs/CONVENTIONS.md](docs/CONVENTIONS.md) — UI contract and lint tripwires
- [docs/RELEASE.md](docs/RELEASE.md) — TestFlight releases
