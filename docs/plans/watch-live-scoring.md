# Plan: Apple Watch live score tracking (tap-to-score)

**Goal:** Kill the #1 friction — manual post-game score entry — by letting the
scorekeeper tap each point on their wrist during play. The score syncs live to
the iPhone, which auto-creates the match and posts the session. No typing after
the game.

**Scope (decided):**
- **Tap-to-score**, not motion auto-detection. (Motion is a later phase; we keep
  the data model forward-compatible for it — see "Forward-compat".)
- **Tethered companion**: the watch relies on the paired iPhone being in
  Bluetooth/Wi-Fi range (in a bag courtside is fine). The **phone owns auth,
  Supabase networking, and posting.** The watch is a resilient controller that
  accumulates points locally and syncs snapshots.

---

## 1. Where this plugs into today's architecture

- A live session is `AppStore.activeDraft: SessionDraft?` — persisted to disk,
  drives the Live Activity via `LiveActivityManager`.
- A match is a `DraftActivity(kind: .match)` with **final** `teamScore` /
  `opponentScore` typed after the fact (defaults 11–9). **There is no
  point-by-point tracking today** — that's what we're adding.
- Precedent to copy: `PickleballAIWidget` is a separate XcodeGen app-extension
  target that shares `LiveActivityAttributes.swift` with the app (listed in both
  targets' `sources` in `project.yml`). The watch app follows the same shape:
  a new target + a small shared, dependency-free model file.

New concept: a **live game** (running score, in progress) that is distinct from
the finalized `DraftActivity`s already in `activities`. When a game ends it
converts into a `DraftActivity(kind: .match)` and appends to the session.

---

## 2. New targets & file layout (XcodeGen)

Add to `project.yml`:

- **`PickleballAIWatch`** — `type: application`, `platform: watchOS`, bundle id
  `com.pickleball.ai.watchapp`, embedded in the iOS app target (like the widget
  is embedded). SwiftUI App lifecycle (single-target watch app, watchOS 10+).
- Shared, **dependency-free** source files compiled into **both** the iOS app
  and the watch target (add to both `sources` lists):
  - `Shared/LiveMatchScore.swift` — the live-game value type + point log.
  - `Shared/WatchSyncMessage.swift` — the WatchConnectivity payload contract.
- `xcodegen generate` after; new watch bundle id needs its own provisioning
  profile for TestFlight (update `scripts/testflight.sh` / `ExportOptions.plist`,
  bump `CURRENT_PROJECT_VERSION`).

Watch app files (`PickleballAIWatch/`): `WatchApp.swift`,
`ScoreView.swift` (the scoring screen), `GameSetupView.swift`,
`GameOverView.swift`, `WatchConnectivityClient.swift`, `WatchGameStore.swift`
(ObservableObject owning the live game + local persistence).

---

## 3. Shared data model

```swift
enum Side: String, Codable { case us, them }

struct PointEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    var side: Side           // who won the rally
    var at: Date
    var source: PointSource  // .manual now; .motion later (forward-compat)
}
enum PointSource: String, Codable { case manual, motion }

/// The in-progress game. Value type so it round-trips cleanly over WCSession
/// and persists on both devices.
struct LiveMatchScore: Codable, Hashable {
    var id = UUID()
    var points: [PointEvent] = []       // full log → derive score, enable undo
    var serving: Side = .us             // serve indicator (toggle in MVP)
    var target: Int = 11                // 11 / 15 / 21
    var winByTwo: Bool = true
    var startedAt = Date()
    var seq: Int = 0                    // monotonic version for last-writer-wins

    var us: Int   { points.filter { $0.side == .us }.count }
    var them: Int { points.filter { $0.side == .them }.count }
    var isComplete: Bool { /* reached target & win-by-2 satisfied */ }
    var winner: Side? { /* nil until complete */ }
}
```

Deriving score from a `points` log (not two counters) gives free **undo**,
correct **serve rotation** later, and is the exact hook a future **motion layer**
uses (inject `PointEvent(source: .motion)` as *suggestions* the user confirms).

---

## 4. Sync design (WatchConnectivity)

**Principle:** the watch is authoritative *during* a game and works even if the
phone is briefly unreachable; the phone is authoritative for *posting*.

- `WCSession` on both sides (activate + delegate), mirroring the
  `PushService` / `LiveActivityManager` singleton pattern.
- **Score state** travels as a full `LiveMatchScore` snapshot, not deltas —
  idempotent, last-writer-wins by `seq`. Send on every change via
  **`updateApplicationContext`** (coalesces to latest, delivered in background
  reliably). When the counterpart is `reachable`, *also* `sendMessage` for
  instant mirror + haptic confirmation. Bidirectional (either device can adjust).
- **Commands** (`startGame`, `endGame`, `newGame`, `finishSession`) use
  **`transferUserInfo`** — a guaranteed-delivery FIFO queue, so "Finish & post"
  tapped on the watch while the phone is in a bag still posts when they
  reconnect. No standalone Supabase on the watch.
- **Reconciliation on reconnect:** receiver adopts an incoming snapshot only if
  its `seq` is newer; ties broken by `startedAt`. One scorekeeper means
  conflicts are rare; `seq` handles the backgrounded-then-resynced case.

**Phone-side manager** (`WatchConnectivityManager`, injected into `AppStore`):
- Inbound score snapshot → write into `activeDraft.liveMatch` (new field) →
  `LiveActivityManager.sync` (now shows the live score) → Workout tab reflects it.
- Inbound `endGame` → append `DraftActivity(kind:.match)` built from the score
  (US → team, THEM → opponents) to `activeDraft.activities`; clear `liveMatch`.
- Inbound `finishSession` → call existing `postSession(...)`.
- Phone-side edits → send snapshot back to the watch.

`SessionDraft` gains `var liveMatch: LiveMatchScore?` (already `Codable`, so
disk persistence + crash-restore come for free).

---

## 5. watchOS UX (deliberately minimal)

1. **Setup** (one tap): "Start game" → optional target-score / serve toggle.
   Player identities are **not** picked on the watch — US vs THEM only. Names,
   partners, guests are attached on the phone before posting (keeps the wrist
   flow dead simple; this is the whole point).
2. **Scoring:** two large tap targets — tap your side or the opponents' side to
   award the rally. Big `US 07 · 05 THEM`, serve dot, **haptic per point**.
   Digital Crown or long-press for **−1 / undo**. Auto-detects game point and
   `target` + win-by-2 → "Game!".
3. **Game over:** "New game" (same session) or "Finish & post."

Settings (watch or phone): target score (11/15/21), win-by-2 on/off, serve
tracking on/off. MVP defaults: 11, win-by-2 on, serve indicator on (manual toggle).

---

## 6. iPhone-side touchpoints

- `SessionActivityAttributes.ContentState` gains `us`/`them` (+ serving) so the
  **Live Activity / Dynamic Island shows the running score** — reuses the
  existing debounced updater (coalesce per-point updates to respect ActivityKit
  budget).
- `ActiveSessionView` shows a **live-game card** mirroring the watch score, with
  a "Track on Watch" affordance and manual +/− as a fallback when the watch
  isn't present. Assign players here before posting (existing player picker).
- `AppStore.loadSignedInData` / start: activate `WatchConnectivityManager`.

---

## 7. Phasing (~4–6 weeks)

- **W1 — Scaffolding:** watch target in `project.yml`; shared `LiveMatchScore` +
  message contract; `WCSession` activates both sides and exchanges a snapshot;
  basic watch scoring UI with local state + persistence.
- **W2 — Two-way sync:** snapshot sync via applicationContext + sendMessage;
  phone reflects live score in `activeDraft` + Live Activity; `seq`
  reconciliation; undo.
- **W3 — Game lifecycle:** start/win-detection/end-game → `DraftActivity`;
  multi-game session; **finish & post from the watch** via guaranteed-delivery
  queue; serve indicator + haptics.
- **W4 — Surfaces:** live score in Live Activity/Dynamic Island; phone live-game
  card + player assignment; optional complication for one-tap launch; settings.
- **W5 — Robustness & polish:** backgrounding, crash-restore both sides,
  phone-in-bag testing, VoiceOver/accessibility, edge cases (session already
  open on phone, conflicting edits, watch app relaunch mid-game).
- **W6 — Ship:** watch TestFlight provisioning, real-device testing, buffer.

---

## 8. Risks / unknowns

- **WC background delivery**: `sendMessage` needs reachability; rely on
  `updateApplicationContext` / `transferUserInfo` for the reliable path. Verify
  the phone can update a Live Activity when woken only by a WC delivery.
- **ActivityKit update budget**: long games = many points; coalesce/debounce.
- **Signing/TestFlight**: extra watch bundle id + provisioning profile; build &
  archive complexity rises (paired-simulator testing for dev).
- **Player identity deferred to phone** — confirm that UX is acceptable; the
  alternative (picking players on the watch) is a lot of tiny-screen UI.
- **Serve/side-out rules**: MVP does rally scoring to 11 win-by-2 with a manual
  serve indicator. Traditional side-out scoring (only server scores, 3-number
  score) is a later setting; the `points` log already supports deriving it.

## 9. Forward-compat for motion auto-detect (Phase 2)

The `PointEvent.source` field + point-log model mean a future CoreMotion/ML layer
can inject **suggested** points (`source: .motion`) that the user confirms with a
wrist tap — no rework of the sync pipeline or session conversion.
