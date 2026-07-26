-- Public "is Pro" flag on profiles so the app can render a Pro badge on ANY
-- user (feed, other profiles, people lists, comments), not just the signed-in
-- one. The `entitlements` table stays private (own-row RLS only); this column
-- mirrors just the single boolean everyone is allowed to see.
--
-- Kept in sync by a trigger on `entitlements`: whenever the revenuecat-webhook
-- upserts an entitlement row, we recompute is_pro = (expires_at > now()). This
-- matches the authoritative rule used elsewhere (Pro == expires_at > now()) and
-- stays correct for CANCELLATION (paid up, auto-renew off). Caveat: the flag can
-- lag a silently-missed EXPIRATION until the next webhook touches the row — the
-- same staleness the entitlements table itself carries; the badge is cosmetic,
-- server-side Pro checks still read expires_at directly.

alter table public.profiles
  add column if not exists is_pro boolean not null default false;

-- Recompute one profile's flag from its entitlement row (or false if none).
create or replace function public.sync_profile_is_pro(p_user_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles p
  set is_pro = coalesce(
    (select e.expires_at > now() from public.entitlements e where e.user_id = p_user_id),
    false
  )
  where p.id = p_user_id;
$$;

revoke execute on function public.sync_profile_is_pro(uuid) from public, anon, authenticated;

create or replace function public.entitlements_sync_profile_is_pro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.sync_profile_is_pro(coalesce(new.user_id, old.user_id));
  return null;
end;
$$;

drop trigger if exists entitlements_sync_profile_is_pro on public.entitlements;
create trigger entitlements_sync_profile_is_pro
  after insert or update or delete on public.entitlements
  for each row execute function public.entitlements_sync_profile_is_pro();

-- Backfill existing subscribers.
update public.profiles p
set is_pro = coalesce(
  (select e.expires_at > now() from public.entitlements e where e.user_id = p.id),
  false
);

-- crew_leaderboard() feeds the People-list badge too, so thread is_pro through
-- it. Return-type change requires a drop + recreate (create-or-replace can't
-- alter OUT columns). Bodies are unchanged except the added column.
drop function if exists public.crew_leaderboard();
drop function if exists repost_internal.crew_leaderboard_for(uuid);

create function repost_internal.crew_leaderboard_for(viewer_id uuid)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  avatar_initials text,
  is_pro boolean,
  wins int,
  losses int,
  matches int
)
language sql
stable
security definer
set search_path = ''
as $$
  with crew as (
    select viewer_id as id
    where viewer_id = auth.uid()
    union
    select f.followee_id
    from public.follows f
    where viewer_id = auth.uid()
      and f.follower_id = viewer_id
      and f.status = 'accepted'
  ), projected_matches as (
    select
      s.user_id as player_id,
      case
        when sa.team_score is null or sa.opponent_score is null
          or sa.team_score = sa.opponent_score then null
        else sa.team_score > sa.opponent_score
      end as won
    from public.sessions s
    join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match'
    join crew c on c.id = s.user_id
    where s.reposted_from is null

    union all

    select
      wrapper.user_id as player_id,
      case
        when sa.team_score is null or sa.opponent_score is null
          or sa.team_score = sa.opponent_score then null
        when tag.role = 'opponent' then sa.opponent_score > sa.team_score
        else sa.team_score > sa.opponent_score
      end as won
    from public.sessions wrapper
    join crew c on c.id = wrapper.user_id
    join public.sessions source on source.id = wrapper.reposted_from
    join public.session_activities sa on sa.session_id = source.id and sa.kind = 'match'
    join lateral (
      select min(ap.role) as role
      from public.activity_participants ap
      where ap.activity_id = sa.id
        and ap.profile_id = wrapper.user_id
      having count(*) = 1
    ) tag on true
    where wrapper.reposted_from is not null
      and source.reposted_from is null
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    p.is_pro,
    coalesce(count(*) filter (where pm.won is true), 0)::int,
    coalesce(count(*) filter (where pm.won is false), 0)::int,
    coalesce(count(*) filter (where pm.won is not null), 0)::int
  from crew c
  join public.profiles p on p.id = c.id
  left join projected_matches pm on pm.player_id = p.id
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials, p.is_pro;
$$;
revoke all on function repost_internal.crew_leaderboard_for(uuid) from public, anon;
grant execute on function repost_internal.crew_leaderboard_for(uuid) to authenticated;

create function public.crew_leaderboard()
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  avatar_initials text,
  is_pro boolean,
  wins int,
  losses int,
  matches int
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from repost_internal.crew_leaderboard_for(auth.uid());
$$;
revoke all on function public.crew_leaderboard() from public, anon;
grant execute on function public.crew_leaderboard() to authenticated;
