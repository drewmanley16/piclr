-- Make the crew leaderboard agree with the profile stats.
--
-- Being tagged in a mutual friend's match creates a credit wrapper session
-- (reposted_from set, no activity rows of its own). The client counts those by
-- projecting the source's activities into the tagged player's perspective —
-- flipping the score when they were the opponent — so profile stats, rivalries
-- and milestones all include them. crew_leaderboard joined sessions straight to
-- session_activities, which finds nothing on a wrapper, so the same player had
-- one record on their profile and a smaller one on the leaderboard.
--
-- private.player_match_results is now the single definition of "matches that
-- count for this player", and mirrors SessionActivity.projected(for:) on device.

create or replace function private.player_match_results(p_user uuid)
returns table (won boolean, played_at timestamptz, visible boolean)
language sql
stable
security definer
set search_path = ''
as $$
  -- Matches the player logged themselves.
  select
    sa.won,
    coalesce(s.started_at, s.created_at),
    s.posted
  from public.sessions s
  join public.session_activities sa
    on sa.session_id = s.id and sa.kind = 'match'
  where s.user_id = p_user
    and s.reposted_from is null
    and sa.won is not null

  union all

  -- Matches credited to the player by being tagged in someone else's session.
  -- `visible` follows the source, not the wrapper: a private credit is only
  -- private as a *post*, the match itself is already public on the author's
  -- feed, so it belongs in a record other people can see.
  select
    case when tag.role = 'opponent' then not sa.won else sa.won end,
    coalesce(source.started_at, source.created_at),
    source.posted
  from public.sessions wrapper
  join public.sessions source
    on source.id = wrapper.reposted_from
  join public.session_activities sa
    on sa.session_id = source.id and sa.kind = 'match'
  -- Exactly one tag, mirroring the client's `guard tags.count == 1`: a player
  -- somehow tagged on both sides of one match has no defined perspective.
  join lateral (
    select max(ap.role) as role, count(*) as tags
    from public.activity_participants ap
    where ap.activity_id = sa.id and ap.profile_id = p_user
  ) tag on tag.tags = 1
  where wrapper.user_id = p_user
    and wrapper.reposted_from is not null
    and sa.won is not null;
$$;

revoke all on function private.player_match_results(uuid)
  from public, anon, authenticated;

-- Same signature and period semantics as before; only the row source and the
-- visibility filter change.
create or replace function public.crew_leaderboard(p_period text default 'all')
returns table (
  user_id         uuid,
  username        text,
  display_name    text,
  avatar_url      text,
  avatar_initials text,
  wins            int,
  losses          int,
  matches         int
)
language sql stable security definer set search_path = public as $$
  with crew as (
    select auth.uid() as id
    union
    select f.followee_id from public.follows f
    where f.follower_id = auth.uid() and f.status = 'accepted'
  ),
  window_start as (
    select case p_period
      when 'month'  then date_trunc('month', now())
      when 'season' then date_trunc('month', now()) - interval '2 months'
      else timestamptz '-infinity'
    end as start
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    coalesce(count(*) filter (where r.won is true), 0)::int  as wins,
    coalesce(count(*) filter (where r.won is false), 0)::int as losses,
    coalesce(count(*) filter (where r.won is not null), 0)::int as matches
  from crew c
  join public.profiles p on p.id = c.id
  -- Lateral so the filters live in the join: a crew member with no qualifying
  -- matches still appears, at 0-0, rather than dropping off the board.
  left join lateral (
    select m.won
    from private.player_match_results(p.id) m
    where m.played_at >= (select start from window_start)
      -- You see your own full record; everyone else's is what they published.
      and (m.visible or p.id = auth.uid())
  ) r on true
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials;
$$;

revoke all on function public.crew_leaderboard(text) from public;
grant execute on function public.crew_leaderboard(text) to authenticated;

-- A credit wrapper must not claim the post-level weekly-streak badge. It is
-- inserted with the source's created_at, so it could land as the "first session
-- of the week" and both badge a repost and starve the player's own session of
-- the badge when they logged one later that week.
create or replace function public.stamp_session_streak()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wk date := date_trunc('week', coalesce(new.started_at, new.created_at))::date;
  streak int;
begin
  if new.reposted_from is not null then
    return null;
  end if;

  -- Only the first session of its week earns the badge.
  if exists (
    select 1 from public.sessions s
    where s.user_id = new.user_id
      and s.id <> new.id
      and s.reposted_from is null
      and date_trunc('week', coalesce(s.started_at, s.created_at))::date = wk
  ) then
    return null;
  end if;

  select public.user_weekly_streak(new.user_id) into streak;
  if streak >= 2 then
    update public.sessions set streak_week = streak where id = new.id;
  end if;
  return null;
end;
$$;
