-- Streaks Phase 2: "your streak ends Sunday" reminder push.
--
-- Adds a 'streak' notification type, a SQL function that computes a user's weekly
-- play streak, and a scheduled job that notifies at-risk users (an active streak
-- who haven't played yet this week). The existing on_notification_dispatch_push
-- trigger delivers the push; send-push formats the 'streak' message.

-- 1. Allow the new type (keep every existing type).
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved',
                  'invite_received', 'invite_response', 'invite_cancelled',
                  'rivalry', 'streak'));

-- 2. Weekly play streak (consecutive Monday-based weeks with ≥1 session, ending
--    at the current or last week). Gaps-and-islands: consecutive weeks share the
--    same (week - rownum*7) key. Returns 0 if a full empty week has elapsed.
create or replace function public.user_weekly_streak(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  with weeks as (
    select distinct date_trunc('week', coalesce(started_at, created_at))::date as wk
    from public.sessions
    where user_id = p_user
  ),
  islands as (
    -- row_number() is bigint; cast to int so `date - int` (a valid operator) applies.
    select wk, (wk - (row_number() over (order by wk))::int * 7) as grp
    from weeks
  ),
  runs as (
    select grp, count(*)::int as len, max(wk) as last_wk
    from islands group by grp
  )
  select coalesce((
    select len from runs
    -- run is "alive" only if its most recent week is this week or last week
    where last_wk >= (date_trunc('week', now()) - interval '7 day')::date
    order by last_wk desc limit 1
  ), 0);
$$;

-- 3. Insert one reminder per at-risk user. Guards: has a device token, streak ≥ 2,
--    no session yet this week, and not already reminded this week (idempotent).
create or replace function public.notify_streak_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare inserted int;
begin
  with targets as (
    insert into public.notifications (user_id, type, detail)
    select p.id, 'streak',
           'Your ' || s.streak || '-week streak ends Sunday — log a session to keep it alive.'
    from public.profiles p
    cross join lateral (select public.user_weekly_streak(p.id) as streak) s
    where s.streak >= 2
      and exists (select 1 from public.device_tokens dt where dt.user_id = p.id)
      and not exists (
        select 1 from public.sessions se
        where se.user_id = p.id
          and date_trunc('week', coalesce(se.started_at, se.created_at)) = date_trunc('week', now())
      )
      and not exists (
        select 1 from public.notifications n
        where n.user_id = p.id and n.type = 'streak'
          and n.created_at >= date_trunc('week', now())
      )
    returning 1
  )
  select count(*) into inserted from targets;
  return inserted;
end;
$$;

-- 4. Schedule it Sat & Sun 16:00 UTC (weekend, before the Monday reset) — best
--    effort: only if pg_cron is available. If this project doesn't have pg_cron
--    enabled, enable it in the Supabase dashboard (Database → Extensions) and then
--    run the cron.schedule(...) line below once by hand.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'streak-reminders',
      '0 16 * * 6,0',
      'select public.notify_streak_reminders();'
    );
  else
    raise notice 'pg_cron not enabled — enable it, then: select cron.schedule(''streak-reminders'',''0 16 * * 6,0'',''select public.notify_streak_reminders();'');';
  end if;
exception when others then
  raise notice 'Could not schedule streak reminders automatically (%). Schedule manually once pg_cron is enabled.', sqlerrm;
end $$;
