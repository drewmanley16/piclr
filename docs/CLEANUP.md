# Cleanup backlog

Codebase review, 2026-08-03. Scope: 23.6k Swift LOC / 108 app files, 3 targets, 60 migrations, 7 edge functions.

All counts below were grep- or query-verified against the repo and the live Supabase project. Check items off as they land; delete sections once cleared.

## Summary

The architecture is in better shape than the file sizes suggest. The `AppStore` split worked (`AppStore.swift` is 211 lines of state + select constants, behavior in 14 extensions, now on `@Observable`), the data-layer boundary is clean, and the select-string constants are genuinely reused.

**The debt has moved to the view layer.** The design system stopped keeping pace with feature work, so features hand-roll UI that should be shared — and those copies have already drifted apart. Plus two live backend issues that aren't cleanup at all.

### Verified healthy — don't re-litigate these

- Zero view files import Supabase or issue PostgREST/RPC/edge calls. Realtime is behind the store.
- Zero bypasses of `Analytics`, `Haptics`, or `FeatureFlags` (27 / 93 / 4 call sites respectively).
- No dead methods or unread published state in `AppStore`.
- Select-string constants (`selectProfileLite`, `selectFeedPreview`, …) reused consistently.
- Colors and radii are well tokenized — near-zero hardcoded-color violations; the lint tripwires work.
- `Shared/` is genuinely dependency-free (Foundation only).
- `build/` is gitignored; `.xcodeproj` currently matches `project.yml`.

---

## Tier 0 — Not cleanup, fix now

- [x] **`avatars` storage bucket is `public = true` in production.** ~~Land the fix as a migration.~~ **Resolved as won't-fix-by-design.** The public bucket is correct: profile pictures are always visible, the way they are on Instagram — they are not gated by blocks or private-account status. The real defect was that the schema *claimed* otherwise, since `avatars_read` called `can_read_media` → `can_view_profile`, a check a public bucket never runs. `20260803120000_avatars_public_by_design.sql` records the decision and replaces that policy with an honestly ungated one. `post-photos` and `gear-photos` remain private and gated. **S**
- [x] **`migrations/` is not a trustworthy source of truth.** `waitlist_public_insert` dropped in `20260803120100`; it was byte-identical in effect to the migration-backed `"anon can join waitlist"`. The avatars bucket — the other confirmed hand-edit — is now captured in a migration too, so both known drifts are closed. CI schema diff still outstanding (Tier 5). **S**
- [x] **`delete-account` skips the `gear-photos` bucket** — fixed; `delete-account/index.ts:38` now loops all three buckets. **S**

---

## Tier 1 — Free wins

Mechanical, no behavior change, ~45 call sites. Bundle as one PR.

- [ ] **Adopt the existing `SectionHeader`** — `DesignSystem.swift:688` has **1** adopter against ~13 hand-rolled copies (`LogView:277,290`, `StatsSheet:64,155`, `FeedView:317`, `RivalsFeature:163,182`, `RivalryInsights:68`, `ProfileView:390`, `OtherProfileView:102,300`, `NotificationsView:83`, `GearSheets:197`). Add `= nil` defaults to `actionTitle`/`action` so adoption isn't verbose. **S**
- [ ] **Consolidate two duplicated name helpers** — two-letter initials (8 copies: `ProfileModels:79,154,214`, `SocialModels:24`, `SafetyModels:16`, `CommentModels:36`, `DraftModels:37`, `AppStore+Auth:279`, `FeedCard:762`) and first-name-only (5 copies: `ActiveSessionView:645`, `FeedCard:665,759`, `InviteSharing:42`, `RivalsFeature:65`). Fallback strings differ ("PB"/"?"/"–") — reconcile while merging. **S**
- [ ] **`selectFollowEdge` constant + `fetchFollowEdges()` helper** — `"follower_id, followee_id, status, created_at"` is retyped verbatim 8× (`AppStore+FollowGraph:29,37,71,78,120,138,297`, `AppStore+Profile:243`). `selectInvite` in `AppStore+Invites:7` is the pattern to copy. **S**
- [ ] **Shared `refreshPostMutationSurfaces(userId:)`** — `loadMySessions` + `loadFeed` copy-pasted 7× (`AppStore+Sessions:360,422,444`, `AppStore+Reposts:27,53,78`, `AppStore+Feed:240`). **S**
- [ ] **Delete dead `SocialAction`** — `DesignSystem.swift:129`, zero call sites. **S**
- [ ] **Fix `SettingsProfileView`'s birthday formatter** — `SettingsProfileView.swift:45-49` re-derives `DateFormatting.postgresDate` but omits the `timeZone` line that formatter exists to set, reintroducing the off-by-one-day bug. Use `DateFormatting.postgresDate`. **S**
- [ ] **`blockUser` runs 7 sequential `await`s** (`AppStore+Safety.swift:56-62`) where every other fan-out uses `async let`. Worst-latency mutation in the store. **S**
- [ ] **Move `Milestone` out of `Milestones.swift`** into its own Models file — it's the one model-shaped type without one. **S**
- [ ] **`SessionRecord.color`** (`FeedCard.swift:553`) re-derives what `MatchResult.color` already does, and misses `Theme.tie`. **S**
- [ ] **Extract `MediaHydrator`'s repeated avatar walk** — the collection and mapping logic is written twice in one function, once for the session and once for its repost `source` (`MediaHydrator.swift:98-111`, `132-161`). **S**

