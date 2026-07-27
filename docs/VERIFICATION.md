# Verification

How changes get proven to work in this repo. There is no test target — verification is
driving the real app on a simulator via **XcodeBuildMCP**, which builds, launches, and
performs UI automation against the accessibility tree.

One-time setup (per machine): [XCODEBUILDMCP_SETUP.md](XCODEBUILDMCP_SETUP.md).

## The contract

Any change that touches UI or app behavior ships with evidence: the app built, ran, and
the affected screen behaved correctly. "It compiles" is not verification.

Prefer XcodeBuildMCP tools over raw `xcodebuild` / `xcrun simctl`. They return structured
results and capture runtime logs automatically.

## The loop

```
session_show_defaults      # once per session, before the first build — don't assume
build_run_sim              # build + boot + install + launch, one call
wait_for_ui                # predicate-based; never sleep and hope
snapshot_ui                # semantic accessibility tree with elementRefs
tap / type_text / swipe    # act on an elementRef
```

Defaults (project, scheme, simulator, bundle ID) come from `.xcodebuildmcp/config.yaml`,
so most calls take no arguments.

Notes that save time:

- **`tap` returns a fresh snapshot in its response.** You rarely need a separate
  `snapshot_ui` after acting.
- **`elementRef`s go stale** after navigation, scrolling, or sheet changes. Refresh, don't
  reuse across screens.
- **Use `wait_for_ui` predicates** (`exists`, `gone`, `textContains`, `settled`) instead of
  fixed delays. Flakiness here is almost always a missing wait.
- **`build_run_sim` returns `runtimeLogPath`.** That is how you read `os_log` output or a
  temporary `Self._printChanges()`.

## Rules

- **Target accessibility elements, never coordinates.** If something can't be reached, the
  fix is an `.accessibilityIdentifier` on the view — which also serves real VoiceOver users.
  See [CONVENTIONS.md](CONVENTIONS.md).
- **Leave state as you found it.** The demo account hits live Supabase. Undo likes, discard
  sessions, don't leave posts behind.
- **Revert temporary hooks before committing** (`_printChanges`, seeded tabs, `.onAppear`
  stubs). Rebuild after reverting.
- **Screenshot when the result is visual.** Structured snapshots prove an element exists;
  a screenshot proves it looks right.

## Known limitations

Don't diagnose these as app bugs:

- **Notification banner taps dismiss instead of activating** in the simulator. To exercise
  a deep link, drive the URL path instead — `xcrun simctl openurl booted "pickleballai://app/u/<uuid>"`
  sets `pendingDeepLink` the same way a push tap does. Verify real push taps on a device.
- **Fast `type_text` races live formatters.** The phone and OTP fields drop characters; type
  digit-by-digit.
- **Menus and alerts** live in a separate UI layer. Over MCP they appear in `snapshot_ui`;
  via the CLI they need `--verbose`.
- **No airplane-mode toggle**, so forced-network-failure paths (error alerts) can't be
  driven from the simulator.
- **Watch flows** need a paired watch simulator.

Signing in needs the demo account (phone + test OTP) — credentials are in App Store Connect
under App Review Information, not in this repo.

## Fallback

If MCP tools aren't loaded in the session, the same tooling works as a CLI
(`xcodebuildmcp <workflow> <tool>`), and `xcodebuild` / `xcrun simctl` still work. Both are
slower and less reliable — see the setup doc's troubleshooting section first.

SourceKit "Cannot find type … in scope" / "No such module" diagnostics during editing are
usually transient cross-file noise. Trust the build result.
