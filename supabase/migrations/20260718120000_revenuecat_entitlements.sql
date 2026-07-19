-- Server-side mirror of RevenueCat subscription state, written only by the
-- revenuecat-webhook edge function (service role). The app never reads this —
-- client truth is the RevenueCat SDK; this exists so edge functions (AI recaps
-- etc.) can verify Pro without trusting the client. Pro == expires_at > now(),
-- which stays correct for CANCELLATION (auto-renew off but still paid up) and
-- for missed EXPIRATION webhooks.

create table if not exists public.entitlements (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  entitlement_id text not null default 'pro',   -- RevenueCat entitlement identifier
  product_id     text,
  status         text,                          -- last webhook event type (INITIAL_PURCHASE, RENEWAL, ...)
  period_type    text,                          -- NORMAL | TRIAL | INTRO
  will_renew     boolean,
  expires_at     timestamptz,                   -- authoritative: pro == expires_at > now()
  environment    text,                          -- SANDBOX | PRODUCTION
  last_event_at  timestamptz,                   -- RevenueCat event_timestamp_ms, out-of-order guard
  updated_at     timestamptz not null default now()
);

alter table public.entitlements enable row level security;
drop policy if exists "entitlements_select_own" on public.entitlements;
create policy "entitlements_select_own" on public.entitlements
  for select to authenticated using (user_id = auth.uid());
grant select on public.entitlements to authenticated;
-- No insert/update/delete policies: only the webhook writes, via service role.

-- Atomic upsert with the out-of-order guard: a stale event (RevenueCat retries
-- and delivery order aren't guaranteed) never overwrites newer state. Returns
-- true when the row was applied, false when skipped as stale.
create or replace function public.apply_revenuecat_event(
  p_user_id      uuid,
  p_product_id   text,
  p_status       text,
  p_period_type  text,
  p_will_renew   boolean,
  p_expires_at   timestamptz,
  p_environment  text,
  p_event_at     timestamptz
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into public.entitlements
    (user_id, product_id, status, period_type, will_renew, expires_at, environment, last_event_at)
  values
    (p_user_id, p_product_id, p_status, p_period_type, p_will_renew, p_expires_at, p_environment, p_event_at)
  on conflict (user_id) do update set
    product_id    = excluded.product_id,
    status        = excluded.status,
    period_type   = excluded.period_type,
    will_renew    = excluded.will_renew,
    expires_at    = excluded.expires_at,
    environment   = excluded.environment,
    last_event_at = excluded.last_event_at,
    updated_at    = now()
  where entitlements.last_event_at is null
     or entitlements.last_event_at <= excluded.last_event_at;
  return found;
end; $$;

-- Webhook-only: not callable from the app.
revoke execute on function public.apply_revenuecat_event from public, anon, authenticated;
