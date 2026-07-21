-- Suggested Athletes: dismissible follow suggestions ranked by mutual
-- follow-graph overlap, falling back to recently active profiles.

create table if not exists public.dismissed_suggestions (
  user_id            uuid not null references public.profiles(id) on delete cascade,
  dismissed_user_id  uuid not null references public.profiles(id) on delete cascade,
  created_at         timestamptz not null default now(),
  primary key (user_id, dismissed_user_id),
  check (user_id <> dismissed_user_id)
);

alter table public.dismissed_suggestions enable row level security;

drop policy if exists "dismissed_suggestions_select_own"
  on public.dismissed_suggestions;
create policy "dismissed_suggestions_select_own"
  on public.dismissed_suggestions for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "dismissed_suggestions_insert_own"
  on public.dismissed_suggestions;
create policy "dismissed_suggestions_insert_own"
  on public.dismissed_suggestions for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "dismissed_suggestions_delete_own"
  on public.dismissed_suggestions;
create policy "dismissed_suggestions_delete_own"
  on public.dismissed_suggestions for delete
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.dismissed_suggestions from anon, authenticated;
grant select, insert, delete on table public.dismissed_suggestions to authenticated;

-- Keep the privileged graph query outside the Data API's exposed schema.
create schema if not exists suggested_internal;
revoke all on schema suggested_internal from public, anon;
grant usage on schema suggested_internal to authenticated;

-- Ranks candidate profiles for the authenticated caller by second-degree
-- follow-graph overlap, falling back to recently active profiles
-- to top up the result set. Excludes self, already-followed/requested,
-- blocked, and previously dismissed profiles.
create or replace function suggested_internal.suggested_athletes_for(p_limit int default 15)
returns table (user_id uuid, mutual_count int)
language sql
stable
security definer
set search_path = ''
as $$
  with viewer as (
    select
      (select auth.uid()) as id,
      greatest(1, least(coalesce(p_limit, 15), 50))::int as result_limit
    where private.is_active_user((select auth.uid()))
  ),
  excluded as (
    select f.followee_id as id
    from public.follows f
    join viewer v on f.follower_id = v.id
    union
    select id from viewer
    union
    select b.blocked_id
    from public.blocks b
    join viewer v on b.blocker_id = v.id
    union
    select b.blocker_id
    from public.blocks b
    join viewer v on b.blocked_id = v.id
    union
    select d.dismissed_user_id
    from public.dismissed_suggestions d
    join viewer v on d.user_id = v.id
  ),
  candidates as (
    -- People followed by accounts the caller follows.
    select f2.followee_id as id
    from viewer v
    join public.follows f1 on f1.follower_id = v.id
    join public.follows f2 on f2.follower_id = f1.followee_id
    where f1.status = 'accepted' and f2.status = 'accepted'
    union all
    -- People who follow the caller's followers.
    select f2.follower_id as id
    from viewer v
    join public.follows f1 on f1.followee_id = v.id
    join public.follows f2 on f2.followee_id = f1.follower_id
    where f1.status = 'accepted' and f2.status = 'accepted'
  ),
  ranked as (
    select id, count(*)::int as mutual_count
    from candidates
    where id not in (select id from excluded)
    group by id
  ),
  fallback as (
    select p.id, p.created_at
    from public.profiles p
    cross join viewer
    where p.onboarding_completed_at is not null
      and p.id not in (select id from excluded)
      and p.id not in (select id from ranked)
  ),
  combined as (
    select
      r.id,
      r.mutual_count,
      0 as source_rank,
      null::timestamptz as fallback_created_at
    from ranked r
    union all
    select
      f.id,
      0 as mutual_count,
      1 as source_rank,
      f.created_at as fallback_created_at
    from fallback f
  )
  select id as user_id, mutual_count
  from combined
  order by source_rank, mutual_count desc, fallback_created_at desc nulls last, id
  limit (select result_limit from viewer);
$$;

revoke all on function suggested_internal.suggested_athletes_for(int)
  from public, anon;
grant execute on function suggested_internal.suggested_athletes_for(int)
  to authenticated;

-- Public RPC wrapper: the caller cannot choose whose graph is queried.
drop function if exists public.suggested_athletes(uuid, int);
create or replace function public.suggested_athletes(p_limit int default 15)
returns table (user_id uuid, mutual_count int)
language sql
stable
security invoker
set search_path = ''
as $$
  select *
  from suggested_internal.suggested_athletes_for(p_limit);
$$;

revoke all on function public.suggested_athletes(int) from public, anon;
grant execute on function public.suggested_athletes(int) to authenticated;
