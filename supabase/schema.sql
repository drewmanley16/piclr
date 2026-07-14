-- pickleball.ai schema
-- Run this in the Supabase SQL editor (Dashboard -> SQL -> New query).
-- Safe to re-run: uses "if not exists" / "drop policy if exists".

-- =========================================================
-- Schemas
-- =========================================================

create schema if not exists private;
revoke all on schema private from anon, authenticated;

-- =========================================================
-- Tables
-- =========================================================

create table if not exists public.profiles (
  id                       uuid primary key references auth.users(id) on delete cascade,
  username                 text unique not null,
  display_name             text not null,
  avatar_initials          text,
  avatar_url               text,
  home_court               text,
  rating                   numeric,
  skill_level              text,
  onboarding_completed_at  timestamptz,
  paddle                   text,
  preferred_side           text,
  height_inches            numeric,
  weight_pounds            numeric,
  shoe_size                numeric,
  created_at               timestamptz not null default now()
);

-- Keep existing projects in sync when this schema is re-run.
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists skill_level text;
alter table public.profiles add column if not exists onboarding_completed_at timestamptz;
alter table public.profiles add column if not exists paddle text;
alter table public.profiles add column if not exists preferred_side text;
alter table public.profiles add column if not exists height_inches numeric;
alter table public.profiles add column if not exists weight_pounds numeric;
alter table public.profiles add column if not exists shoe_size numeric;
create unique index if not exists profiles_username_lower_idx on public.profiles (lower(username));
create index if not exists profiles_onboarding_idx on public.profiles (onboarding_completed_at);

-- A session is the loggable + postable unit. It shows in the feed when posted = true.
-- A session is also a container of activities (practice/match) written on-device.
create table if not exists public.sessions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles(id) on delete cascade,
  title            text,
  location         text,
  duration_minutes int  not null default 0,
  focus            text,
  takeaway         text,
  posted           boolean not null default true,
  started_at       timestamptz,
  ended_at         timestamptz,
  reposted_from    uuid references public.sessions(id) on delete set null,
  created_at       timestamptz not null default now()
);
-- Keep existing projects in sync when this schema is re-run.
alter table public.sessions add column if not exists started_at timestamptz;
alter table public.sessions add column if not exists ended_at   timestamptz;
alter table public.sessions add column if not exists reposted_from uuid references public.sessions(id) on delete set null;
create index if not exists sessions_user_created_idx on public.sessions (user_id, created_at desc);
create unique index if not exists sessions_repost_target_idx
  on public.sessions (user_id, reposted_from)
  where reposted_from is not null;

create table if not exists public.likes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, session_id)
);

create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now()
);

-- Your gear locker: paddles, shoes, bag, apparel, etc. Persistent per user.
create table if not exists public.gear (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  category   text not null,
  name       text not null,
  brand      text,
  created_at timestamptz not null default now()
);
create index if not exists gear_user_idx on public.gear (user_id, created_at desc);