---

## Tier 2 — Missing shared components

The design system covers *identity* well (`ProfileAvatar`, `IdentityRow`, `ProfileLink` are healthy) but has no vocabulary for **actions, sheets, or empty states** — so every feature reinvents them. One component per PR, migrating call sites as you go. This is where the compounding payoff is.

- [ ] **`PrimaryButtonStyle`** — the full-width accent CTA is hand-built **17×** across 10 files, with `minHeight` drifting 44/48/50/52/54/56. `AuthView` alone has 5. **M**
- [ ] **`EmptyStateView(icon:title:subtitle:action:)`** — ~21 hand-rolled icon+title+subtitle blocks across 16 files. Also gives `CONVENTIONS.md`'s "every list screen ships an empty state" rule something to point at. **M**
- [ ] **`sheetToolbar(cancel:confirm:)` modifier** — 35 `ToolbarItem(.cancellationAction/.confirmationAction)` blocks across ~21 files. **S/M**
- [ ] **`destructiveConfirmation` modifier** — 19 `confirmationDialog`s / 36 destructive buttons. **This has already caused drift:** `FollowListView`'s block/unfollow dialogs fire `Haptics`, `OtherProfileView:145,218,238`'s identical copies don't. Bake the haptic into the modifier so no call site can forget. Fold in the `capsuleLabel` helper duplicated between `OtherProfileView:270` and `FollowListView:193`. **M**
- [ ] **`FeedCard.headerRow` → `IdentityRow`** — `FeedCard.swift:129-146` hand-builds exactly `IdentityRow`'s shape on the app's highest-traffic row. Same for `SafetySheets:73` and `InviteView:106`. **S**
- [ ] **Adopt existing `StatSegment`** for 3 bespoke stat tiles (`ActiveSessionView:342`, `FeedCard:504`, `StatsSheet:132`). **S**
- [ ] **Adopt existing `SegmentedControl`** for `WeightSheet`'s unit toggle (`WeightSheet:165`) — straight swap, and it already fires the haptic the toggle duplicates by hand. **S**
- [ ] **`PillPicker`** — individually-capsuled range/metric selectors, 3–5 sites (`ProfileView:661,749`, `WeightSheet:459`). **M**
- [ ] **`HairlineDivider`** — `Divider().overlay(Theme.hairline)` appears 27×. Low priority, but guarantees nobody forgets the overlay. **S**
- [ ] **Route giant scoreboard numerals through `Theme.scoreboard(_:)`** — `StatsSheet:104-110` and `ShareCard:57-63` reimplement it with inconsistent weights. **S**

---

## Tier 3 — Systemic

