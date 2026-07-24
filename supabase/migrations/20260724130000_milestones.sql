-- Milestones: achievement badges (e.g. "50 matches played", "10-week streak").
-- The catalog of milestone IDs/copy lives client-side (`Milestone.catalog` in
-- Milestones.swift); this migration only persists *which* IDs a user has
-- unlocked, so the shelf survives reinstalls/other devices, and delivers a
-- "you just unlocked X" push the same way every other notification does.

-- --- 1. Unlock storage -------------------------------------------------------
create table if not exists public.milestone_unlocks (
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  milestone_id text not null,
  unlocked_at  timestamptz not null default now(),
  primary key (profile_id, milestone_id)
);

alter table public.milestone_unlocks enable row level security;

drop policy if exists "milestone_unlocks_select_own" on public.milestone_unlocks;
create policy "milestone_unlocks_select_own" on public.milestone_unlocks
  for select using (auth.uid() = profile_id);

drop policy if exists "milestone_unlocks_insert_own" on public.milestone_unlocks;
create policy "milestone_unlocks_insert_own" on public.milestone_unlocks
  for insert with check (auth.uid() = profile_id);

-- --- 2. Allow the new notification type --------------------------------------
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap', 'milestone_unlocked', 'season_award'));

-- --- 3. Unlock RPC ------------------------------------------------------------
-- Client calls this once it detects (from live stats) that a milestone was just
-- crossed, passing the human-readable title alongside the id (the catalog of
-- titles/copy lives client-side in `Milestone.catalog`, not duplicated here).
-- Idempotent: a repeat call for an already-unlocked id is a no-op and returns
-- false, so the client only fires the celebratory analytics/push once.
create or replace function public.unlock_milestone(p_milestone_id text, p_title text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  newly_inserted boolean;
begin
  insert into public.milestone_unlocks (profile_id, milestone_id)
  values (auth.uid(), p_milestone_id)
  on conflict (profile_id, milestone_id) do nothing
  returning true into newly_inserted;

  if newly_inserted then
    insert into public.notifications (user_id, type, detail)
    values (auth.uid(), 'milestone_unlocked', p_title);
  end if;

  return coalesce(newly_inserted, false);
end; $$;

revoke all on function public.unlock_milestone(text, text) from public;
grant execute on function public.unlock_milestone(text, text) to authenticated;
