# Code Review Plan — pickleball.ai iOS

*Produced 2026-07-16 by an orchestrated 5-agent review (Architecture, Mega-Files, Duplication, State/Data-Flow, Robustness). Every finding below was traced to a real file; the highest-severity claims were independently re-verified by the orchestrator against source before publishing. Read-only review — no code was changed.*

> **Status (updated 2026-07-16, branch `code-review-phase1`):** Phases 1 and 2 are implemented — checked items `[x]` below are done and build-verified. Note for future agents: **all line numbers in this document are stale.** `AppStore.swift` is now a ~152-line core plus 13 `AppStore+<Domain>.swift` extensions; `RemoteModels.swift` and `ProfileSheets.swift` no longer exist (split into domain model files and per-sheet view files). Navigate by symbol, not line. Still open: 1.5/1.10 (deferred — DB/schema changes), 1.13 (pre-launch URL swap), 2.8 (skipped — see item), and Phase 3.

---

## Executive summary

The codebase is in **good shape for its stage** — better than typical for a solo pre-launch app. The model layer is clean (no UIKit/SwiftUI leakage), Supabase access is perfectly contained (`import Supabase` appears in exactly 2 files; zero views bypass the store), there are **no dangerous force unwraps, `try!`, `as!`, or `fatalError`s anywhere**, no secrets in source, and error surfacing (`reportError`/`friendly`, `AppStore.swift:2346–2374`) plus optimistic-update rollback (`toggleLike`, `AppStore.swift:1896`) are above-average patterns worth preserving as templates.

Top 3 themes:

1. **`AppStore.swift` (2,401 lines) is the whole app** — 29 `@Published` properties (only 1 `private(set)`), 101 methods, ~16 distinct domains, all Supabase access inlined. Every view re-renders on every published mutation. All five agents independently converged on this file.
2. **A cluster of real, user-facing correctness bugs hides in the state layer** — the live session (`activeDraft`) has *zero* persistence (force-quit loses an hour of logged matches); a killed app orphans its Lock Screen Live Activity; a failed `postSession` strands `posted:false` rows in the DB and retry duplicates them; likes visibly "revert" on the Discover tab; Discover pagination races.
3. **Small duplication debts are cheap to pay now** — a profile-select fragment hand-typed 6×, three near-identical identity-row components, three ISO-8601 formatters, one confirmed-dead method, one stale `schema.sql`.

## Architecture verdict

**Current state:** Single `@MainActor` `AppStore: ObservableObject` injected once at the root, consumed by 13 view files (229 call sites). No repository/service layer; PostgREST select strings, realtime channel plumbing (5 channels, ~150 lines of hand-rolled subscribe/teardown), signed-URL hydration, and image processing all live as peer methods on one class against the module-global `let supabase` (`SupabaseService.swift:30`). Two ad hoc singletons (`PushService.shared`, `LiveActivityManager.shared`). The *boundary* is healthy — views never touch the network — the *hub* is the problem.

**Target state (for this stage):** Keep the single-store programming model views already use, but make the file navigable and the seams visible:
- One `AppStore.swift` holding only state declarations + lifecycle, with method bodies moved into ~13 same-module `extension AppStore` files (`AppStore+Auth.swift`, `AppStore+Feed.swift`, …).
- Shared infrastructure extracted into real types: `MediaHydrator` (signed-URL cache + `hydrate*` helpers), `RealtimeSubscription` (channel+task+teardown wrapper).
- `RemoteModels.swift` split by domain; select-string constants co-located with their models.

