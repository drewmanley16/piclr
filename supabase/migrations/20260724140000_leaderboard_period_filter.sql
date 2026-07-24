-- Crew leaderboard, Pro timeframe filter. The free all-time view
-- (`crew_leaderboard('all')`) is unchanged output-for-output from the original
-- zero-arg function; 'month'/'season' narrow the match window and are gated
-- client-side to Pro (see LeaderboardSheet's period chips).

drop function if exists public.crew_leaderboard();

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
    coalesce(count(*) filter (where sa.won is true), 0)::int  as wins,
    coalesce(count(*) filter (where sa.won is false), 0)::int as losses,
    coalesce(count(*) filter (where sa.won is not null), 0)::int as matches
  from crew c
  join public.profiles p on p.id = c.id
  left join public.sessions s
    on s.user_id = p.id
    and coalesce(s.started_at, s.created_at) >= (select start from window_start)
  left join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match'
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials;
$$;

revoke all on function public.crew_leaderboard(text) from public;
grant execute on function public.crew_leaderboard(text) to authenticated;
