-- Fix: compute_season_awards() failed every call with "column reference
-- season_key is ambiguous" — the local PL/pgSQL variable `season_key` collided
-- with the season_awards.season_key column inside INSERT ... SELECT (the
-- `ranked` CTE has no season_key column, so Postgres couldn't tell whether the
-- bare identifier meant the variable or the target column). Renaming the
-- local variables with a v_ prefix removes all ambiguity.

create or replace function public.compute_season_awards()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_season_start timestamptz := date_trunc('month', now()) - interval '1 month';
  v_season_end   timestamptz := date_trunc('month', now());
  v_season_key   text := to_char(v_season_start, 'YYYY-MM');
  inserted     int;
begin
  with most_wins as (
    select s.user_id as profile_id, count(*) filter (where sa.won is true) as value
    from public.sessions s
    join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match' and sa.won is not null
    where coalesce(s.started_at, s.created_at) >= v_season_start
      and coalesce(s.started_at, s.created_at) < v_season_end
    group by s.user_id
    having count(*) filter (where sa.won is true) > 0
    order by value desc
    limit 3
  ),
  most_active as (
    select s.user_id as profile_id, count(distinct s.id) as value
    from public.sessions s
    where coalesce(s.started_at, s.created_at) >= v_season_start
      and coalesce(s.started_at, s.created_at) < v_season_end
    group by s.user_id
    order by value desc
    limit 3
  ),
  rivalry_totals as (
    select
      s.user_id as owner,
      ap.profile_id as opponent,
      count(*) filter (where sa.won is true) - count(*) filter (where sa.won is false) as diff
    from public.sessions s
    join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match' and sa.won is not null
    join public.activity_participants ap on ap.activity_id = sa.id and ap.role = 'opponent' and ap.profile_id is not null
    where coalesce(s.started_at, s.created_at) >= v_season_start
      and coalesce(s.started_at, s.created_at) < v_season_end
    group by s.user_id, ap.profile_id
  ),
  rivalry_champion as (
    select owner as profile_id, max(diff) as value
    from rivalry_totals
    group by owner
    having max(diff) > 0
    order by value desc
    limit 3
  ),
  ranked as (
    select profile_id, 'most_wins' as category, value,
           row_number() over (order by value desc) as rank
    from most_wins
    union all
    select profile_id, 'most_active', value,
           row_number() over (order by value desc)
    from most_active
    union all
    select profile_id, 'rivalry_champion', value,
           row_number() over (order by value desc)
    from rivalry_champion
  ),
  inserted_rows as (
    insert into public.season_awards (profile_id, season_key, category, rank, value)
    select profile_id, v_season_key, category, rank, value
    from ranked
    on conflict (season_key, category, rank) do nothing
    returning profile_id, category, rank
  )
  select count(*) into inserted from inserted_rows;

  insert into public.notifications (user_id, type, detail)
  select profile_id,
         'season_award',
         'You were #1 for ' ||
           (case category
              when 'most_wins'        then 'Most wins'
              when 'most_active'      then 'Most active'
              when 'rivalry_champion' then 'Rivalry champion'
            end)
           || ': ' || to_char(v_season_start, 'Month YYYY')
  from public.season_awards
  where season_key = v_season_key and rank = 1
    and created_at >= now() - interval '5 minutes'; -- only this run's inserts

  return inserted;
end; $$;
