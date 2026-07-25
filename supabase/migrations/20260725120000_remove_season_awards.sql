-- Remove the season awards feature entirely: the monthly cron job, the compute
-- function, the storage table, and the 'season_award' notification type.

-- --- 1. Unschedule the monthly job (best effort — pg_cron may not be enabled) --
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'season-awards') then
      perform cron.unschedule('season-awards');
    end if;
  end if;
exception when others then
  raise notice 'Could not unschedule season-awards (%). Remove it manually.', sqlerrm;
end $$;

-- --- 2. Drop the compute function and the table -------------------------------
drop function if exists public.compute_season_awards();
drop table if exists public.season_awards; -- RLS policy drops with the table

-- --- 3. Retire the notification type ------------------------------------------
delete from public.notifications where type = 'season_award';

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap', 'milestone_unlocked'));
