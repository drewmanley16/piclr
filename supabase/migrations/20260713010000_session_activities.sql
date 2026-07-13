-- Rich session logging: a session is a container of activities (practice or
-- match). Match activities tag the people you played with/against — either app
-- members (profile_id) or free-text guests (guest_name).

alter table public.sessions add column if not exists started_at timestamptz;
alter table public.sessions add column if not exists ended_at   timestamptz;

create table if not exists public.session_activities (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references public.sessions(id) on delete cascade,
  kind           text not null check (kind in ('practice', 'match')),
  position       int  not null default 0,
  -- practice
  focus          text,
  reps           text,
  notes          text,
  -- match
  team_score     int,
  opponent_score int,
  won            boolean,
  created_at     timestamptz not null default now()
);
create index if not exists session_activities_session_idx
  on public.session_activities (session_id, position);

create table if not exists public.activity_participants (
  id          uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.session_activities(id) on delete cascade,
  session_id  uuid not null references public.sessions(id) on delete cascade,
  profile_id  uuid references public.profiles(id) on delete set null,
  guest_name  text,
  role        text not null check (role in ('partner', 'opponent')),
  created_at  timestamptz not null default now(),
  check (profile_id is not null or guest_name is not null)
);
create index if not exists activity_participants_activity_idx
  on public.activity_participants (activity_id);
create index if not exists activity_participants_profile_idx
  on public.activity_participants (profile_id);
create index if not exists activity_participants_session_idx
  on public.activity_participants (session_id);

-- =========================================================
-- RLS: children are readable like sessions; only the session owner writes them.
-- =========================================================

alter table public.session_activities   enable row level security;
alter table public.activity_participants enable row level security;

drop policy if exists "session_activities_read"   on public.session_activities;
drop policy if exists "session_activities_write"  on public.session_activities;
create policy "session_activities_read" on public.session_activities
  for select to authenticated using (true);
create policy "session_activities_write" on public.session_activities
  for all to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid()))
  with check (exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid()));

drop policy if exists "activity_participants_read"  on public.activity_participants;
drop policy if exists "activity_participants_write" on public.activity_participants;
create policy "activity_participants_read" on public.activity_participants
  for select to authenticated using (true);
create policy "activity_participants_write" on public.activity_participants
  for all to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid()))
  with check (exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid()));
