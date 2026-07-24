-- Premium notifications, phase 2: weekly wrap + rivalry "heating up".
--
-- 1. Weekly wrap: a Sunday-evening push summarizing the week just played.
--    A scheduled job inserts one 'weekly_wrap' notification per active user;
--    the existing on_notification_dispatch_push trigger delivers it, and
--    send-push formats the 'weekly_wrap' message from the row's `detail`.
-- 2. Heating up: notify_on_rivalry already fires on lead changes/ties. This adds
--    a branch so that when the session owner extends a hot streak to a milestone
--    (3, then every 5th) against an opponent, that opponent gets a heat push.
--    Folded into the same function so a match still yields at most one rivalry row.

-- --- 1. Allow the new type (keep every existing type) ------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap'));

-- --- 2. Weekly wrap job ------------------------------------------------------
-- One 'weekly_wrap' per user who logged a session this (Monday-based) week and
-- has a device token. Idempotent: skips anyone already wrapped this week.
create or replace function public.notify_weekly_wrap()
returns int language plpgsql security definer set search_path = public as $$
declare inserted int;
begin
  with wk as (
    select date_trunc('week', now()) as start
  ),
  per_user as (
    select
      s.user_id,
      count(distinct s.id)                              as sessions,
      count(*) filter (where sa.won is true)            as wins,
      count(*) filter (where sa.won is false)           as losses
    from public.sessions s
    left join public.session_activities sa
      on sa.session_id = s.id and sa.kind = 'match' and sa.won is not null
    where coalesce(s.started_at, s.created_at) >= (select start from wk)
    group by s.user_id
  ),
  targets as (
    insert into public.notifications (user_id, type, detail)
    select
      pu.user_id, 'weekly_wrap',
      'Your week: ' || pu.sessions
        || ' session' || (case when pu.sessions = 1 then '' else 's' end)
        || (case when (pu.wins + pu.losses) > 0
                 then ', ' || pu.wins || '–' || pu.losses || ' in matches'
                 else '' end)
        || '. Tap to see your wrap.'
    from per_user pu
    where pu.sessions > 0
      and exists (select 1 from public.device_tokens dt where dt.user_id = pu.user_id)
      and not exists (
        select 1 from public.notifications n
        where n.user_id = pu.user_id and n.type = 'weekly_wrap'
          and n.created_at >= (select start from wk)
      )
    returning 1
  )
  select count(*) into inserted from targets;
  return inserted;
end; $$;

-- Sunday 23:00 UTC (~evening in the Americas), while the Monday-based week is
-- still current so the wrap covers the week just finished. Best effort — needs
-- pg_cron (already used by streak-reminders).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'weekly-wrap',
      '0 23 * * 0',
      'select public.notify_weekly_wrap();'
    );
  else
    raise notice 'pg_cron not enabled — enable it, then: select cron.schedule(''weekly-wrap'',''0 23 * * 0'',''select public.notify_weekly_wrap();'');';
  end if;
exception when others then
  raise notice 'Could not schedule weekly wrap automatically (%). Schedule manually once pg_cron is enabled.', sqlerrm;
end $$;

-- --- 3. Rivalry trigger, now with a "heating up" branch ----------------------
create or replace function public.notify_on_rivalry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  owner        uuid;
  opp          uuid;
  this_won     boolean;
  wins         int;
  losses       int;
  prev_wins    int;
  prev_losses  int;
  total        int;
  streak       int := 0;
  m            record;
  owner_handle text;
  detail       text;
begin
  if new.role <> 'opponent' or new.profile_id is null then
    return new;
  end if;

  opp := new.profile_id;
  select user_id into owner from public.sessions where id = new.session_id;
  if owner is null or owner = opp then
    return new;
  end if;

  -- Only completed match activities count.
  select won into this_won from public.session_activities where id = new.activity_id;
  if this_won is null then
    return new;
  end if;

  -- Owner-perspective record vs this opponent, including the match just logged.
  select
    count(*) filter (where sa.won),
    count(*) filter (where not sa.won)
  into wins, losses
  from public.activity_participants ap
  join public.session_activities sa on sa.id = ap.activity_id
  join public.sessions s on s.id = sa.session_id
  where ap.role = 'opponent'
    and ap.profile_id = opp
    and s.user_id = owner
    and sa.kind = 'match'
    and sa.won is not null;

  total := wins + losses;
  if total < 2 then                       -- one game is not yet a rivalry
    return new;
  end if;

  prev_wins   := wins   - (case when this_won then 1 else 0 end);
  prev_losses := losses - (case when this_won then 0 else 1 end);

  -- Current head-to-head streak: consecutive most-recent meetings that match the
  -- one just logged (owner-perspective, newest first).
  for m in
    select sa.won
    from public.activity_participants ap
    join public.session_activities sa on sa.id = ap.activity_id
    join public.sessions s on s.id = sa.session_id
    where ap.role = 'opponent'
      and ap.profile_id = opp
      and s.user_id = owner
      and sa.kind = 'match'
      and sa.won is not null
    order by s.created_at desc, sa.position desc
  loop
    if m.won = this_won then streak := streak + 1;
    else exit;
    end if;
  end loop;

  select username into owner_handle from public.profiles where id = owner;

  -- Record is phrased from the recipient's (opponent's) point of view:
  -- their wins are the owner's losses, and vice-versa.
  if wins = losses and prev_wins <> prev_losses then
    detail := '@' || owner_handle || ' evened your rivalry at ' || wins || '–' || losses;
  elsif wins > losses and prev_wins <= prev_losses then
    detail := '@' || owner_handle || ' took the lead in your rivalry, ' || losses || '–' || wins;
  elsif losses > wins and prev_losses <= prev_wins then
    detail := 'You took the lead over @' || owner_handle || ', ' || losses || '–' || wins;
  elsif this_won and streak >= 3 and (streak = 3 or streak % 5 = 0) then
    -- No lead change, but the owner is on a hot run against this opponent.
    detail := '@' || owner_handle || ' is heating up — ' || streak || ' straight against you';
  else
    return new;                           -- nothing notable, stay quiet
  end if;

  insert into public.notifications (user_id, actor_id, type, session_id, detail)
  values (opp, owner, 'rivalry', new.session_id, detail);
  return new;
end; $$;

drop trigger if exists on_rivalry_match on public.activity_participants;
create trigger on_rivalry_match after insert on public.activity_participants
  for each row execute function public.notify_on_rivalry();
