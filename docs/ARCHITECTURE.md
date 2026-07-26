# Architecture

How the app is put together. For backend details see [BACKEND.md](BACKEND.md); for
code conventions see [CONVENTIONS.md](CONVENTIONS.md).

## Targets

Four build products, all generated from `project.yml` (XcodeGen — see CLAUDE.md):

| Target | Type | Bundle id | Sources |
|---|---|---|---|
| `PickleballAI` | iOS app | `com.pickleball.ai` | `PickleballAI/` + `Shared/` |
| `PickleballAIWidget` | app extension (WidgetKit/ActivityKit) | `com.pickleball.ai.widget` | `PickleballAIWidget/` + `PickleballAI/LiveActivityAttributes.swift` |
| `PickleballAIWatch` | watchOS app | `com.pickleball.ai.watchapp` | `PickleballAIWatch/` + `Shared/` |
| — `Shared/` | source dir compiled into **both** app and watch | — | `LiveMatchScore.swift`, `WatchSyncMessage.swift`, `WorkoutMetrics.swift` |

`Shared/` is deliberately dependency-free (no SwiftUI, no Supabase) so its types
round-trip over WatchConnectivity and persist on both devices.

## `AppStore` — the app's brain

`AppStore` is a single `@MainActor final class AppStore: ObservableObject`
injected once at the root (`PickleballAIApp` → `.environmentObject`). Nearly
every view reads `@EnvironmentObject var store: AppStore`. It owns all
`@Published` state and all networking. **New backend calls almost always become
a method on an `AppStore` extension, not ad-hoc calls in views.**

The class is split across files, all in the same module:

| File | Owns |
|---|---|
| `AppStore.swift` | Class declaration, **every piece of stored state**, PostgREST select constants, lifecycle (`start()`), `activeDraft` |
| `AppStore+Auth.swift` | Sign in/out, OTP, onboarding, `loadSignedInData(userId:)` — the post-sign-in fan-out. **Add new initial loads there.** |
| `AppStore+Feed.swift` | Following/discover feeds, pagination, likes |
| `AppStore+Sessions.swift` | Posting sessions, my-sessions list, session CRUD |
| `AppStore+Comments.swift` | Comments, threaded replies, comment likes, mentions |
| `AppStore+FollowGraph.swift` | Directional follows, requests, follower/following lists, search |
| `AppStore+Profile.swift` | Profile reads/updates, avatar upload, measures |
| `AppStore+Notifications.swift` | Notifications list, read state |
| `AppStore+Realtime.swift` | All `RealtimeSubscription` channel lifecycles + debounced refresh |
| `AppStore+Reposts.swift` | Reposting sessions |
| `AppStore+Invites.swift` | Session invites |
| `AppStore+Gear.swift` | Gear locker |
| `AppStore+Safety.swift` | Blocking, reporting |
| `AppStore+MediaHelpers.swift` | Photo upload helpers (post photos, avatars) |

New stored state goes in `AppStore.swift`; new behavior goes in the matching
extension (or a new `AppStore+Topic.swift`).

### Auth routing

`authState` (`.unconfigured / .loading / .signedOut / .needsOnboarding /
.signedIn`) is the top-level router in `RootView`. When signed in, `RootView`
shows three swipeable pages behind a custom `AppTabBar` (the native tab bar is
hidden): **Home** (`HomeView` in `FeedView.swift`), **Workout** (`WorkoutView`
in `LogView.swift`), **Profile** (`ProfileView.swift`).

### PostgREST select constants

Reads use big embedded select strings with explicit FK hints, defined once in
`AppStore.swift` and reused everywhere:

- `selectProfileLite` — the lightweight identity column subset
- `selectActivityGraph` — activities + participants + their profiles
- `selectRepostSource` — the embedded original post for reposts
- `selectWithCounts` / `selectFeedPreview` — full feed rows

**Reuse these constants rather than writing new select strings** — hand-typed
duplicates drift.

