# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native SwiftUI iOS app (iOS 17+) for social pickleball tracking, backed by Supabase (Auth, PostgREST, Storage, Realtime, Edge Functions), plus a WidgetKit Live Activity extension and a watchOS tap-to-score companion. Design is all-black + electric-lime; see `PickleballAI/DesignSystem.swift` (`Theme`, `cardStyle()`, `AppHeader`, `ProfileAvatar`, `IdentityRow`, `RemoteImage`).

Deeper docs — read the one that matches your task before diving into code:

- `docs/ARCHITECTURE.md` — targets, the `AppStore` split, data-model file map, live session / watch / push / monetization flows
- `docs/BACKEND.md` — Supabase migrations workflow, edge functions, RLS + storage conventions
- `docs/CONVENTIONS.md` — full UI consistency contract + lint tripwires
- `docs/VERIFICATION.md` — **how to prove a change works**: the XcodeBuildMCP loop, rules, known limitations
- `docs/XCODEBUILDMCP_SETUP.md` — one-time machine setup for the above
- `docs/RELEASE.md` — TestFlight uploads, signing, StoreKit testing

## Project generation (XcodeGen — read this first)

The Xcode project is **generated** from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). Do not hand-edit `PickleballAI.xcodeproj`.

- Regenerate after changing `project.yml`, adding/removing source files, or changing build settings: `xcodegen generate`
- **All `Info.plist` keys must be declared in `project.yml`** under a target's `info.properties` — xcodegen overwrites `Info.plist` on every generate, so edits made directly to `Info.plist` are lost. (A missing `UILaunchScreen: {}` here silently letterboxes the app to a legacy size.)
- New Swift files under `PickleballAI/` are picked up automatically (the whole dir is a source), but you still must `xcodegen generate` so they enter the target before building.
- Three targets: `PickleballAI` (app), `PickleballAIWidget` (extension), `PickleballAIWatch` (watch app). `Shared/` is compiled into both app and watch — keep it dependency-free.

## Build & run

Build, launch, and UI automation go through **XcodeBuildMCP** — `build_run_sim` builds,
boots, installs, and launches in one call, and `snapshot_ui`/`tap` drive the app against
the accessibility tree. Project defaults live in `.xcodebuildmcp/config.yaml`, so most
calls take no arguments.

There is no test target. **Verification means driving the running app**, not just a green
build — read `docs/VERIFICATION.md` before verifying a change. Machine setup:
`docs/XCODEBUILDMCP_SETUP.md`.

Raw fallback when the MCP tools aren't loaded:

```sh
# Regenerate + build for simulator
xcodegen generate
xcodebuild -project PickleballAI.xcodeproj -scheme PickleballAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' build

# Install + launch on the booted simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/PickleballAI.app" -maxdepth 8 | head -1)
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.pickleball.ai
```

SourceKit "Cannot find type … in scope" / "No such module" diagnostics during editing are usually transient cross-file noise — trust the build result.

TestFlight: `ASC_KEY_ID=<key> ASC_ISSUER_ID=<issuer> scripts/testflight.sh` — **bump `CURRENT_PROJECT_VERSION` in `project.yml` first**. Details in `docs/RELEASE.md`; team/credential specifics live in the user's memory, not the repo.

## Configuration (gitignored plists)

- `PickleballAI/Supabase.plist` — **required**; copy `Supabase.example.plist` and fill in URL + anon key, else the app shows a "config needed" screen. Read by `SupabaseConfig` in `SupabaseService.swift`.
- `PickleballAI/RevenueCat.plist` — optional, paywall dev only; without it DEBUG builds use a stubbed paywall. `FeatureFlags.monetizationEnabled` compiles all payment UI out of Release until launch.

## Architecture (the 30-second version)

Full detail: `docs/ARCHITECTURE.md`.

- **`AppStore` is the whole app's brain**: one `@MainActor ObservableObject` injected at the root; all `@Published` state and all networking. The class declaration + every piece of stored state live in `PickleballAI/AppStore.swift`; behavior is split across `AppStore+Auth/Feed/Sessions/Comments/FollowGraph/Profile/Notifications/Realtime/Reposts/Invites/Gear/Safety/MediaHelpers.swift`. **New backend calls become methods on the matching extension, not ad-hoc calls in views.**
- `authState` (`.unconfigured/.loading/.signedOut/.needsOnboarding/.signedIn`) is the top-level router in `RootView`. `loadSignedInData(userId:)` (`AppStore+Auth.swift`) is the post-sign-in fan-out — add new initial loads there.
- PostgREST reads use the select-string constants in `AppStore.swift` (`selectProfileLite`, `selectWithCounts`, `selectFeedPreview`, …) with explicit FK hints. **Reuse these constants; don't hand-write new select strings.**
- Models are split by domain (`SessionModels`, `ProfileModels`, `CommentModels`, `SocialModels`, …) with read (`Decodable`) and write (`Encodable`) structs deliberately separate. Drafts (`SessionDraft` etc.) are in `DraftModels.swift`.
- Tabs (`RootView`): **Home** (`HomeView` in `FeedView.swift`), **Workout** (`WorkoutView` in `LogView.swift` + `SessionEditors.swift`), **Profile** (`ProfileView.swift`). A live session is `store.activeDraft`; its `didSet` drives the Live Activity.
- The follow graph is **directional** (follows + requests), not mutual friends.
- Backend: `supabase/migrations/` is the schema source of truth (not `schema.sql`); edge functions in `supabase/functions/`. See `docs/BACKEND.md`.
- Analytics go through `Analytics` (`Analytics.swift`), never raw PostHog calls.

## Conventions (the always-apply subset)

Full contract + tripwire details: `docs/CONVENTIONS.md`. `scripts/lint.sh` (SwiftLint custom rules in `.swiftlint.yml`) enforces the mechanical subset in CI.

- **Storage paths must lowercase the UID**: Swift's `UUID.uuidString` is uppercase but storage RLS checks `auth.uid()::text` (lowercase). Use `uid.uuidString.lowercased()` for any Storage object path.
- **New feature = new branch off `main`, one PR.** Verify with a simulator screenshot when there's UI. Match the surrounding SwiftUI style (small computed subviews, `Theme` tokens, `cardStyle()`).
- **Person rows use `IdentityRow`**; models representing people carry `PersonRef`. Avatars always navigate when a profile exists (`ProfileAvatar` links by default; `unlinked: true` needs a reason). Navigate via `ProfileLink`, never by constructing `OtherProfileView` directly.
- **Sheets containing navigable people use `ProfileNavigationStack`**, not a bare `NavigationStack`.
- **Every list screen ships `SkeletonList` + an empty state + `.refreshable`.** User-initiated state changes fire `Haptics`. Colors/spacing/fonts come from `Theme` — no hardcoded values.
- When screenshot-verifying a screen you can't tap to, a temporary `TabView(selection: .constant(<tab>))` / `.onAppear` seed is fine — **always revert temp hooks before committing.**