-- Directional follow graph (the app's social model). One row per directed
-- edge (follower_id -> followee_id). status is the single source of truth:
--   pending  = requested, awaiting the followee's decision
--   accepted = followee approved; follower now follows followee
--   rejected = optional terminal state to suppress re-requests (default flow deletes)
-- Following is directional: B accepting A does NOT make B follow A back.
create table if not exists public.follows (
  follower_id  uuid not null references public.profiles(id) on delete cascade,
  followee_id  uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  created_at   timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
-- Follower lists + pending-request inboxes ("edges into B, by status").
-- Follower-side lists (edges out of A) are served by the primary key.
create index if not exists follows_followee_status_idx on public.follows (followee_id, status);

create table if not exists public.friend_requests (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null references public.profiles(id) on delete cascade,
  addressee_id  uuid not null references public.profiles(id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (requester_id <> addressee_id)
);
create unique index if not exists friend_requests_pair_unique_idx
  on public.friend_requests (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index if not exists friend_requests_requester_idx on public.friend_requests (requester_id, status);
create index if not exists friend_requests_addressee_idx on public.friend_requests (addressee_id, status);

create table if not exists private.phone_lookup (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  phone_e164 text unique not null,
  updated_at timestamptz not null default now()
);
alter table private.phone_lookup enable row level security;
revoke all on table private.phone_lookup from anon, authenticated;

-- A session is a container of activities (practice or match). Match activities
-- tag the people you played with/against — either app members (profile_id) or
-- free-text guests (guest_name).
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
  created_at     timestamptz not null default now(),
  constraint session_activities_id_session_id_key unique (id, session_id)
);
create index if not exists session_activities_session_idx
  on public.session_activities (session_id, position);
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.session_activities'::regclass
      and conname = 'session_activities_id_session_id_key'
  ) then
    alter table public.session_activities
      add constraint session_activities_id_session_id_key unique (id, session_id);
  end if;
end $$;

create table if not exists public.activity_participants (
  id          uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.session_activities(id) on delete cascade,
  session_id  uuid not null references public.sessions(id) on delete cascade,
  profile_id  uuid references public.profiles(id) on delete set null,
  guest_name  text,
  role        text not null check (role in ('partner', 'opponent')),
  created_at  timestamptz not null default now(),
  check (profile_id is not null or guest_name is not null),
  constraint activity_participants_activity_session_fkey
    foreign key (activity_id, session_id)
    references public.session_activities(id, session_id)
    on delete cascade
);
create index if not exists activity_participants_activity_idx
  on public.activity_participants (activity_id);
create index if not exists activity_participants_profile_idx
  on public.activity_participants (profile_id);
create index if not exists activity_participants_session_idx
  on public.activity_participants (session_id);
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.activity_participants'::regclass
      and conname = 'activity_participants_activity_session_fkey'
  ) then
    alter table public.activity_participants
      add constraint activity_participants_activity_session_fkey
      foreign key (activity_id, session_id)
      references public.session_activities(id, session_id)
      on delete cascade;
  end if;
end $$;

-- Permission-gated reposts: a player tagged in a session can request to repost
-- it; the original author approves, which copies the session into the
-- requester's log (a new session pointing back via sessions.reposted_from).
create table if not exists public.repost_requests (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.sessions(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (session_id, requester_id)
);
create index if not exists repost_requests_requester_idx on public.repost_requests (requester_id, status);
create index if not exists repost_requests_session_idx on public.repost_requests (session_id, status);

-- =========================================================
-- Auto-create a profile row when a user signs up.
-- Phone users arrive before profile onboarding, so they get safe placeholders.
-- =========================================================

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  fallback_username text := 'player_' || substr(replace(new.id::text, '-', ''), 1, 8);
  fallback_name text := coalesce(
    nullif(new.raw_user_meta_data->>'display_name', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Pickleball Player'
  );
begin
  insert into public.profiles (id, username, display_name, avatar_initials)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'username', ''), fallback_username),
    fallback_name,
    coalesce(
      nullif(new.raw_user_meta_data->>'avatar_initials', ''),
      case when fallback_name = 'Pickleball Player' then 'PB' else upper(left(fallback_name, 2)) end
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

drop function if exists public.handle_new_user();

-- =========================================================
-- Row Level Security
-- =========================================================

alter table public.profiles        enable row level security;
alter table public.sessions        enable row level security;
alter table public.likes           enable row level security;
alter table public.comments        enable row level security;
alter table public.gear            enable row level security;
alter table public.follows         enable row level security;
alter table public.friend_requests enable row level security;
alter table public.session_activities   enable row level security;
alter table public.activity_participants enable row level security;
alter table public.repost_requests       enable row level security;

-- profiles: signed-in users can discover completed profiles; you manage your own row.
drop policy if exists "profiles_read"   on public.profiles;
drop policy if exists "profiles_insert" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_read" on public.profiles
  for select to authenticated
  using (onboarding_completed_at is not null or id = auth.uid());
create policy "profiles_insert" on public.profiles
  for insert to authenticated
  with check (id = auth.uid());
create policy "profiles_update" on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- sessions: you can read your own sessions; you can read posted sessions of
-- people you follow (accepted). Directional — matches the follow graph.
drop policy if exists "sessions_read"   on public.sessions;
drop policy if exists "sessions_insert" on public.sessions;
drop policy if exists "sessions_update" on public.sessions;
drop policy if exists "sessions_delete" on public.sessions;
create policy "sessions_read" on public.sessions
  for select to authenticated
  using (
    user_id = auth.uid()
    or (
      posted = true
      and exists (
        select 1 from public.follows f
        where f.status = 'accepted'
          and f.follower_id = auth.uid()
          and f.followee_id = sessions.user_id
      )
    )
  );
create policy "sessions_insert" on public.sessions
  for insert to authenticated
  with check (user_id = auth.uid());
create policy "sessions_update" on public.sessions
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy "sessions_delete" on public.sessions
  for delete to authenticated
  using (user_id = auth.uid());

-- likes: visible when the related session is visible; you like/unlike as yourself.
drop policy if exists "likes_read"   on public.likes;
drop policy if exists "likes_insert" on public.likes;
drop policy if exists "likes_delete" on public.likes;
create policy "likes_read" on public.likes
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = likes.session_id));
create policy "likes_insert" on public.likes
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.sessions s where s.id = likes.session_id)
  );
