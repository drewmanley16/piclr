-- Post-level weekly-streak badge.
--
-- Stamps the session that *extends* a user's weekly play streak with the streak
-- length it reached (>= 2 weeks), so the feed can badge "N week streak" on that
-- post. Only the first session of a new week earns the badge, and the value is
-- frozen on the row — a post from three weeks ago keeps saying "3 week streak"
-- even after the streak grows. Reuses `public.user_weekly_streak` (added in
-- 20260718000000_streak_reminders).

-- 1. The frozen streak value. Nullable: most posts don't earn a badge.
alter table public.sessions add column if not exists streak_week int;

-- 2. On insert, if this is the user's first session of its (Monday-based) week
--    and their current weekly streak is >= 2, stamp the streak length. Written
--    in a second statement (AFTER INSERT) so `user_weekly_streak` counts the row
--    just added — the fresh session is what makes this week "active".
create or replace function public.stamp_session_streak()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wk date := date_trunc('week', coalesce(new.started_at, new.created_at))::date;
  streak int;
begin
  -- Only the first session of its week earns the badge.
  if exists (
    select 1 from public.sessions s
    where s.user_id = new.user_id
      and s.id <> new.id
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

drop trigger if exists on_session_stamp_streak on public.sessions;
create trigger on_session_stamp_streak
  after insert on public.sessions
  for each row execute function public.stamp_session_streak();

-- 3. Backfill: stamp the first session of every historical week whose run length
--    (consecutive Monday-weeks up to and including it) is >= 2. Gaps-and-islands
--    on distinct weeks per user; `len` is the week's 1-based position in its run.
with weeks as (
  select user_id, date_trunc('week', coalesce(started_at, created_at))::date as wk
  from public.sessions
  group by 1, 2
),
islands as (
  select user_id, wk,
         (wk - (row_number() over (partition by user_id order by wk))::int * 7) as grp
  from weeks
),
ranked as (
  select user_id, wk,
         row_number() over (partition by user_id, grp order by wk) as len
  from islands
),
first_session as (
  select distinct on (s.user_id, date_trunc('week', coalesce(s.started_at, s.created_at))::date)
         s.id, s.user_id,
         date_trunc('week', coalesce(s.started_at, s.created_at))::date as wk
  from public.sessions s
  order by s.user_id,
           date_trunc('week', coalesce(s.started_at, s.created_at))::date,
           coalesce(s.started_at, s.created_at) asc, s.id
)
update public.sessions s
set streak_week = r.len
from first_session fs
join ranked r on r.user_id = fs.user_id and r.wk = fs.wk
where s.id = fs.id and r.len >= 2 and s.streak_week is distinct from r.len;
