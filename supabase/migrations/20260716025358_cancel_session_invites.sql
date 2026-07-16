-- Soft-cancel session invites so recipients retain a durable cancellation
-- notification and can still open the invite for context.

alter table public.session_invites
  add column if not exists cancelled_at timestamptz;

comment on column public.session_invites.cancelled_at is
  'When set, the host canceled this invite and it no longer belongs in Upcoming.';

create index if not exists session_invites_upcoming_idx
  on public.session_invites (scheduled_at)
  where cancelled_at is null;

-- Hosts may only cancel their own active invites. Column-level privileges keep
-- the client from changing the court, host, or scheduled time through UPDATE.
drop policy if exists "session_invites_cancel" on public.session_invites;
create policy "session_invites_cancel" on public.session_invites
  for update to authenticated
  using (
    host_id = (select auth.uid())
    and cancelled_at is null
    and private.is_active_user((select auth.uid()))
  )
  with check (
    host_id = (select auth.uid())
    and cancelled_at is not null
    and private.is_active_user((select auth.uid()))
  );

revoke update on public.session_invites from authenticated;
grant update (cancelled_at) on public.session_invites to authenticated;

-- Cancellation is its own durable notification type.
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved',
                  'invite_received', 'invite_response', 'invite_cancelled',
                  'rivalry'));

-- Notify every recipient once when an invite transitions to canceled. This is
-- private trigger-only code: clients cannot call it through the Data API.
create or replace function private.notify_on_invite_cancelled()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  host_handle text;
  court_name text;
begin
  if old.cancelled_at is null and new.cancelled_at is not null then
    select p.username into host_handle
    from public.profiles p
    where p.id = new.host_id;

    select c.name into court_name
    from public.courts c
    where c.id = new.court_id;

    insert into public.notifications (user_id, actor_id, type, invite_id, detail)
    select
      r.user_id,
      new.host_id,
      'invite_cancelled',
      new.id,
      '@' || coalesce(host_handle, 'player') || ' canceled the invite to '
        || coalesce(court_name, 'the court')
    from public.invite_recipients r
    where r.invite_id = new.id
      and r.user_id <> new.host_id;
  end if;

  return new;
end;
$$;

revoke all on function private.notify_on_invite_cancelled() from public, anon, authenticated;

drop trigger if exists on_session_invite_cancelled on public.session_invites;
create trigger on_session_invite_cancelled
  after update of cancelled_at on public.session_invites
  for each row execute function private.notify_on_invite_cancelled();