create policy "likes_delete" on public.likes
  for delete to authenticated
  using (user_id = auth.uid());

-- comments: visible when the related session is visible; you write/delete your own.
drop policy if exists "comments_read"   on public.comments;
drop policy if exists "comments_insert" on public.comments;
drop policy if exists "comments_delete" on public.comments;
create policy "comments_read" on public.comments
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = comments.session_id));
create policy "comments_insert" on public.comments
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.sessions s where s.id = comments.session_id)
  );
create policy "comments_delete" on public.comments
  for delete to authenticated
  using (user_id = auth.uid());

-- gear: readable by all signed-in users; you manage your own.
drop policy if exists "gear_read"   on public.gear;
drop policy if exists "gear_insert" on public.gear;
drop policy if exists "gear_update" on public.gear;
drop policy if exists "gear_delete" on public.gear;
create policy "gear_read" on public.gear
  for select to authenticated
  using (true);
create policy "gear_insert" on public.gear
  for insert to authenticated
  with check (user_id = auth.uid());
create policy "gear_update" on public.gear
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy "gear_delete" on public.gear
  for delete to authenticated
  using (user_id = auth.uid());

-- follows: readable by any signed-in user. The requester controls the request
-- (create pending / cancel); the recipient controls acceptance (accept/reject).
drop policy if exists "follows_read"   on public.follows;
drop policy if exists "follows_insert" on public.follows;
drop policy if exists "follows_update" on public.follows;
drop policy if exists "follows_delete" on public.follows;
create policy "follows_read"   on public.follows for select to authenticated using (true);
-- You may only create your own request, and it must start as pending.
create policy "follows_insert" on public.follows for insert to authenticated
  with check (follower_id = auth.uid() and status = 'pending');
-- Only the recipient can act on a request, and only to accept or reject it.
create policy "follows_update" on public.follows for update to authenticated
  using (followee_id = auth.uid())
  with check (followee_id = auth.uid() and status in ('accepted', 'rejected'));
-- The requester can cancel/unfollow; the recipient can reject/remove.
create policy "follows_delete" on public.follows for delete to authenticated
  using (follower_id = auth.uid() or followee_id = auth.uid());

-- friend_requests: mutual friend graph with participant-only visibility.
drop policy if exists "friend_requests_read"   on public.friend_requests;
drop policy if exists "friend_requests_insert" on public.friend_requests;
drop policy if exists "friend_requests_update" on public.friend_requests;
drop policy if exists "friend_requests_delete" on public.friend_requests;
create policy "friend_requests_read" on public.friend_requests
  for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy "friend_requests_insert" on public.friend_requests
  for insert to authenticated
  with check (requester_id = auth.uid() and requester_id <> addressee_id and status = 'pending');
create policy "friend_requests_update" on public.friend_requests
  for update to authenticated
  using (addressee_id = auth.uid() and status = 'pending')
  with check (addressee_id = auth.uid() and status in ('accepted', 'declined'));
create policy "friend_requests_delete" on public.friend_requests
  for delete to authenticated
  using (requester_id = auth.uid() and status = 'pending');

-- session_activities / activity_participants: children are readable like
-- sessions; only the session owner writes them.
drop policy if exists "session_activities_read"   on public.session_activities;
drop policy if exists "session_activities_write"  on public.session_activities;
create policy "session_activities_read" on public.session_activities
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = session_activities.session_id));
create policy "session_activities_write" on public.session_activities
  for all to authenticated
  using (exists (
    select 1 from public.sessions s
    where s.id = session_activities.session_id and s.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.sessions s
    where s.id = session_activities.session_id and s.user_id = auth.uid()
  ));

drop policy if exists "activity_participants_read"  on public.activity_participants;
drop policy if exists "activity_participants_write" on public.activity_participants;
create policy "activity_participants_read" on public.activity_participants
  for select to authenticated
  using (exists (select 1 from public.sessions s where s.id = activity_participants.session_id));
create policy "activity_participants_write" on public.activity_participants
  for all to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id and s.user_id = auth.uid()
    )
    and exists (
      select 1 from public.session_activities a
      where a.id = activity_participants.activity_id
        and a.session_id = activity_participants.session_id
    )
  )
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id and s.user_id = auth.uid()
    )
    and exists (
      select 1 from public.session_activities a
      where a.id = activity_participants.activity_id
        and a.session_id = activity_participants.session_id
    )
  );

-- repost_requests: visible to the requester and to the session's author.
drop policy if exists "repost_requests_read"   on public.repost_requests;
drop policy if exists "repost_requests_insert" on public.repost_requests;
drop policy if exists "repost_requests_update" on public.repost_requests;
create policy "repost_requests_read" on public.repost_requests
  for select to authenticated using (
    requester_id = auth.uid()
    or exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid())
  );
