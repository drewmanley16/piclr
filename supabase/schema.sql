-- pickleball.ai schema
-- Run this in the Supabase SQL editor (Dashboard -> SQL -> New query).
-- Safe to re-run: uses "if not exists" / "drop policy if exists".

-- =========================================================
-- Tables
-- =========================================================

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  username       text unique not null,
  display_name   text not null,
  avatar_initials text,
  avatar_url     text,
  home_court     text,
  rating         numeric,
  preferred_side text,
  height_inches  numeric,
  weight_pounds  numeric,
  shoe_size      numeric,
  created_at     timestamptz not null default now()
);

-- Keep existing projects in sync when this schema is re-run.
alter table public.profiles add column if not exists height_inches numeric;
alter table public.profiles add column if not exists weight_pounds numeric;
alter table public.profiles add column if not exists shoe_size numeric;
alter table public.profiles add column if not exists avatar_url text;

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

create table if not exists public.follows (
  follower_id  uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

-- =========================================================
-- Auto-create a profile row when a user signs up.
-- Reads username / display_name / avatar_initials from signup metadata.
-- SECURITY DEFINER so it runs regardless of the client session (works even
-- when email confirmation is enabled).
-- =========================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username, display_name, avatar_initials)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'username', ''),
             'player_' || substr(replace(new.id::text, '-', ''), 1, 8)),
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''),
             split_part(new.email, '@', 1)),
    coalesce(nullif(new.raw_user_meta_data->>'avatar_initials', ''),
             upper(left(new.email, 2)))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- Row Level Security
-- =========================================================

alter table public.profiles enable row level security;
alter table public.sessions enable row level security;
alter table public.likes    enable row level security;
alter table public.comments enable row level security;
alter table public.gear     enable row level security;
alter table public.follows  enable row level security;

-- profiles: everyone signed-in can read; you manage your own row.
drop policy if exists "profiles_read"   on public.profiles;
drop policy if exists "profiles_insert" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_read"   on public.profiles for select to authenticated using (true);
create policy "profiles_insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles_update" on public.profiles for update to authenticated using (id = auth.uid());

-- sessions: readable by all signed-in users; you write your own.
drop policy if exists "sessions_read"   on public.sessions;
drop policy if exists "sessions_insert" on public.sessions;
drop policy if exists "sessions_update" on public.sessions;
drop policy if exists "sessions_delete" on public.sessions;
create policy "sessions_read"   on public.sessions for select to authenticated using (true);
create policy "sessions_insert" on public.sessions for insert to authenticated with check (user_id = auth.uid());
create policy "sessions_update" on public.sessions for update to authenticated using (user_id = auth.uid());
create policy "sessions_delete" on public.sessions for delete to authenticated using (user_id = auth.uid());

-- likes: readable by all; you like/unlike as yourself.
drop policy if exists "likes_read"   on public.likes;
drop policy if exists "likes_insert" on public.likes;
drop policy if exists "likes_delete" on public.likes;
create policy "likes_read"   on public.likes for select to authenticated using (true);
create policy "likes_insert" on public.likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes_delete" on public.likes for delete to authenticated using (user_id = auth.uid());

-- comments: readable by all; you write/delete your own.
drop policy if exists "comments_read"   on public.comments;
drop policy if exists "comments_insert" on public.comments;
drop policy if exists "comments_delete" on public.comments;
create policy "comments_read"   on public.comments for select to authenticated using (true);
create policy "comments_insert" on public.comments for insert to authenticated with check (user_id = auth.uid());
create policy "comments_delete" on public.comments for delete to authenticated using (user_id = auth.uid());

-- gear: readable by all signed-in users; you manage your own.
drop policy if exists "gear_read"   on public.gear;
drop policy if exists "gear_insert" on public.gear;
drop policy if exists "gear_update" on public.gear;
drop policy if exists "gear_delete" on public.gear;
create policy "gear_read"   on public.gear for select to authenticated using (true);
create policy "gear_insert" on public.gear for insert to authenticated with check (user_id = auth.uid());
create policy "gear_update" on public.gear for update to authenticated using (user_id = auth.uid());
create policy "gear_delete" on public.gear for delete to authenticated using (user_id = auth.uid());

-- follows: readable by all; you follow/unfollow as yourself.
drop policy if exists "follows_read"   on public.follows;
drop policy if exists "follows_insert" on public.follows;
drop policy if exists "follows_delete" on public.follows;
create policy "follows_read"   on public.follows for select to authenticated using (true);
create policy "follows_insert" on public.follows for insert to authenticated with check (follower_id = auth.uid());
create policy "follows_delete" on public.follows for delete to authenticated using (follower_id = auth.uid());
