# Streaks — Implementation Plan

Status: **planning** · Branch: `feature/streaks`

## Goal

Add a **consistency streak** as the app's core retention mechanic. The streak's
job is habit formation via loss aversion, not achievement. Success = it measurably
lifts weekly return rate (see Analytics).

## Framing (read first)

- Pickleball is **not a daily activity**, so a daily *play* streak is broken by
  design. The streak here is a **weekly play streak**: consecutive calendar weeks
  in which the user logged ≥1 session.
- A daily *engagement* streak (open app + do a drill) is intentionally **out of
  scope** until daily micro-content ("Daily Dink") exists — without daily content
  it's hollow. Revisit as Phase 4.

## Terminology — disambiguate from the existing "streak"

The app already ships a **win streak** (`SessionStats.streakLabel` → `W2`/`L3`),
surfaced in `LogView.weekStrip` and `ProfileView.recordCard` / `StatsSheet`. That
is a *performance* stat and does nothing for retention.

- **Rename all existing UI of that stat to "Win streak"** to free the word
  "Streak" for the new consistency mechanic. (Copy-only change; keep the
  computation.)
- New consistency streak is referred to as **"streak"** with a 🔥 flame.

## Definitions

- **Play week:** an ISO week (`Calendar.dateInterval(of: .weekOfYear)`) containing
  ≥1 `sessions` row for the user (`created_at`, or `started_at` if present).
- **Current streak (weeks):** the count of consecutive play weeks ending at the
  most recent play week. The **current week is "in progress"** — it does not break
  the streak until a *full* week passes with no session.
- **Break rule:** the streak resets to 0 only when an entire ISO week elapses with
  no session (minus any freeze — Phase 3).
- **Qualifying action (v1):** a logged `session`. (Consider also counting a sent
  invite / RSVP later; start strict = a real session.)

## Phased plan

### Phase 1 — Weekly play streak (no backend, ship first)
Pure client computation from `store.mySessions`. No schema change.

- **Compute:** add `weeklyStreak: Int` and `longestWeeklyStreak: Int` to
  `SessionStats` (or a dedicated `StreakStats` struct in `SessionStats.swift`).
  Algorithm: map sessions → set of ISO-week start dates; walk backwards from the
  current week counting consecutive weeks; current week counts as "in progress"
  and never breaks the chain on its own.
- **UI:**
  - `LogView.weekStrip` — replace the win-streak cell (or add a cell) with the
    🔥 consistency streak ("6 wk").
  - `ProfileView` — a prominent streak element near the top (its own small card or
    in the record/profile row) with the flame + week count + "longest".
  - Rename the existing win-streak labels to "Win streak" (LogView, ProfileView,
    StatsSheet).
- **Milestone celebration:** at 4 / 12 / 26 / 52 weeks, reuse the existing
  `CelebrationView` (confetti + haptic) when a session post crosses a milestone.
  Trigger from `AppStore.postSession` success by comparing streak before/after.
- **Empty/new state:** "Log a session this week to start a streak." No guilt at 0.

**Acceptance:** streak shows correctly for known data; increments when this week's
first session is logged; survives leaving/returning; win-streak relabeled
everywhere; milestone fires once per threshold crossing.

### Phase 2 — "Streak ends" push notification (highest-ROI item)
The single biggest retention lever: remind users before they lose it.

