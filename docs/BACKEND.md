# Backend (Supabase)

Everything server-side lives in `supabase/`. The client-side counterparts are
described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Layout

```
supabase/
├── config.toml          # supabase CLI project config
├── migrations/          # timestamped SQL, applied in order — THE schema source of truth
├── schema.sql           # legacy initial snapshot; do NOT edit or trust for current schema
├── functions/           # Deno edge functions (one dir per function)
└── tests/database/      # pgTAP-style SQL tests for tricky RLS/trigger behavior
```

## Migrations

- **`migrations/` is the schema source of truth**, not `schema.sql`. To learn
  the current shape of a table, read its latest migrations (they're small and
  named by feature, e.g. `20260725000000_repost_notifications.sql`).
- New migration = new file `YYYYMMDDHHMMSS_short_feature_name.sql`. Timestamps
  must sort after every existing file.
- Apply with the Supabase CLI (`supabase db push`) or by pasting into the SQL
  editor; there is no automatic deploy from this repo.
- Schema changes that views depend on usually also need matching Swift model +
  select-string updates (see the PostgREST constants in `AppStore.swift`).

## Edge functions

Deployed with `supabase functions deploy <name>`. Each function's `index.ts`
header documents its required secrets (`supabase secrets set ...`).

| Function | Invoked by | Purpose |
|---|---|---|
| `complete-onboarding` | app | Validates + writes the initial profile (username, names, skill level) |
| `match-contacts` | app | Matches hashed phone contacts against `phone_lookup` |
| `delete-account` | app | Full account deletion (auth user + data) |
| `send-push` | DB trigger via pg_net | Signs an ES256 APNs JWT and delivers a push for one `notifications` row |
| `revenuecat-webhook` | RevenueCat servers | Mirrors subscription events into `public.entitlements` |
| `waitlist-notify` | DB trigger via pg_net | Emails (Resend) when someone joins the waitlist |

Server-to-server functions (`send-push`, `waitlist-notify`, `revenuecat-webhook`)
authenticate with shared bearer secrets, never the anon key.

## Push pipeline

Client side is in [ARCHITECTURE.md](ARCHITECTURE.md#push-notifications-client-side).
Server side: an insert into `notifications` fires the
`on_notification_dispatch_push` trigger, which calls `send-push` via pg_net.
The function URL + shared secret live in **Supabase Vault**
(`push_function_url` / `push_function_key`) — not DB GUCs. Full setup history
and APNs key details: [PUSH_SETUP.md](PUSH_SETUP.md).

## Conventions

- **Storage paths must lowercase the UID.** Swift's `UUID.uuidString` is
  uppercase but storage RLS compares against `auth.uid()::text` (lowercase).
  Always `uid.uuidString.lowercased()` in Storage object paths.
- **RLS everywhere.** Every table has row-level security; new tables need
  policies in the same migration. `supabase/tests/database/` holds regression
  tests for the trickiest policies (threaded comments, tagged reposts) — add
  one when a policy is subtle.
- **`entitlements` is server-only.** Written exclusively by the
  `revenuecat-webhook` function; clients never read or write it.
- **Follow graph is directional.** The `follows` table models directed
  follows with request/accept states — not mutual "friends" (some legacy
  naming survives in discovery UI hooks).

## Local app configuration

`PickleballAI/Supabase.plist` (gitignored) holds the real project URL + anon
key; copy `Supabase.example.plist` and fill it in. `SupabaseConfig` (in
`SupabaseService.swift`) reads it and exposes the app-wide `supabase` client.
Without it the app renders a "config needed" screen.
