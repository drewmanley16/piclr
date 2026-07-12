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
  home_court               text,
  rating                   numeric,
  skill_level              text,
  onboarding_completed_at  timestamptz,
  paddle                   text,
  preferred_side           text,
  created_at               timestamptz not null default now()
);

alter table public.profiles add column if not exists skill_level text;
alter table public.profiles add column if not exists onboarding_completed_at timestamptz;
create unique index if not exists profiles_username_lower_idx on public.profiles (lower(username));
create index if not exists profiles_onboarding_idx on public.profiles (onboarding_completed_at);

-- A session is the loggable + postable unit. It shows in the feed when posted = true.
create table if not exists public.sessions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles(id) on delete cascade,
  title            text,
  location         text,
  duration_minutes int  not null default 0,
  focus            text,
  takeaway         text,
  posted           boolean not null default true,
  created_at       timestamptz not null default now()
);
create index if not exists sessions_user_created_idx on public.sessions (user_id, created_at desc);

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

-- Kept for compatibility with older builds. New app code uses friend_requests.
create table if not exists public.follows (
  follower_id  uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

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

-- sessions: you can read your own sessions; accepted friends can read posted sessions.
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
        select 1 from public.friend_requests fr
        where fr.status = 'accepted'
          and (
            (fr.requester_id = auth.uid() and fr.addressee_id = sessions.user_id)
            or (fr.addressee_id = auth.uid() and fr.requester_id = sessions.user_id)
          )
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

-- follows: compatibility policies for older builds. Some databases used
-- followee_id before origin/main used following_id, so inspect before creating.
drop policy if exists "follows_read"   on public.follows;
drop policy if exists "follows_insert" on public.follows;
drop policy if exists "follows_delete" on public.follows;
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'follows'
      and column_name = 'following_id'
  ) then
    execute $policy$
      create policy "follows_read" on public.follows
        for select to authenticated
        using (follower_id = auth.uid() or following_id = auth.uid())
    $policy$;
    execute $policy$
      create policy "follows_insert" on public.follows
        for insert to authenticated
        with check (follower_id = auth.uid())
    $policy$;
    execute $policy$
      create policy "follows_delete" on public.follows
        for delete to authenticated
        using (follower_id = auth.uid())
    $policy$;
  elsif exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'follows'
      and column_name = 'followee_id'
  ) then
    execute $policy$
      create policy "follows_read" on public.follows
        for select to authenticated
        using (follower_id = auth.uid() or followee_id = auth.uid())
    $policy$;
    execute $policy$
      create policy "follows_insert" on public.follows
        for insert to authenticated
        with check (follower_id = auth.uid())
    $policy$;
    execute $policy$
      create policy "follows_delete" on public.follows
        for delete to authenticated
        using (follower_id = auth.uid())
    $policy$;
  end if;
end $$;

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

-- =========================================================
-- Data API grants
-- =========================================================

grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.sessions to authenticated;
grant select, insert, delete on public.likes to authenticated;
grant select, insert, delete on public.comments to authenticated;
grant select, insert, update, delete on public.gear to authenticated;
grant select, insert, delete on public.follows to authenticated;
grant select, insert, delete on public.friend_requests to authenticated;
revoke update on public.friend_requests from authenticated;
grant update (status) on public.friend_requests to authenticated;
grant usage on schema public to authenticated;
