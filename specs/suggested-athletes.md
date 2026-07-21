# Spec: Suggested Athletes

## Objective
Add a horizontally-scrolling "Suggested Athletes" card row to the Home feed, inserted immediately after the first post, to help users find and follow more people. Cards show avatar, username, a "Featured"/reason label, a Follow button, and a dismiss (X) that permanently hides that suggestion for the user. Matches the visual reference: rounded dark cards, circular avatar, blue pill Follow button, small X in the top-right corner, "Invite a friend" affordance in the section header.

Success = users discover and follow relevant people (their followers'/following's connections first) directly from the feed, with dismissals that stick.

## Ranking logic (source of suggestions)
Priority order, deduped, capped at ~15 candidates per load:

1. **Second-degree follow graph** (the "also followed by people you know" signal the user asked for):
   - People followed by accounts the current user follows ("friends of friends")
   - People who follow the current user's followers (mutual-audience signal)
   - Combine both sets, rank by overlap count (how many of the user's follows/followers connect to this candidate) descending.
2. **Fallback heuristic** (only used to top up if step 1 yields < 15): profiles with `onboarding_completed_at` set, ordered by recent activity (e.g. `last_session_at` / `created_at` desc), excluding anyone already covered.

Always exclude, at the query level:
- The current user themself
- Anyone already followed or with a pending outgoing follow request (`requestedFollowIds`)
- Anyone blocked (either direction)
- Anyone the user has dismissed (see below)

## Data model

**New Postgres RPC**: `suggested_athletes(p_limit int default 15)`
Returns `(user_id uuid, mutual_count int)`, computed via the graph query above, excluding dismissed/blocked/followed/self server-side. The ranking logic lives in one place and isn't duplicated client-side.

The public RPC is a `SECURITY INVOKER` wrapper and never accepts a user ID. It derives the viewer from `auth.uid()` through a privileged implementation in the non-exposed `suggested_internal` schema.

**New table**: `dismissed_suggestions`
```sql
create table dismissed_suggestions (
  user_id uuid not null references profiles(id) on delete cascade,
  dismissed_user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, dismissed_user_id)
);
-- RLS: user can insert/select/delete only rows where user_id = auth.uid()
```

**New Swift model** (`SocialModels.swift`):
```swift
struct SuggestedAthlete: Identifiable, Decodable, Hashable {
    var id: UUID { profile.id }
    let profile: Profile
    let mutualCount: Int
    var reasonLabel: String { mutualCount > 0 ? "Followed by \(mutualCount) you know" : "Featured" }
}
```

## Client architecture

- `AppStore+FollowGraph.swift`: add
  - `@Published var suggestedAthletes: [SuggestedAthlete] = []`
  - `func loadSuggestedAthletes()` — calls the RPC via PostgREST, hydrates `Profile` rows (reuse the `profilesByID(for:)` batch-hydration helper), filters anything that became stale (e.g. followed since load).
  - `func dismissSuggestion(userId: UUID)` — optimistically removes from `suggestedAthletes`, inserts into `dismissed_suggestions` via PostgREST; on failure, re-insert into the array and surface an error (reuse existing error-toast pattern in `AppStore`).
  - Follow action on a card reuses existing `sendFollowRequest(to:)`; on success, remove the card from `suggestedAthletes` (optimistic, matching `unfollow`'s existing pattern).
- Call `loadSuggestedAthletes()` from `loadSignedInData(userId:)` fan-out (per CLAUDE.md convention for new initial loads).
- New view: `SuggestedAthletesRow.swift`
  - `ScrollView(.horizontal, showsIndicators: false)` + `HStack` of `SuggestedAthleteCard` (new small view), following the chip-scroll structure already used in `ProfileView.swift` L468-487.
  - Section header: "Suggested Athletes" (Theme title style) + trailing "+ Invite a friend" button reusing whatever the existing invite/contact-matching entry point is (check `FindFriendsSheet` for the current invite action to reuse rather than duplicate).
  - `SuggestedAthleteCard`: `ProfileAvatar(profile:, unlinked: true, size: ...)` (unlinked since it's inside a tappable card — tapping the card itself, not just the avatar, should navigate to the profile), username, `reasonLabel` in secondary text color, `Follow` button (`Haptics` on tap per UI contract), X button top-trailing that calls `dismissSuggestion`.
  - `.cardStyle()` per card, `Theme` tokens only, no hardcoded colors/spacing.
  - Layout: card width sized so ~3 cards fit on screen with a peek of a 4th card's edge (matches reference screenshot) — free horizontal scroll, **no explicit "see more" button/pagination**; RPC still returns up to ~15 candidates so scrolling reveals the rest.
  - Skeleton: while `suggestedAthletes` is loading, render 3 `SuggestedAthleteCard`-shaped skeleton placeholders (shimmer, per `SkeletonList` conventions) instead of showing nothing.
  - "Invite a friend" reuses the exact existing invite entry point from `FindFriendsSheet` (same action/sheet), not a new flow.
- **FeedView.swift**: insert `SuggestedAthletesRow` into the feed's `List`/`LazyVStack` immediately after the first post item (index 1), not as a pinned header — i.e. conditionally render it as a row between `feedItems[0]` and `feedItems[1]` once loading has started (shows skeleton first, then real cards, then disappears entirely if `suggestedAthletes` ends up empty post-load).

## Testing Strategy
No test target in this repo (per CLAUDE.md). Verification = build via `xcodegen generate && xcodebuild ...` + simulator screenshot of the feed showing the skeleton then the row after the first post, tap-Follow removes the card, tap-X removes the card and survives an app relaunch (persisted dismissal), horizontal scroll reveals cards beyond the first 3. Manually verify the RPC via `supabase` SQL editor or a quick `psql` query against a seeded follow graph.

## Boundaries
- Always: reuse `sendFollowRequest`/`unfollow`, `ProfileAvatar`, `Theme` tokens, `Haptics` on Follow/X taps, `ProfileNavigationStack` if this row's card tap needs to push into a profile from a context where one might not already exist, and the existing `FindFriendsSheet` invite action for "Invite a friend".
- Ask first: the new migration (table + RPC) before applying it; any change to `loadSignedInData` ordering if it risks feed load latency.
- Never: duplicate the graph-ranking logic client-side — it belongs in the RPC only.

## Plan

**Order of work** (each step buildable/verifiable before the next):

1. **DB layer** — migration adding `dismissed_suggestions` table (+ RLS) and `suggested_athletes(p_limit)` RPC. No client changes yet; verify via SQL editor against seeded data.
2. **Models** — `SuggestedAthlete` in `SocialModels.swift`.
3. **Store** — `suggestedAthletes` published state + `loadSuggestedAthletes()` / `dismissSuggestion(userId:)` in `AppStore+FollowGraph.swift`; wire into `loadSignedInData`'s existing `async let` fan-out (`AppStore+Auth.swift:227-256`), alongside `loadFollowState` etc. Verify with a breakpoint/log, no UI yet.
4. **UI** — `SuggestedAthleteCard` + `SuggestedAthletesRow` (skeleton + loaded states), inserted into `FeedView.swift` after the first post. Verify with simulator screenshot.
5. **Invite wiring** — swap the row's "+ Invite a friend" for `InviteShareLink(message: store.inviteShareMessage, subject: "Join me on pickleball.ai", source: "suggested_athletes")`, matching `FindFriendsSheet`'s usage exactly but with a distinct `source` for analytics.
6. **Polish/verify** — haptics, lint, full manual pass (follow, dismiss, relaunch-persists, scroll).

**Risks**: RPC correctness on graph queries (test against a seeded follow graph with known mutuals before touching Swift); `loadSignedInData`'s background fan-out already awaits a tuple — adding one more `async let` is mechanical but must not become the *first* awaited call (keep it non-blocking, after `loadFeed()`).

## Tasks

- [ ] Task: Add `dismissed_suggestions` table + RLS policies
  - Acceptance: table exists, RLS restricts all ops to `user_id = auth.uid()`
  - Verify: apply migration locally, `insert`/`select`/`delete` as two different test users, confirm cross-user access is denied
  - Files: `supabase/migrations/<timestamp>_suggested_athletes.sql`

- [ ] Task: Add `suggested_athletes(p_limit int default 15)` RPC
  - Acceptance: returns `(user_id, mutual_count)` ranked by 2nd-degree overlap desc, falls back to recent-activity ordering to fill to `p_limit`, excludes self/followed/pending/blocked/dismissed
  - Verify: call via SQL editor against seeded profiles/follows fixture with known mutuals; confirm ranking and exclusions
  - Files: same migration file as above (append `create function`)

- [ ] Task: Add `SuggestedAthlete` model
  - Acceptance: `Identifiable, Decodable, Hashable`, decodes RPC response + hydrated `Profile`, computed `reasonLabel`
  - Verify: builds; a quick unit decode in a scratch `#Preview` or debug print against a sample JSON payload
  - Files: `PickleballAI/SocialModels.swift`

- [ ] Task: Add store state + load/dismiss methods
  - Acceptance: `AppStore.suggestedAthletes` populates from the RPC + `profilesByID(for:)` hydration; `dismissSuggestion(userId:)` optimistically removes and persists via insert into `dismissed_suggestions`, rolls back on failure; `loadSuggestedAthletes()` called from `loadSignedInData`'s background `async let` fan-out
  - Verify: build; log/breakpoint confirms population on sign-in and correct removal on dismiss/follow
  - Files: `PickleballAI/AppStore+FollowGraph.swift`, `PickleballAI/AppStore+Auth.swift`

- [ ] Task: Build `SuggestedAthleteCard` view
  - Acceptance: `.cardStyle()`, `ProfileAvatar(profile:, unlinked: true)`, username, `reasonLabel`, Follow button (`Haptics.impact()`, calls `sendFollowRequest(to:)`, removes card on success), X button top-trailing (`Haptics.tap()`, calls `dismissSuggestion`), whole card tappable to navigate to profile (needs `ProfileNavigationStack` context)
  - Verify: `#Preview` with sample `SuggestedAthlete` data renders correctly in dark theme
  - Files: `PickleballAI/SuggestedAthleteCard.swift` (new)

- [ ] Task: Build `SuggestedAthletesRow` (skeleton + loaded + invite header)
  - Acceptance: header "Suggested Athletes" + `InviteShareLink(message: store.inviteShareMessage, subject: "Join me on pickleball.ai", source: "suggested_athletes")` reusing the exact component from `FindFriendsSheet`; `ScrollView(.horizontal)` sized so ~3 cards + peek of 4th are visible; shows `SkeletonList(rows: 3)`-equivalent shimmer while loading, real cards once loaded, hides entirely if empty post-load
  - Verify: simulator screenshot in both skeleton and loaded states
  - Files: `PickleballAI/SuggestedAthletesRow.swift` (new)

- [ ] Task: Insert row into Home feed after first post
  - Acceptance: row renders between `feedItems[0]` and `feedItems[1]`, doesn't break existing pagination/realtime feed behavior
  - Verify: simulator screenshot of Home tab; scroll feed to confirm no layout break
  - Files: `PickleballAI/FeedView.swift`

- [ ] Task: Full manual verification pass
  - Acceptance: follow removes card + creates follow edge; X removes card + persists after force-quit/relaunch; horizontal scroll reveals beyond first 3; invite opens same share sheet as `FindFriendsSheet`
  - Verify: `xcodegen generate && xcodebuild ... build`, `scripts/lint.sh`, manual run-through on simulator with screenshots
  - Files: n/a (verification only)

## Success Criteria
- Row appears after the first feed post: skeleton first, then real cards once loaded (or disappears if empty).
- ~3 cards visible per screen with a peek of the next, free horizontal scroll, no "see more" button.
- Cards prioritize mutual-connection suggestions over the recency fallback.
- Follow and X both work optimistically with correct rollback on failure.
- A dismissed user does not reappear after force-quitting and relaunching the app.
- "Invite a friend" opens the same flow as the existing `FindFriendsSheet` invite action.
- Build succeeds; SwiftLint custom rules pass (`scripts/lint.sh`).