- [ ] **`Theme` has no spacing or type scale**, but `CONVENTIONS.md` claims spacing is tokenized. Reality: **215** numeric `.padding()` literals, **29** raw `.font(.system(size:))`. Land the tokens first for new code; retrofit opportunistically; don't lint-enforce until coverage is real. **L**
- [ ] **52 hand-written `CodingKeys` blocks**, no `keyDecodingStrategy` configured anywhere. Largest single boilerplate item in the codebase. Thread a snake_case decoder through the query layer; keep manual keys only where fields genuinely don't map (`WeightEntry.day` ← `recorded_on`, `blocked_id`, …). **L**
- [ ] **Finish the `PersonRef` migration** — `Profile`, `ParticipantProfile`, `LeaderboardEntry`, `BlockedAccount` each re-declare the same identity fields, which is why `ProfileAvatar` carries 4 parallel inits (`DesignSystem:249,253,257,262`). Collapsing them removes the overloads and gets callers onto the path the docs already specify. **M**
- [ ] **Type the enums that mirror DB CHECK constraints** — `role` (6 raw-string sites), follow `status` (~10), notification `type`. This has already rotted twice: `"repost"` is dead client code (dropped from the constraint in `20260725120000`), and `"squad_invite"` is a live DB type with no client handling that silently falls through to a generic message. `RSVPStatus` (`InviteModels:28`) is the template. **M**
- [ ] **Extract the paginated session-query core** — `loadFeed` (`AppStore+Feed:9-99`) and `loadDiscover` (`:102-175`) are ~90-line near-clones with the same empty-page-skip loop and hydrate/reconcile dance; a third copy is in `loadPublicProfile` (`AppStore+Profile:266-289`). ~140 lines. **M**
- [ ] **Stop the background fan-out writing shared `errorMessage`** — `loadSignedInData` (`AppStore+Auth:263-271`) starts 9 concurrent loads that all call `reportError`, the same clobbering class `feedLoadError`/`discoverLoadError` were split out to fix (see the comment at `AppStore.swift:37-43`). A flaky `loadGear` can pop an alert mid-unrelated-action. **S/M**
- [ ] **Write down the `busyCount` vs optimistic-UI rule**, then bring ~10 straggler write methods in line (`createInvite`, `cancelInvite`, `setGearVisible`, `deleteGear`, `deleteWeightEntry`, `updatePrivacy`, `updateGoalPrefs`). 23 methods follow the busy pattern, ~17 don't, and some of those are correctly optimistic — the problem is that nothing says which is which. **M**
- [ ] **Move presentation logic off `Decodable` DTOs** into extensions, following `MatchResult.color`'s precedent. ~10 types, worst offenders `FeedSession` (5 formatting properties) and `AppNotification` (a 15-case copy switch). **M**
- [ ] **Decompositions:** `DesignSystem.swift` 854 → ~9 concern-scoped files; `ProfileView` 1005 (splits along existing MARKs, the activity chart alone is 200 lines); `AuthView` 784 (splits cleanly along its `Step` enum); `WeightSheet` 663; `ActiveSessionView.detailsCard` (109-line computed property mixing 5 concerns). **M–L**

---

## Tier 4 — Backend

- [ ] **Add `supabase/functions/_shared/`** — `corsHeaders` (3 functions), the `json()` helper (all 7, in two shapes), user+admin client bootstrap (3), bearer-secret auth (4), and `escapeHtml` + Resend send (`report-notify` and `waitlist-notify` are ~70% identical). ~150–200 duplicated lines; turns a CORS or auth fix from a 7-file edit into one. **M**
- [ ] **Standardize edge-function error handling** — `report-notify` and `waitlist-notify` don't log at all and return `String(err)` to the caller, leaking internals and leaving nothing in the logs. The other 5 log + return a generic message. **S**
- [ ] **Sweep bare `auth.uid()` → `(select auth.uid())`** — 9 policies flagged live by the performance advisor (`device_tokens` ×2, `gear` ×3, `milestone_unlocks` ×2, `profiles_insert`, `entitlements_select_own`). Add `to authenticated` to `milestone_unlocks`, which omits it unlike every peer table. **M**
- [ ] **Apply the own-folder read shortcut to `avatars_read`/`gear_photos_read`** — `post_photos_read` got it reactively after `upsert:true` uploads 403'd; the other two are safe only by the implicit invariant that they don't use `upsert:true`. Fix proactively. **S**
- [ ] **`revoke execute` on 13 trigger-only `SECURITY DEFINER` functions** currently callable via anon RPC. `create_own_session` already does this — follow its pattern. **S**
- [ ] **Drop redundant permissive policies** — `activity_participants` DELETE (×2), `session_activities` SELECT (the `FOR ALL` write policy already covers it), `waitlist` INSERT. **S**
- [ ] **Add the 5 unindexed FKs** flagged by the advisor. None are hot paths today; it's a 5-line migration. **S**
- [ ] **RLS regression tests for `squads` (7 policies) and `blocks`/`reports`** — the latter introduced the blocked-user predicate used everywhere. `BACKEND.md` already asks for tests "when a policy is subtle." **M**
- [ ] **Consider a baseline squash** — `create_own_session`/`update_own_session` are fully re-pasted across 5 migrations (~1,000 cumulative lines) because `CREATE OR REPLACE` needs the whole body. Reading 5 versions to find the current one is the main onboarding cost across the 60 files. Preserve the good explanatory comments in the new baseline header. **L**

