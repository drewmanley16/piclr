# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native SwiftUI iOS app (iOS 17+) for social pickleball tracking, backed by Supabase (Auth, PostgREST, Storage, Realtime, Edge Functions). Design is all-black + electric-lime; see `PickleballAI/DesignSystem.swift` (`Theme`, `cardStyle()`, `AppHeader`, `ProfileAvatar`, `RemoteImage`).

## Project generation (XcodeGen — read this first)

The Xcode project is **generated** from `project.yml` by [XcodeGen](https://github.com/yonsson/XcodeGen). Do not hand-edit `PickleballAI.xcodeproj`.

- Regenerate after changing `project.yml`, adding/removing source files, or changing build settings: `xcodegen generate`
- **All `Info.plist` keys must be declared in `project.yml`** under a target's `info.properties` — xcodegen overwrites `Info.plist` on every generate, so edits made directly to `Info.plist` are lost. (A missing `UILaunchScreen: {}` here silently letterboxes the app to a legacy size.)
- New Swift files under `PickleballAI/` are picked up automatically (the whole dir is a source), but you still must `xcodegen generate` so they enter the target before building.

## Build & run

```sh
# Regenerate + build for simulator
xcodegen generate
xcodebuild -project PickleballAI.xcodeproj -scheme PickleballAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build

# Install + launch on the booted simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/PickleballAI.app" -maxdepth 8 | head -1)
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.pickleball.ai
```

There is no test target. "Verification" in this repo means: build succeeds + screenshot the running simulator (`xcrun simctl io booted screenshot`). SourceKit "Cannot find type … in scope" / "No such module" diagnostics during editing are usually transient cross-file noise — trust the `xcodebuild` result.

### TestFlight

`ASC_KEY_ID=<key> ASC_ISSUER_ID=<issuer> scripts/testflight.sh` (archive → export with manual signing via `ExportOptions.plist` → `altool` upload). **Bump `CURRENT_PROJECT_VERSION` in `project.yml` before each upload** (build numbers can't repeat). Details (team/bundle/app IDs, provisioning) live in the user's memory, not here.

## Supabase setup (required to run)

`PickleballAI/Supabase.plist` is **gitignored** and holds the real project URL + anon key. Copy `Supabase.example.plist` → `Supabase.plist` and fill it in; `SupabaseConfig` (in `SupabaseService.swift`) reads it and exposes the app-wide `supabase` client. Without it the app renders a "config needed" screen.

Backend lives in `supabase/`: `migrations/` (timestamped SQL, applied in order — this is the schema source of truth, not `schema.sql`) and `functions/` (Deno edge functions: `complete-onboarding`, `match-contacts`, `delete-account`, `send-push`).

## Architecture

### `AppStore` is the whole app's brain
`PickleballAI/AppStore.swift` (~2000 lines) is a single `@MainActor final class AppStore: ObservableObject` injected once at the root (`PickleballAIApp` → `.environmentObject`). Nearly every view reads `@EnvironmentObject var store: AppStore`. It owns all `@Published` state (auth state, feeds, sessions, follow graph, notifications, gear, likes, the live-session `activeDraft`, etc.) and all networking. New backend calls almost always become a method on `AppStore`, not ad-hoc calls in views.

- `authState` (`.unconfigured/.loading/.signedOut/.needsOnboarding/.signedIn`) is the top-level router in `RootView`.
- `loadSignedInData(userId:)` is the post-sign-in fan-out (feed, sessions, follows, notifications, realtime, push). Add new initial loads there.
- PostgREST reads use big embedded select strings with explicit FK hints, e.g. `selectFeedPreview` / `selectWithCounts` (`profiles!sessions_user_id_fkey(...)`). Reuse these constants rather than writing new select strings.

### Data model split
`RemoteModels.swift` holds **read** models (`Decodable`: `FeedSession`, `SessionActivity`, `ActivityParticipant`, `Profile`, `AppNotification`, …) and **write** models (`Encodable`: `NewSession`, `NewSessionActivity`, `ProfileUpdate`, …), plus the local draft types (`SessionDraft`, `DraftActivity`, `DraftPlayer`) used while composing a session. Read/write models are deliberately separate structs. `SessionStats.swift` computes head-to-head/record/streak client-side from `[FeedSession]`.

### Screens
Tabs (`RootView.mainTabs`): **Home** (`FeedView.swift` — following/discover feed, pagination, realtime), **Workout** (`LogView.swift` — quick-log + persistent live session; `SessionEditors.swift` for match/practice editors + player picker), **Profile** (`ProfileView.swift` + `ProfileSheets.swift` — stats, gear, measures, settings). `NotificationsView.swift`, `OtherProfileView.swift`, `CommentsView.swift`, `AuthView.swift` round it out.

### Live session
A session in progress is `store.activeDraft: SessionDraft?`. It persists at the store level so it survives leaving the Workout tab; `ActiveSessionView(isLive:)` binds to it. `activeDraft`'s `didSet` drives the Live Activity via `LiveActivityManager`.

### Live Activity / widget
`PickleballAIWidget/` is a separate **app-extension target** (WidgetKit/ActivityKit). `LiveActivityAttributes.swift` (`SessionActivityAttributes`) is compiled into **both** the app and the widget target (listed in both targets' `sources` in `project.yml`). The extension has its own bundle id `com.pickleball.ai.widget` and its own provisioning profile for TestFlight.

### Push notifications
`PushService` (app delegate via `UIApplicationDelegateAdaptor`) captures the APNs token and taps; `AppStore` uploads the token (`register_device_token` RPC) and routes taps into `pendingDeepLink`, which `RootView` presents. A DB trigger on `notifications` inserts calls the `send-push` edge function (which signs an ES256 APNs JWT). Function URL + shared secret are stored in **Supabase Vault** (`push_function_url` / `push_function_key`), not DB GUCs.

## Conventions

- **Storage paths must lowercase the UID**: Swift's `UUID.uuidString` is uppercase but storage RLS checks `auth.uid()::text` (lowercase). Use `uid.uuidString.lowercased()` for any Storage object path.
- **New feature = new branch off `main`, one PR.** Verify with a simulator screenshot when there's UI. Match the surrounding SwiftUI style (small computed subviews, `Theme` tokens, `cardStyle()`).
- When screenshot-verifying a specific screen you can't tap to, a common pattern is a temporary `TabView(selection: .constant(<tab>))` + `.tag()` hooks or an `.onAppear` seed — **always revert these temp hooks before committing.**
