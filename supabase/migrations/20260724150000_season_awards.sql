-- Season awards: monthly, global (not crew-scoped — a per-viewer "winner"
-- wouldn't make sense for a prestige feature, unlike the crew leaderboard).
-- Computed by a pg_cron job on the 1st of each month for the month just ended,
-- same idiom as notify_weekly_wrap() in 20260724000000_weekly_wrap_and_heating_up.sql.

-- --- 1. Storage ---------------------------------------------------------------
create table if not exists public.season_awards (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  season_key  text not null, -- e.g. '2026-07' (calendar month)
  category    text not null check (category in ('most_wins', 'most_active', 'rivalry_champion')),
  rank        int not null check (rank between 1 and 3),
  value       int not null,
  created_at  timestamptz not null default now(),
  unique (season_key, category, rank)
);

alter table public.season_awards enable row level security;

drop policy if exists "season_awards_select_own" on public.season_awards;
create policy "season_awards_select_own" on public.season_awards
  for select using (auth.uid() = profile_id);

-- --- 2. Allow the new notification type (idempotent, mirrors prior migrations) --
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap', 'milestone_unlocked', 'season_award'));

-- --- 3. Compute job -------------------------------------------------------------
-- For the calendar month that just ended, ranks the top 3 profiles in each
-- category and inserts them, plus a 'season_award' notification for each #1.
-- Idempotent via the (season_key, category, rank) unique constraint.
create or replace function public.compute_season_awards()
returns int language plpgsql security definer set search_path = public as $$
declare
  season_start timestamptz := date_trunc('month', now()) - interval '1 month';
  season_end   timestamptz := date_trunc('month', now());
  season_key   text := to_char(season_start, 'YYYY-MM');
  inserted     int;
begin
  with most_wins as (
    select s.user_id as profile_id, count(*) filter (where sa.won is true) as value
    from public.sessions s
    join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match' and sa.won is not null
    where coalesce(s.started_at, s.created_at) >= season_start
      and coalesce(s.started_at, s.created_at) < season_end
    group by s.user_id
    having count(*) filter (where sa.won is true) > 0
    order by value desc
    limit 3
  ),
  most_active as (
    select s.user_id as profile_id, count(distinct s.id) as value
    from public.sessions s
    where coalesce(s.started_at, s.created_at) >= season_start
      and coalesce(s.started_at, s.created_at) < season_end
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
    where coalesce(s.started_at, s.created_at) >= season_start
      and coalesce(s.started_at, s.created_at) < season_end
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
    select profile_id, season_key, category, rank, value
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
           || ' — ' || to_char(season_start, 'Month YYYY')
  from public.season_awards
  where season_key = season_key and rank = 1
    and created_at >= now() - interval '5 minutes'; -- only this run's inserts

  return inserted;
end; $$;

-- 00:05 UTC on the 1st of each month, computing for the month just ended.
-- Best effort — needs pg_cron (already used by weekly-wrap/streak-reminders).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'season-awards',
      '5 0 1 * *',
      'select public.compute_season_awards();'
    );
  else
    raise notice 'pg_cron not enabled — enable it, then: select cron.schedule(''season-awards'',''5 0 1 * *'',''select public.compute_season_awards();'');';
  end if;
exception when others then
  raise notice 'Could not schedule season awards automatically (%). Schedule manually once pg_cron is enabled.', sqlerrm;
end $$;
