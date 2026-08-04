-- Weight becomes a private log instead of a single number on the profile.
--
-- `profiles.weight_pounds` rode along with public identity: `profiles_read`
-- grants any authenticated, non-blocked user the whole row for a profile they
-- can view, so everyone's current weight was readable. Body data belongs in
-- its own owner-only tables, so the log (`weight_entries`) and its settings
-- (`weight_settings`) live apart from `profiles` and never appear in a feed,
-- leaderboard, or another user's profile.
--
-- DESTRUCTIVE for one column: `profiles.weight_pounds` is dropped, but only
-- after every stored value is backfilled into `weight_entries` as today's
-- weigh-in, so nobody loses their current weight. Reads stay safe for shipped
-- clients (the iOS model decodes the column with `decodeIfPresent`); the write
-- path does not — an older build tapping "Save Weight" sends `weight_pounds`
-- in the profile update body and PostgREST will 400 on the unknown column
-- until that build updates.

create table if not exists public.weight_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  recorded_on   date not null default current_date,
  weight_pounds numeric not null check (weight_pounds > 0 and weight_pounds <= 1500),
  created_at    timestamptz not null default now(),
  -- One weigh-in per day. Logging again the same day corrects that day (the
  -- client upserts on this constraint) instead of stacking points on the chart.
  unique (user_id, recorded_on)
);
create index if not exists weight_entries_user_date_idx
  on public.weight_entries (user_id, recorded_on desc);

create table if not exists public.weight_settings (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  -- Display preference only — pounds are canonical on the wire, so switching
  -- to kg never rewrites the log.
  unit        text not null default 'lb' check (unit in ('lb', 'kg')),
  goal_pounds numeric check (goal_pounds > 0 and goal_pounds <= 1500),
  updated_at  timestamptz not null default now()
);

alter table public.weight_entries  enable row level security;
alter table public.weight_settings enable row level security;

-- ---------------------------------------------------------------------------
-- RLS: owner-only, every verb. There is deliberately no policy that lets
-- anyone else read these rows.
-- ---------------------------------------------------------------------------

drop policy if exists "weight_entries_read"   on public.weight_entries;
drop policy if exists "weight_entries_insert" on public.weight_entries;
drop policy if exists "weight_entries_update" on public.weight_entries;
drop policy if exists "weight_entries_delete" on public.weight_entries;
create policy "weight_entries_read" on public.weight_entries
  for select to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_entries_insert" on public.weight_entries
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_entries_update" on public.weight_entries
  for update to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_entries_delete" on public.weight_entries
  for delete to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "weight_settings_read"   on public.weight_settings;
drop policy if exists "weight_settings_insert" on public.weight_settings;
drop policy if exists "weight_settings_update" on public.weight_settings;
drop policy if exists "weight_settings_delete" on public.weight_settings;
create policy "weight_settings_read" on public.weight_settings
  for select to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_settings_insert" on public.weight_settings
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_settings_update" on public.weight_settings
  for update to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "weight_settings_delete" on public.weight_settings
  for delete to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

-- ---------------------------------------------------------------------------
-- Backfill, then retire the column
-- ---------------------------------------------------------------------------

do $$
declare
  moved bigint;
begin
  with seeded as (
    insert into public.weight_entries (user_id, recorded_on, weight_pounds)
    select id, current_date, weight_pounds
      from public.profiles
     where weight_pounds is not null
       and weight_pounds > 0
       and weight_pounds <= 1500
    on conflict (user_id, recorded_on) do nothing
    returning 1
  )
  select count(*) into moved from seeded;
  raise notice 'seeded % weight_entries row(s) from profiles.weight_pounds', moved;
end $$;

alter table public.profiles
  drop column if exists weight_pounds;