### Realtime

`RealtimeSubscription` (in `RealtimeSubscription.swift`) wraps a channel + its
listener-task lifecycle. `AppStore` holds five: sessions, notifications,
follows, invites, comments. Handlers in `AppStore+Realtime.swift` debounce into
feed/list refreshes rather than patching rows in place.

## Data model files

Read models are `Decodable`, write models are `Encodable` — deliberately
separate structs. The old `RemoteModels.swift` was split by domain:

| File | Contents |
|---|---|
| `Models.swift` | Local enums (`SkillFocus`, `SkillLevel`, …) |
| `SessionModels.swift` | `FeedSession`, `SessionActivity`, `ActivityParticipant`, `NewSession`, cached date formatters |
| `DraftModels.swift` | `SessionDraft`, `DraftActivity`, `DraftPlayer` — local composing types |
| `ProfileModels.swift` | `Profile`, `ProfileUpdate`, `PersonRef` |
| `CommentModels.swift` | Comments + replies + likes |
| `SocialModels.swift` | Follow graph rows (`FollowRequest`, `FollowListEntry`, `ContactMatch`, …) |
| `NotificationModels.swift` | `AppNotification`, `DeepLink` |
| `GearModels.swift`, `InviteModels.swift`, `SafetyModels.swift` | Their domains |
| `EdgeFunctionModels.swift` | Request/response payloads for edge functions |
| `SessionStats.swift` | Head-to-head / record / streak computed client-side from `[FeedSession]` |

## Live session → Live Activity → Watch

- An in-progress session is `store.activeDraft: SessionDraft?`. It lives on the
  store so it survives leaving the Workout tab; `ActiveSessionView(isLive:)`
  binds to it. Its `didSet` drives the lock-screen Live Activity via
  `LiveActivityManager` and persists the draft.
- `SessionActivityAttributes` (`LiveActivityAttributes.swift`) is compiled into
  **both** the app and widget targets.
- The watch is a tethered tap-to-score controller: the phone owns auth,
  Supabase networking, and posting; the watch accumulates points locally
  (`WatchGameStore`) and syncs `LiveMatchScore` snapshots + live workout
  metrics (heart rate / calories, via HealthKit) over WatchConnectivity
  (`WatchConnectivityManager` on the phone, `WatchConnectivityClient` on the
  watch, message contract in `Shared/WatchSyncMessage.swift`). Live metrics are
  transient by design — never persisted or uploaded raw.

## Push notifications (client side)

`PushService` (app delegate via `UIApplicationDelegateAdaptor`) captures the
APNs token and notification taps. `AppStore` uploads the token
(`register_device_token` RPC) and routes taps into `pendingDeepLink`, which
`RootView` presents. Server side: see [BACKEND.md](BACKEND.md#push-pipeline).

## Monetization

- `FeatureFlags.subscriptionsEnabled` (in `FeatureFlags.swift`) is the master
  kill switch; `monetizationEnabled` derives from it (always on in DEBUG so the
  paywall stays developable). While it's `false`, **no paid feature ships in
  Release builds.**
- `RevenueCatService` + `Subscription.swift` wrap the RevenueCat SDK;
  `PaywallView.swift` is the paywall, `ProTeaser.swift` the gated-feature
  teasers. Without `RevenueCat.plist` (gitignored), DEBUG builds fall back to a
  stubbed paywall.
- Clients read Pro status from the RevenueCat SDK, never from the
  `entitlements` table (that's written only by the `revenuecat-webhook` edge
  function, for server-side checks).
- The run scheme injects `PickleballAI.storekit`, so simulator purchases hit
  the local StoreKit test store.

## Analytics

`Analytics.swift` (PostHog) is the single source of truth for the event
taxonomy — snake_case, past-tense event names. **Call sites go through
`Analytics`, never raw `PostHogSDK.shared.capture(...)` literals.** The PostHog
token is a public client key and lives in source intentionally.
