# pickleball.ai (piclr)

Native SwiftUI iOS app (iOS 17+) for social pickleball tracking — log matches
and practice sessions, follow other players, and share to a feed. Backed by
Supabase (Auth, PostgREST, Storage, Realtime, Edge Functions), with an Apple
Watch scoring companion and a lock-screen Live Activity.

## Quickstart

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a Supabase project.

```sh
# 1. Configure Supabase (gitignored — the app shows a "config needed" screen without it)
cp PickleballAI/Supabase.example.plist PickleballAI/Supabase.plist
#    …then fill in SUPABASE_URL and SUPABASE_ANON_KEY

# 2. Generate the Xcode project (required after every project.yml or file add/remove)
xcodegen generate

# 3. Build for the simulator
xcodebuild -project PickleballAI.xcodeproj -scheme PickleballAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 4. Install + launch on a booted simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/PickleballAI.app" -maxdepth 8 | head -1)
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.pickleball.ai
```

> `PickleballAI.xcodeproj` is **generated** from `project.yml` — never
> hand-edit it, and declare all `Info.plist` keys in `project.yml`.

Backend setup: apply `supabase/migrations/` in order (this is the schema source
of truth) and deploy the functions in `supabase/functions/`. See
[docs/BACKEND.md](docs/BACKEND.md).

Optional: `cp PickleballAI/RevenueCat.example.plist PickleballAI/RevenueCat.plist`
to develop the paywall against real RevenueCat offerings (DEBUG builds
otherwise use a stubbed paywall).

## What's here

| Path | What it is |
|---|---|
| `PickleballAI/` | The iOS app — SwiftUI views + the `AppStore` state layer |
| `PickleballAIWidget/` | WidgetKit extension for the live-session lock-screen activity |
| `PickleballAIWatch/` | watchOS tap-to-score companion app |
| `Shared/` | Dependency-free models compiled into both app and watch |
| `supabase/` | Migrations (source of truth), Deno edge functions, DB tests |
| `scripts/` | `lint.sh` (SwiftLint tripwires), `testflight.sh` (release upload) |
| `project.yml` | XcodeGen project definition — targets, plist keys, versions |
| `docs/` | Deeper documentation (below) |

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — targets, the `AppStore`
  state layer, data models, live session / watch / push flows
- [docs/BACKEND.md](docs/BACKEND.md) — Supabase migrations, edge functions,
  RLS conventions
- [docs/CONVENTIONS.md](docs/CONVENTIONS.md) — UI consistency contract, lint
  tripwires, workflow
- [docs/RELEASE.md](docs/RELEASE.md) — TestFlight uploads, signing, StoreKit
  testing
- [CLAUDE.md](CLAUDE.md) — entry point for AI coding agents

## Verification

There is no test target. Verification = build succeeds + a simulator
screenshot for UI changes (`xcrun simctl io booted screenshot shot.png`), plus
`scripts/lint.sh` (enforced in CI on PRs).
