-- Goals Pro feature: the weekly-goal + streak-save reminder toggle in
-- GoalsSheet was local-only (@AppStorage) — flipping it off did nothing
-- server-side, so notify_streak_reminders() pinged every at-risk user
-- regardless of preference. Sync the setting to profiles and honor it.

alter table public.profiles
  add column if not exists weekly_goal int not null default 3,
  add column if not exists streak_reminders_enabled boolean not null default true;

alter table public.profiles
  add constraint profiles_weekly_goal_range check (weekly_goal between 1 and 14);

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
      and p.streak_reminders_enabled
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