---

## Tier 5 — Guardrails

Do these **before** the Tier 2/3 refactors so CI catches breakage.

- [ ] **XcodeGen drift check** — `xcodegen generate && git diff --exit-code`. Currently in sync, but nothing enforces it despite `CLAUDE.md` opening with "do not hand-edit the `.xcodeproj`." **S**
- [ ] **Add a build job to CI** — it's lint-only today; a PR that breaks compilation is only caught locally. The command is already in `CLAUDE.md`'s fallback section. **M**
- [ ] **Run the 5 existing pgTAP tests** in `supabase/tests/database/` — they currently run nowhere. Add a migration-ordering check while you're there. **M**
- [ ] **Pin SwiftLint's version** — `brew install swiftlint` is unpinned, which erodes the "verified zero violations on the day it lands" guarantee in `.swiftlint.yml`. **S**
- [ ] **Lint `PickleballAIWatch` and `Shared/`** — both currently unlinted (`.swiftlint.yml` `included:` covers only app + widget). Add a grep asserting `Shared/` stays dependency-free. **S**
- [ ] **Trigger CI on push to `main`**, not just `pull_request`. **S**
- [ ] **New lint rules locking in currently-100%-clean behavior** — raw `PostHogSDK.shared.capture`, raw `UI*FeedbackGenerator`, view-layer networking. Cheap now, expensive to restore after drift. **S**
- [ ] **Tighten the `hardcoded_color` rule** from `\.foregroundColor\(\.` to `\.foregroundColor\(` after migrating the 6 remaining deprecated call sites to `.foregroundStyle(`. **S**
- [ ] **Extract shared `WCSession` transport into `Shared/`** — `WatchConnectivityManager.swift` (136 lines) and `WatchConnectivityClient.swift` (128) are ~80% identical: same `sendScore`, same pending-command queue, same delegate pass-throughs. Differences are only the phone's `@MainActor`/`@Published` bookkeeping. Needs paired-simulator verification. **M**
- [ ] **Delete `scripts/ci-setup-cert.sh`** — provisions GitHub secrets for a TestFlight Actions pipeline that doesn't exist and is referenced nowhere. **S**
- [ ] **Have `lint.yml` call `scripts/lint.sh`** instead of duplicating its body — two copies of the same command that can silently diverge. **S**
- [ ] **Doc drift:** `CLAUDE.md` omits `AppStore+Weight.swift` from the extension list and still describes `AppStore` as `ObservableObject`; `BACKEND.md` omits `report-notify` and wrongly says clients can't read `entitlements` (`entitlements_select_own` grants it); `PUSH_SETUP.md`'s open checklist is likely stale; `InviteSharing.swift` is an `AppStore` extension that breaks the `AppStore+Topic.swift` naming convention. **S**

---

## Suggested sequencing

1. **Tier 0 today** — the avatars bucket is a live privacy hole during submission prep.
2. **Tier 1 as one PR** — ~45 sites, mechanical, no behavior change.
3. **Tier 5 guardrails** — before the big refactors, so CI catches breakage.
4. **Tier 2, one component per PR** — the compounding payoff.
5. **Tier 3/4 opportunistically**, when next in that code.