-- Only a tagged participant may request to repost, and only as themselves.
create policy "repost_requests_insert" on public.repost_requests
  for insert to authenticated with check (
    requester_id = auth.uid()
    and status = 'pending'
    and exists (
      select 1 from public.activity_participants ap
      where ap.session_id = repost_requests.session_id and ap.profile_id = auth.uid()
    )
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id <> auth.uid()
    )
  );
-- The session's author may decline directly. Approval must go through
-- approve_repost so the copied session is created atomically.
create policy "repost_requests_update" on public.repost_requests
  for update to authenticated
  using (
    status = 'pending'
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id = auth.uid()
    )
  )
  with check (
    status = 'declined'
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id = auth.uid()
    )
  );

-- Approve + copy the session into the requester's log. SECURITY DEFINER so the
-- copy can be written as the requester; the caller must be the original author.
create or replace function public.approve_repost(request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  req  public.repost_requests;
  orig public.sessions;
  new_session_id uuid := gen_random_uuid();
  act  public.session_activities;
  new_act_id uuid;
begin
  select * into req from public.repost_requests where id = request_id for update;
  if req.id is null then raise exception 'Repost request not found'; end if;
  if req.status <> 'pending' then raise exception 'Repost request is not pending'; end if;

  select * into orig from public.sessions where id = req.session_id;
  if orig.user_id <> auth.uid() then raise exception 'Only the author can approve'; end if;
  if orig.user_id = req.requester_id then raise exception 'You cannot repost your own session'; end if;
  if not exists (
    select 1 from public.activity_participants ap
    where ap.session_id = req.session_id and ap.profile_id = req.requester_id
  ) then
    raise exception 'Requester is not tagged in this session';
  end if;

  update public.repost_requests set status = 'approved', updated_at = now() where id = request_id;

  insert into public.sessions
    (id, user_id, title, location, duration_minutes, focus, takeaway, posted,
     started_at, ended_at, reposted_from, created_at)
  values
    (new_session_id, req.requester_id, orig.title, orig.location, orig.duration_minutes,
     orig.focus, orig.takeaway, true, orig.started_at, orig.ended_at, orig.id, now());

  for act in
    select * from public.session_activities where session_id = orig.id order by position
  loop
    new_act_id := gen_random_uuid();
    insert into public.session_activities
      (id, session_id, kind, position, focus, reps, notes, team_score, opponent_score, won)
    values
      (new_act_id, new_session_id, act.kind, act.position, act.focus, act.reps, act.notes,
       act.team_score, act.opponent_score, act.won);
    insert into public.activity_participants (activity_id, session_id, profile_id, guest_name, role)
      select new_act_id, new_session_id, profile_id, guest_name, role
      from public.activity_participants where activity_id = act.id;
  end loop;

  return new_session_id;
end;
$$;

revoke all on function public.approve_repost(uuid) from public, anon;
grant execute on function public.approve_repost(uuid) to authenticated;

-- =========================================================
-- Realtime
-- =========================================================

-- Enable Supabase Realtime on the sessions table so new posts surface live in
-- the feed (Home + Profile) without a manual refresh. Idempotent.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'sessions'
  ) then
    alter publication supabase_realtime add table public.sessions;
  end if;
end $$;

-- =========================================================
-- Storage
-- =========================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars_read" on storage.objects;
create policy "avatars_read"
  on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- =========================================================
-- Data API grants
-- =========================================================

grant select, insert, update, delete on public.profiles to authenticated;
grant select, delete on public.sessions to authenticated;
revoke insert, update on public.sessions from authenticated;
revoke insert (reposted_from), update (reposted_from) on public.sessions from authenticated;
grant insert (
  id, user_id, title, location, duration_minutes, focus, takeaway, posted,
  started_at, ended_at, created_at
) on public.sessions to authenticated;
grant update (
  title, location, duration_minutes, focus, takeaway, posted, started_at, ended_at
) on public.sessions to authenticated;
grant select, insert, delete on public.likes to authenticated;
grant select, insert, delete on public.comments to authenticated;
grant select, insert, update, delete on public.gear to authenticated;
grant select, insert, update, delete on public.follows to authenticated;
grant select, insert, delete on public.friend_requests to authenticated;
revoke update on public.friend_requests from authenticated;
grant update (status) on public.friend_requests to authenticated;
grant select, insert, update, delete on public.session_activities to authenticated;
grant select, insert, update, delete on public.activity_participants to authenticated;
grant select, insert on public.repost_requests to authenticated;
revoke update, delete on public.repost_requests from authenticated;
grant update (status) on public.repost_requests to authenticated;
grant usage on schema public to authenticated;
