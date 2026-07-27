# XcodeBuildMCP setup (macOS)

One-time setup so your coding agent can build, run, and drive the app on a simulator.
Takes about five minutes. For how we actually use it, see [VERIFICATION.md](VERIFICATION.md).

## What this is

[XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) (Sentry, MIT) wraps Xcode's
toolchain and exposes it to AI agents over MCP. The agent gets one call to build+run, and
UI automation that targets **accessibility elements rather than screen coordinates** — so
it doesn't break when a layout shifts.

## Prerequisites

- Xcode 26.x with the iOS 26.3 simulator runtime, and an **iPhone 17 Pro** simulator
  (`xcrun simctl list devices | grep "iPhone 17 Pro"`)
- Node 20+ (`node --version`) — verified on 23.9
- The repo building already — including `PickleballAI/Supabase.plist` (see
  [../CLAUDE.md](../CLAUDE.md))

## 1. Install

```sh
npm install -g xcodebuildmcp@latest
xcodebuildmcp --version     # expect 2.7.0 or newer
```

Homebrew works too: `brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp`.

## 2. Register the MCP server

`.mcp.json` is **gitignored**, so this file is per-machine — you have to create it. If you
already use the Supabase MCP server, add the `XcodeBuildMCP` block alongside it rather than
overwriting.

```jsonc
// .mcp.json  (repo root)
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "xcodebuildmcp",
      "args": ["mcp"]
    }
  }
}
```

## 3. Install the agent skill

Teaches the agent to use the CLI correctly and appends a pointer to `AGENTS.md`.

```sh
xcodebuildmcp init --client claude --skill cli
```

## 4. Restart your agent

**MCP servers load at client startup.** Adding one mid-session does nothing until you
restart. In Claude Code you can also run `/mcp` to reconnect without a full restart.

## 5. Verify

Ask your agent to build and run the app. It should call `session_show_defaults`, then
`build_run_sim`, and the app should launch on the simulator. Expect ~60s for a cold build,
~15s incremental.

To check by hand:

```sh
xcodebuildmcp tools           # lists ~100 tools
```

(`xcodebuildmcp daemon status` reporting "Not running" is fine — the daemon only speeds up
direct CLI use. In MCP mode the client runs its own server process.)

Project defaults live in `.xcodebuildmcp/config.yaml`, which **is** committed — it uses a
simulator *name* rather than a machine-specific UDID, so it works on any machine. You
shouldn't need to change it.

## Troubleshooting

**Agent says the tools aren't available.** This is the common one. MCP servers load at client
startup, so adding the config mid-session does nothing — restart the client, or `/mcp` to
reconnect. If tools still don't appear, confirm the binary is healthy with
`xcodebuildmcp tools` (should list ~100) and check `.mcp.json` is valid JSON.

Note `xcodebuildmcp mcp` is the server itself: run bare in a terminal it will sit waiting on
stdin, which is correct behavior, not a hang. Let the client launch it.

**"Daemon failed to start within 5000ms."** A stale process is holding the socket. Match
`daemon.js` specifically — a broad `pkill -f xcodebuildmcp` also kills the MCP server your
client launched, which silently drops every tool mid-session:

```sh
pgrep -fl 'xcodebuildmcp/build/daemon.js'
kill -9 <pid>
xcodebuildmcp daemon start
```

**UI automation can't find an element.** It reads the accessibility tree, so unlabeled views
are invisible to it. Add an `.accessibilityIdentifier` — that fixes VoiceOver too.

**Using the CLI directly?** Install globally (above) rather than `npx` — `npx` adds 2-3s of
cold start per call, which is enough to expire UI snapshot references between commands.
Note `timeout` doesn't exist on macOS; don't wrap commands in it.

## Uninstall

```sh
xcodebuildmcp init --uninstall
npm uninstall -g xcodebuildmcp
```

Then drop the `XcodeBuildMCP` block from `.mcp.json`.
