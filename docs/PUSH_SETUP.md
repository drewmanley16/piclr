# Push notifications (APNs) setup

## Status (2026-07-14)

Backend is **configured and live** on project `jdokoljojvrmaxhjjqbe`:
- Edge-function secrets set (`APNS_KEY`/`APNS_KEY_ID=58JH7R76G9`/`APNS_TEAM_ID`/
  `APNS_BUNDLE_ID`/`APNS_HOST=api.push.apple.com`/`PUSH_FUNCTION_SECRET`).
- `send-push` deployed; `device_tokens` + RPC + dispatch trigger applied.
- Function URL + shared secret stored in **Supabase Vault**
  (`push_function_url`, `push_function_key`); the trigger reads them.
- App entitlement set to `production` (matches TestFlight / `api.push.apple.com`).

**Remaining (needs you):**
1. Apple portal → enable **Push Notifications** on the `com.pickleball.ai` App ID.
2. Rebuild + ship to TestFlight so the signed build carries the push entitlement.
3. Install, tap **Allow**, then trigger a notification (e.g. have a friend like
   your session) to confirm delivery on a real device.

The sections below document the setup for reference / re-provisioning.

---

The app code, `device_tokens` table, dispatch trigger, and `send-push` edge
function are all in the repo. None of this can be tested end-to-end on the
simulator — you need a real device.

## 1. Apple Developer

1. **App ID capability** — developer.apple.com → Identifiers → `com.pickleball.ai`
   → enable **Push Notifications**. Regenerate/download the provisioning profile
   (Xcode automatic signing will do this for you on next build).
2. **APNs Auth Key** — developer.apple.com → Keys → **+** → enable
   **Apple Push Notifications service (APNs)** → download the `.p8`
   (you only get to download it once). Note the **Key ID** (10 chars) and your
   **Team ID** (`X9H68STU8F`).

## 2. Entitlement environment

`PickleballAI/PickleballAI.entitlements` ships with `aps-environment =
development` (correct for Xcode → device builds, which use
`api.sandbox.push.apple.com`).

For **TestFlight / App Store** builds, this must be `production` and the edge
function must target `api.push.apple.com` (see `APNS_HOST` below). The `.p8`
auth key works for both environments — only the entitlement + host differ.

## 3. Supabase secrets (edge function)

```
supabase secrets set \
  PUSH_FUNCTION_SECRET="$(openssl rand -hex 32)" \
  APNS_KEY="$(cat AuthKey_XXXXXXXXXX.p8)" \
  APNS_KEY_ID="XXXXXXXXXX" \
  APNS_TEAM_ID="X9H68STU8F" \
  APNS_BUNDLE_ID="com.pickleball.ai" \
  APNS_HOST="api.sandbox.push.apple.com"   # api.push.apple.com for TestFlight/prod
```

Deploy the function:

```
supabase functions deploy send-push
```

## 4. Wire the dispatch trigger (Supabase Vault)

The `on_notification_dispatch_push` trigger calls the function via `pg_net`,
reading the endpoint + shared secret from **Vault** (the Management API SQL role
can't set custom `app.settings.*` GUCs, so Vault is used instead). It no-ops
until both secrets exist. Store them (secret must equal `PUSH_FUNCTION_SECRET`):

```sql
select vault.create_secret(
  'https://jdokoljojvrmaxhjjqbe.supabase.co/functions/v1/send-push',
  'push_function_url');
select vault.create_secret('<same value as PUSH_FUNCTION_SECRET>',
  'push_function_key');
-- to rotate later: select vault.update_secret(<uuid>, '<new value>');
```

## 5. Apply the migration

`supabase/migrations/20260714120000_push_notifications.sql` creates
`device_tokens`, the `register_device_token` RPC, and the dispatch trigger.
Apply with `supabase db push` (or the dashboard).

## How it flows

1. On sign-in the app requests notification permission and registers with APNs.
2. The device token is stored via `register_device_token` (SECURITY DEFINER
   upsert, so a device that switches accounts reassigns cleanly).
3. Any DB trigger that inserts a `notifications` row fires
   `dispatch_push_notification`, which async-POSTs `{notification_id}` to
   `send-push`.
4. `send-push` loads the notification + recipient's tokens, signs an ES256 JWT
   with the `.p8`, and delivers to APNs. Dead tokens (410/400) are pruned.

## Testing the client without APNs

Simulator can render a local push payload:

```
xcrun simctl push booted com.pickleball.ai payload.apns
```

(Requires the app to have been granted permission first.) This validates the
banner + foreground presentation, not real APNs delivery.