- **New notification type `streak`** — extend the `notifications_type_check`
  constraint (follow the pattern in `20260715130000_rivalries_and_leaderboard.sql`)
  and add a `case "streak"` to `send-push/index.ts buildMessage`, using the
  `detail` column for the phrase (e.g. *"Your 6-week streak ends Sunday — log a
  session to keep it."*).
- **Scheduling:** there is **no scheduler today** (no pg_cron). Options:
  1. **pg_cron** (enable extension) + a SQL function that, on a schedule (e.g. Sat
     & Sun mornings), inserts a `streak` notification for every user who has an
     active streak ≥2 and **no session in the current ISO week**. The existing
     `on_notification_dispatch_push` trigger then delivers it.
  2. A **Supabase Scheduled Edge Function** (cron) doing the same via service role.
  - Recommend option 1 (keeps logic in the DB next to the data; reuses the push
    trigger). Gate the query so a user gets **at most one** streak reminder per
    week (check for an existing unread `streak` notif this week).
- **Targeting:** only users with `device_tokens`, streak ≥ 2, and no session this
  week. Respect the `notificationsEnabled` preference.

**Acceptance:** a test user with a 2+ week streak and no session this week receives
exactly one reminder; users who already played this week get none.

### Phase 3 — Streak freeze + repair (persistence + monetization)
Removes the anxiety that makes users abandon broken streaks; first paid lever.

- **Schema:** `user_streaks` table — `user_id (pk)`, `current_weeks`,
  `longest_weeks`, `freezes_available int default 1`, `last_active_week date`,
  `updated_at`. Maintain via a trigger on `sessions` insert **or** recompute
  app-side on load and persist. RLS: user reads own row; writes via
  `security definer` RPCs (`use_streak_freeze`, `repair_streak`).
- **Freeze:** if a week would break the streak and `freezes_available > 0`, consume
  one to preserve it. 1 free; more are earned (milestones) or **purchased in Super
  pickleball.ai** (ties into the paywall scaffold on `feature/paywall-scaffold`).
- **Repair:** one-tap restore of a just-lost streak — free once, then paid.
- **UI:** freeze indicator on the streak; a sheet to buy/apply freezes; repair
  prompt when a streak breaks.

**Acceptance:** a missed week with a freeze available preserves the streak and
decrements freezes; repair restores a broken streak; paid freezes gate on
entitlement.

### Phase 4 — Daily engagement streak (deferred)
Only after "Daily Dink" daily content exists. A separate daily streak for opening
the app + doing the daily rep. Do **not** build now.

## Data model summary
- Phase 1–2: **no new tables** (streak computed from `sessions`; notifications reuse
  existing table + a new `type`).
- Phase 3: **`user_streaks`** table + two RPCs.

## Monetization hooks (Super pickleball.ai)
- Extra streak freezes and instant streak repair are premium items — the cleanest,
  least-annoying first purchase (Duolingo's model). Wire through the existing
  `SubscriptionStore` / entitlement gating on the paywall branch.

## Analytics (wire into the metrics dashboard)
Track so we can prove it works:
- % of active users with an active streak; streak length distribution.
- Week-over-week retention **with vs. without** an active streak (the key proof).
- Streak-reminder push → session-within-48h conversion.
- Freeze usage and freeze/repair purchase rate.

## Humane-design guardrails
- Weekly cadence + a freeze buffer so a normal vacation doesn't nuke a long streak.
- Qualifying action must be a **real session**, never "opened the app" — keep the
  metric honest and the habit meaningful.
- No dark-pattern guilt at 0; loss-aversion messaging only once a streak exists.

## File touch list
- `PickleballAI/SessionStats.swift` — add weekly streak computation.
- `PickleballAI/LogView.swift` — weekStrip streak cell + rename win-streak.
- `PickleballAI/ProfileView.swift` / `ProfileSheets.swift` — streak UI + rename.
- `PickleballAI/AppStore.swift` — milestone trigger on `postSession`; Phase 3 RPC calls.
- `PickleballAI/Celebration.swift` — reuse for milestones.
- `supabase/migrations/…_streaks.sql` — Phase 2 type + Phase 3 `user_streaks` + RPCs + pg_cron.
- `supabase/functions/send-push/index.ts` — `streak` message case.

## Suggested sequencing
1. **Phase 1** (client streak + rename + milestone) — ship, low risk, immediate value.
2. **Phase 2** (streak-ends push) — biggest retention win; needs pg_cron setup.
3. **Phase 3** (freeze/repair + Super) — after the paywall lands.
