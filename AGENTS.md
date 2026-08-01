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
- [docs/VERIFICATION.md](docs/VERIFICATION.md) — how to prove a change works
- [docs/XCODEBUILDMCP_SETUP.md](docs/XCODEBUILDMCP_SETUP.md) — one-time machine setup
- [docs/RELEASE.md](docs/RELEASE.md) — TestFlight releases

There is no test target. Verification means building **and driving** the app on a simulator
through XcodeBuildMCP — read [docs/VERIFICATION.md](docs/VERIFICATION.md) before verifying a
change, and prefer its tools over raw `xcodebuild` / `xcrun simctl`. If the XcodeBuildMCP
skill is installed, load it before calling those tools.