**Migration approach:** Extension-split first (pure file moves, no behavior change, no view edits — `private` helpers become `internal`, a mechanical diff), one extension file per PR. Defer the "true" domain-store / `@Observable` re-architecture (Agent A's proposal) until after launch or until re-render cost is measurable — it touches all 13 views and 229 call sites for a perf benefit nobody has yet observed. This resolves the A-vs-B conflict: B's split is a strict prerequisite that loses nothing if A's split happens later.

---

## Prioritized action plan

### Phase 1 — Correctness fixes & quick wins (do before new features)

- [x] **1.1 Persist `activeDraft` across launches.** Force-quit/crash/low-memory kill during a live session silently destroys everything logged (`AppStore.swift:1354–1362`; repo-wide grep confirms zero `UserDefaults`/file persistence). Encode `SessionDraft` to a JSON file on `didSet` (or scenePhase-background), restore in `AppStore.start()`; keep `photoData` in a file, add a max-age staleness check on restore. Verify `SessionDraft`/`DraftActivity`/`DraftPlayer` are `Codable` first. Files: `AppStore.swift`, `RemoteModels.swift`. Effort: **M**. Risk: low. Deps: none.
- [x] **1.2 Reattach to an orphaned Live Activity on launch.** `LiveActivityManager.swift:10` holds `activity` in memory only; after a kill, starting a new session creates a *second* Lock Screen activity while the first lingers. On init, adopt `Activity<SessionActivityAttributes>.activities.first` before ever calling `start()`. Files: `LiveActivityManager.swift`. Effort: **S**. Risk: low. Deps: pairs naturally with 1.1.
- [x] **1.3 Fix Discover-tab like/comment staleness.** `toggleLike` (`AppStore.swift:1896–1932`) and `addComment`/`deleteComment` (`:1663–1692`) reload only `feed`; when the optimistic overlay clears (`optimisticLikeCounts[id] = nil`, line 1931), copies of the session in `discoverFeed`/`mySessions` visibly revert to stale counts. Patch the count delta into whichever arrays contain the session id (mirror how `blockUser` does targeted removals). Files: `AppStore.swift`. Effort: **S–M**. Risk: low.
- [x] **1.4 Guard `loadDiscover` against concurrent loads.** `loadFeed` has `isFeedRequestInFlight` (`AppStore.swift:72,682–690`); `loadDiscover` (`:752–789`) has nothing, and `FeedCard.onAppear` pagination (`FeedView.swift:129–138`) can double-fire — racing requests can compute the same offset and set `discoverReachedEnd` prematurely. Mirror the feed guard. Files: `AppStore.swift`. Effort: **S**. Risk: low.
- [ ] **1.5 Make session posting transactional/idempotent.** `postSession` (`AppStore.swift:1381–1453`) inserts the session (`posted:false`), then activities, participants, photo, then flips `posted:true`; any mid-loop failure strands orphan rows, and retry (which the UI encourages — the draft survives failure) inserts a *new* session. Wrap the multi-insert in a Postgres RPC (precedent: `update_own_session` RPC at `:1514`) or upsert on a client-generated draft id. Files: `AppStore.swift`, new `supabase/migrations/` entry. Effort: **M**. Risk: medium (write path + DB function; test against RLS). Deps: none, but land the pending `isBusy` race fix (known, tracked in memory) first so the write-path diffs don't collide.
- [x] **1.6 Debounce Live Activity updates from the title field.** Every keystroke in the live-session title flows `LogView.swift:495–497` → `activeDraft.didSet` → `LiveActivityManager.sync`, firing unordered fire-and-forget `activity.update()` calls into ActivityKit's rate limiter. Coalesce in `sync` with a short sleep, or push the title only on commit. Files: `LiveActivityManager.swift` or `LogView.swift`. Effort: **S**. Risk: low.
- [x] **1.7 Add staleness guards to remaining loaders.** `loadGear`, `loadFollowState`, `loadNotifications`, `loadBlockedAccounts` assign `@Published` state after `await` with no `currentProfile?.id == userId` re-check, unlike `loadFeed`/`loadDiscover` (`AppStore.swift:713,735,768,779`); a slow response landing during sign-out writes stale data. Copy the existing guard pattern. Files: `AppStore.swift`. Effort: **S**. Risk: low.
- [x] **1.8 Deduplicate the profile-select fragment.** `id,username,display_name,avatar_initials,avatar_url,avatar_path` is hand-typed **6×** in `AppStore.swift` (lines 56, 57, 1589, 1646, 1715, 1940 — verified). Extract one `selectProfileLite` constant and interpolate. PostgREST select syntax is whitespace-sensitive: diff each resulting string, then smoke-test feed/notifications/comments/invites. Effort: **S**. Risk: low.
- [x] **1.9 Delete dead `AppStore.logSession`.** `AppStore.swift:1320–1347`; zero call sites (verified by grep) — superseded by the draft-based `postSession`/`quickLog` path. Re-grep immediately before deleting. Effort: **S**. Risk: low.
- [ ] **1.10 Regenerate or delete `supabase/schema.sql`.** It predates `20260715130000_rivalries_and_leaderboard.sql` and later migrations (verified: zero mentions of rivalries/leaderboard) and will mislead anyone bootstrapping from it. Either `supabase db dump` from a freshly-migrated DB or delete it and point docs at `migrations/`. Effort: **S**. Risk: low.
- [x] **1.11 Adopt `os.Logger`.** Exactly 5 bare `print()` calls and no `Logger` anywhere (`PushService.swift:89`, `LiveActivityManager.swift:48`, `AppStore.swift:377,2287,2296`). Mechanical swap to per-subsystem loggers (`Push`, `LiveActivity`, `FeedPerf`) — the only way to debug TestFlight builds via Console.app. Effort: **S**. Risk: low.
- [x] **1.12 (code done; NOT yet deployed to Supabase)** Wrap edge-function handlers in a top-level try/catch. All four functions in `supabase/functions/` only guard `req.json()`; an unexpected throw yields Deno's default 500 instead of the functions' own `json({error},500)` shape (verified in `delete-account/index.ts:11–56`). Effort: **M** (4 small files). Risk: low.
- [ ] **1.13 Pre-launch: swap hardcoded Vercel URLs.** `AuthView.swift:8–9,17` hardcodes `pickleball-ai-web.vercel.app` terms/privacy/invite links with a live `// TODO: swap to App Store URL at launch` (line 16). Tracked here so it can't slip — Guideline 1.2 exposure if the deployment lapses. Effort: **S**. Deps: launch checklist (see `appstore-submission` memory).

### Phase 2 — Structural refactors

- [x] **2.1 Split `AppStore.swift` into extension files** (one PR each, in this order — realtime and helpers first since they're the most self-contained): `AppStore+Realtime.swift` (lines ~391–642), `AppStore+MediaHelpers.swift` (~2094–2375), `AppStore+Auth.swift` (~121–390), `AppStore+Feed.swift` (~679–830, 1896–1936), `AppStore+FollowGraph.swift` (~846–1142), `AppStore+Sessions.swift` (~1320–1571), `AppStore+Safety.swift`, `+Notifications`, `+Comments`, `+Reposts`, `+Profile`, `+Gear`, `+Invites`. `private` helpers become `internal` — mechanical. Run `xcodegen generate` after each file add. Effort: **L** total, **S–M** per PR. Risk: medium in aggregate, low per PR. Deps: 1.5 and the pending `isBusy` fix should land first.
- [x] **2.2 Extract `MediaHydrator`.** Move `hydrateSessions`/`hydrateProfile(s)`/`hydrateParticipantProfile`/`hydrateComment`/`signedMediaURLs` + `mediaURLCache` (`AppStore.swift:2167–2291, ~86`) into a standalone `@MainActor` class — hydration becomes one injected dependency instead of call-after-every-fetch discipline that every new read method must remember. Effort: **S–M**. Risk: low. Deps: 2.1 (`AppStore+MediaHelpers.swift` is the staging ground).
- [x] **2.3 Add a `RealtimeSubscription` wrapper.** The 5-channel subscribe/for-await/teardown pattern is repeated ~6× (`startRealtime` :395–490, `stopRealtime` :575–609, comments :616–641); nothing enforces that every channel/task pair gets a teardown branch. Collapse to one type with `start()`/`stop()`, migrate one channel at a time. Effort: **M**. Risk: low (realtime is best-effort refresh-triggering). Deps: 2.1.
- [x] **2.4 Split `RemoteModels.swift` (1,186 lines, ~45 types, 8 domains)** into `ProfileModels`, `SessionModels`, `SocialGraphModels`, `SafetyModels`, `NotificationModels`, `GearModels`, `InviteModels`, `EdgeFunctionModels` (line ranges in appendix). Move `SessionDraft`/`DraftActivity`/`DraftPlayer` out — they're on-device UI state, not remote models. Co-locate select-string constants with their models. Effort: **S–M**. Risk: low. Deps: none (can precede 2.1).
- [x] **2.5 Split `ProfileSheets.swift` (1,210 lines, 7 concerns)** per appendix; extracting the ~140 lines of legal markdown into `LegalDocuments.swift` alone pays for itself (pure data, reviewed by non-engineers). Effort: **M**. Risk: low.
- [x] **2.6 Extract a shared identity-row component.** `FollowRequestRow`/`RepostRequestRow` (`ProfileView.swift:640–741`) are structurally identical; `FollowEntryRow` (`FollowListView.swift:62–123`) and `FriendCandidateRow` (`AuthView.swift:679–726`, already reused by `FeedView`) reimplement the same avatar+name+@username block with drifting fonts. Add `IdentityRow` (+ optional accept/decline trailing pair) to `DesignSystem.swift`, migrate one row per screenshot-verified commit. Effort: **M**. Risk: medium (haptics/dialog wiring). 
- [x] **2.7 Smaller file splits** (each S, low risk, per appendix): `ActiveSessionView.swift` out of `LogView.swift`; `FeedCard.swift` out of `FeedView.swift` (and break its ~230-line body — the largest in the codebase — into computed subviews, mirroring `ProfileView`'s pattern); `WorkoutCalendarCard.swift`, `SocialRequestRows.swift`, `RivalsFeature.swift` out of `ProfileView.swift`; `OnboardingPreview.swift`, `FriendCandidateRow.swift`, `AuthField.swift` out of `AuthView.swift`.
- [ ] ~~**2.8**~~ **SKIPPED — incompatible with 2.1.** Swift's `private(set)` restricts the setter to the declaring *file*; after the extension split, every `@Published` property is mutated from `AppStore+*.swift` files, so the tightening is impossible without reverting the split. Revisit only as part of 3.1 (domain stores would restore per-file setter scoping). Original item: Tighten `@Published` to `private(set)`. 29 `@Published var`, only 1 `private(set)` (verified); any view can bypass rollback/debounce invariants. Do incrementally alongside each 2.1 extension PR — as each domain's methods move, lock down its properties. Effort: **S** per domain. Risk: low.
- [x] **2.9 Consolidate date formatters.** Three ISO-8601 sources of truth (`AppStore.swift:101–105`, `RemoteModels.swift:181–188`, plus an inline `ISO8601DateFormatter()` per call at `RemoteModels.swift:1180`); two inline `DateFormatter()`s rebuilt per body evaluation in `WorkoutCalendarCard` (`ProfileView.swift:420,439`). One shared `DateFormatting` namespace + `static let`s. Effort: **S**. Risk: low.

### Phase 3 — Nice-to-haves (post-launch)

- [ ] **3.1 Domain stores or `@Observable` migration.** Split `AppStore` into per-domain `ObservableObject`s (or migrate to iOS 17's `@Observable` for property-level render diffing). Real benefit — today typing in a search field can invalidate feed cards — but touches 13 views / 229 call sites. Do only after 2.1 makes the seams explicit, and only if re-render cost is observed. Effort: **L**. Risk: medium-high.
- [ ] **3.2 Protocol seams + test target.** `AppStore` is untestable: 42 direct references to the global `supabase`, singletons consumed inline (`PushService.shared` at :331, `LiveActivityManager.shared` at :1355). Introduce narrow per-feature protocols with constructor injection *when a test target is decided on* — the seams only pay off then. Effort: **L**. Risk: medium.
- [ ] **3.3 Share theme constants with the widget.** `PickleballAIWidget.swift:5–6` hand-copies `Theme.accent`/`background` hex values. A tiny `SharedTheme.swift` in both targets' `sources` (precedent: `LiveActivityAttributes.swift`) removes the drift risk. Needs `project.yml` edit + `xcodegen generate`. Effort: **S**. Risk: low.
- [ ] **3.4 Comment the unlabeled `try?` swallows** (`LogView.swift:577` — silent photo-load no-op, `ProfileSheets.swift:597`, `LocationPicker.swift:49`) in the style of `AppStore.swift:375–377`. Effort: **S**.
- [ ] **3.5 Tighten edge-function CORS** from `*` if a web client ever appears; moot for the native-only, bearer-token present. Effort: **S**.

### Phase 4 — UI consistency: enforce by construction (added 2026-07-16 after owner found the record-sheet avatar bug)

*Origin: every place that shows a person must show their real avatar and navigate to their profile. The audit found the root cause is API/data design, not view bugs: `ProfileAvatar` defaults `linked: false` (16 call sites in 4 inconsistent states), and stats/blocked models drop or ignore identity. Strategy: make the consistent thing the default, make inconsistent states unrepresentable, then add tripwires.*

**Wave 1 — foundation (one agent; must land first):**
- [ ] **4.1 Flip `ProfileAvatar` to link-by-default.** In `DesignSystem.swift`: navigation is ON whenever `userId != nil`; replace `linked: Bool = false` with an opt-out (`unlinked: Bool = false` or `.static` variant) for avatars inside already-tappable containers. Rename the raw `init(url:initials:)` to a semantic `init(guest:)`/`init(preview:)` so a nil-profile avatar states why. Update all 16 call sites: sites currently wrapped in `ProfileLink` keep the wrap (avoid double-navigation — audit each; inside `ProfileLink`/tappable cards use the opt-out), inert-but-real sites (`InviteView:117`, others) become linked, fake/preview sites (`OnboardingPreview`) use the semantic init. Files: `DesignSystem.swift` + every avatar call site. Effort: **M**. Risk: medium (double-navigation traps — verify each site on simulator with the demo account).
- [ ] **4.2 Introduce `PersonRef`.** Small struct (id: UUID?, displayName, handle?, avatarURL?, initials) in `ProfileModels.swift` with inits from `Profile`/`ParticipantProfile`/guest-name. `ProfileAvatar` and `IdentityRow` gain `PersonRef` initializers. Nil `id` = guest = non-navigable by construction. Effort: **S**. Risk: low.

**Wave 2 — adopt (two agents in parallel; after Wave 1):**
- [ ] **4.3 Plumb identity through stats.** `PlayerRecord`/`Rivalry` (`SessionStats.swift`) embed `PersonRef` (populated from `ActivityParticipant.profile` during aggregation; guests keep initials-only). Update `PlayerRecordRow` (`StatsSheet.swift:127`), `RivalRow`/`RivalsSheet` (`RivalsFeature.swift`), partner rows (`ProfileView.swift:226`) to render real avatar + navigation. **This fixes the record-sheet bug.** Effort: **M**. Risk: low.
- [ ] **4.4 Blocked accounts show avatars.** `BlockedAccount` already has `blockedAvatarPath` — sign it via `MediaHydrator` in `loadBlockedAccounts` (`AppStore+Safety.swift`) and render in `SafetySheets.swift:75`. Keep the row non-navigable (deliberate: you blocked them) with a one-line comment saying so. Effort: **S**. Risk: low.
- [ ] **4.5 Unify loading/refresh/haptics on lagging screens.** Skeletons (reuse `SkeletonList`/`SkeletonRow` from `DesignSystem.swift`) replace bare `ProgressView` on FollowListView, NotificationsView, CommentsView, InviteView lists; add `.refreshable` to CommentsView + invite list; add `Haptics` to FollowListView follow/unfollow actions (match the wiring in `AcceptDeclineButtons`). Effort: **M**. Risk: low (visual — screenshot each).

**Wave 3 — tripwires (one agent; after Wave 2):**
- [ ] **4.6 SwiftLint tripwires.** Add `.swiftlint.yml` with custom regex rules only: forbid `ProfileAvatar(url: nil`, forbid `Color(red:`/`Color.white`/`.foregroundColor(.white` outside `DesignSystem.swift`, forbid `DateFormatter()` inside view bodies, forbid direct `OtherProfileView(` outside `ProfileLink`/`RootView`. Add `scripts/lint.sh` (no-op with a hint if swiftlint missing — it is NOT currently installed) + `.github/workflows/lint.yml` running it on PRs. Effort: **S**. Risk: none.
- [ ] **4.7 CLAUDE.md consistency contract.** Five-line section: person rows use `IdentityRow`/`PersonRef`; avatars always navigate when a profile exists (opt-out is the exception and needs a reason); list screens ship skeleton + empty state + `.refreshable`; state-changing taps get `Haptics`; new colors/spacing come from `Theme`. Effort: **S**.

**Verification:** build per wave + simulator screenshots with the signed-in demo account (`@demoplayer` — Test OTP works on sim): record sheet, rivals, blocked accounts, followers list, notifications, comments, invites. **Do-not-do:** no visual redesigns while unifying; no folding `LeaderboardRow`/`CommentRow` into `IdentityRow` (shapes genuinely diverge); no giant `PersonRef` migration of models that already work as `Profile`/`ParticipantProfile`.

---

## Appendix — Mega-file decomposition map

Line ranges are approximate anchors from this review; re-verify before cutting.

**`AppStore.swift` (2,401)** → keep state+lifecycle (1–120) in place; extensions: `+Auth` 121–390 · `+Realtime` 391–642 · `+Feed` 679–830 & 1896–1936 · `+FollowGraph` 846–1142 · `+Safety` 1146–1238 · `+Sessions` 1320–1571 · `+Notifications` 1573–1638 · `+Comments` 1640–1692 · `+Reposts` 1694–1764 · `+Profile` 1013–1054, 1240–1316, 1766–1859 · `+Gear` 1861–1894 · `+Invites` 1938–2092 · `+MediaHelpers` 2094–2375.

**`ProfileSheets.swift` (1,210)** → `MeasuresSheet` 7–96 · `StatsSheet` (+`RecordHero`/`HeroStat`/`RecordSection`/`PlayerRecordRow`) 100–251 · `GearSheets` 255–469 · `SettingsView` 473–545 · `SettingsProfileView` 549–756 · `SettingsSubscreens` 760–862 · `SafetySheets` (`ReportSheet`/`BlockedAccountsView`/`DeleteAccountSheet`) 866–1027 · `LegalDocuments` 1029–1210.

**`RemoteModels.swift` (1,186)** → `ProfileModels` (5–76, 270–291, 775–797, 897–908, 943–969) · `SessionModels` incl. drafts-for-now (89–507, 910–931) · `RepostModels`/`LeaderboardModels` (508–580, may merge) · `NotificationModels` (584–661) · `Comment` models (665–701) · `GearModels` (703–756, 971–981) · `SocialGraphModels` (758–823, 985–995) · `SafetyModels` (825–1020) · `EdgeFunctionModels` (1022–1052) · `InviteModels` (1054–1186). Drafts (`SessionDraft` et al.) ultimately belong in their own on-device-models file.

**`ProfileView.swift` (841)** → extract `WorkoutCalendarCard`+`DayCell` (409–515, fully self-contained), `PostingRow`/`FollowRequestRow`/`RepostRequestRow` (565–746), `RivalRow`/`RivalsSheet` (757–841). Main view (4–371) is already well-factored — leave it.

**`AuthView.swift` (778)** → extract `OnboardingPreviewCard`/`LeaderboardPreviewRow` (591–648), `FriendCandidateRow` (679–726, cross-file reuse), `AuthField`/`SkillLevelButton` (650–758). The 6-step onboarding state machine (~280 lines of per-step computed views) stays but is the file's long-term watch item.

**`LogView.swift` (761)** → extract `ActiveSessionView` + `ActivityEditorRoute`/`AddActivityButton`/`DraftActivityRow` (403–761); consider renaming the remainder `WorkoutView.swift` to match its struct.

**`FeedView.swift` (759)** → extract `FeedCard` + `SessionSummaryStrip`/`ActivityRow`/`InlineCommentRow` (307–707); break `FeedCard.body` (318–550) into computed subviews. `SocialLabel`/`FocusChip` (709–759) → `DesignSystem.swift`.

**`DesignSystem.swift` (616)** — size is appropriate for its role; optional later split into `RemoteImage`/`Navigation`/`HeaderComponents`/`SkeletonLoaders`. Low priority.

**`InviteView.swift` (436)** and **`SessionEditors.swift` (350)** — cohesive; no split needed.

---

## Do-not-do list (tempting but premature)

1. **Full MVVM / per-screen ViewModels.** The single-store pattern with a clean network boundary is working; adding a ViewModel layer now would triple the surface for zero user benefit pre-launch.
2. **Protocol-injecting `supabase`/`PushService`/`LiveActivityManager` today.** No test target exists and none is planned yet; the seams are pure cost until there's a consumer (see 3.2).
3. **Big-bang `EnvironmentObject`-per-domain-store migration.** 13 views, 229 call sites, no measured perf problem. Extension-split first; re-evaluate after.
4. **Over-generalizing the row component.** Fold `LeaderboardRow` (`LeaderboardView.swift:87`) and `CommentRow` (`CommentsView.swift:109`) into `IdentityRow` only if the shapes genuinely converge — rank numbers and reply affordances suggest they won't (Agent C concurred).
5. **`@Observable` migration bundled into the AppStore split.** Two risky changes in one; sequence them (2.1 first, 3.1 later, if ever).
6. **Rewriting the realtime layer around a fancier abstraction than the thin `RealtimeSubscription` wrapper.** It's best-effort refresh plumbing; keep it boring.

## Open questions for the product owner

1. Is `activeDraft` *intentionally* ephemeral (avoid resurrecting days-old sessions)? If so, 1.1 should restore-with-max-age rather than unconditionally.
2. Are orphaned `posted:false` rows (1.5) already pruned by any Supabase-side job? None was found in `migrations/`.
3. Is a test target planned? Changes the priority of 3.2 from "later" to "before 2.1, so the split lands testable."
4. Is `logSession` (1.9) reserved for a future simpler quick-log API, or safe to delete outright?
5. Should `schema.sql` be regenerated or deleted — does anything downstream (docs, setup scripts) actually run it?
