-- Notify the original author when a tagged mutual friend publishes a repost.
-- Publishing happens inside repost_internal.create_repost (the private workout
-- credit is promoted to posted = true); only that transition should notify,
-- not the earlier automatic private-credit creation.

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap', 'milestone_unlocked', 'season_award'));

create or replace function repost_internal.create_repost(
  source_session_id uuid,
  target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  source_session public.sessions;
  repost_id uuid;
  published_now boolean;
begin
  if caller_id is null or caller_id <> target_user_id then
    raise exception 'You can only repost into your own log';
  end if;

  select s.* into source_session
  from public.sessions s
  where s.id = source_session_id
  for share;

  if source_session.id is null then raise exception 'Session not found'; end if;
  if source_session.user_id = target_user_id then raise exception 'You cannot repost your own session'; end if;
  if source_session.reposted_from is not null then raise exception 'Reposted sessions cannot be reposted again'; end if;
  if not source_session.posted then raise exception 'Only posted sessions can be reposted'; end if;
  if not private.can_view_session(target_user_id, source_session_id) then raise exception 'Session not found'; end if;
  if not exists (
    select 1
    from public.activity_participants ap
    join public.session_activities sa on sa.id = ap.activity_id
    where ap.session_id = source_session_id
      and ap.profile_id = target_user_id
      and sa.kind = 'match'
  ) then
    raise exception 'You are not tagged in a match in this session';
  end if;
  if not private.is_mutual_follow(source_session.user_id, target_user_id) then
    raise exception 'Only mutual friends can repost without approval';
  end if;

  repost_id := repost_internal.ensure_private_workout_credit(
    source_session_id,
    target_user_id
  );
  if repost_id is null then raise exception 'Session is not eligible for reposting'; end if;

  update public.sessions
  set posted = true,
      created_at = now()
  where id = repost_id
    and not posted
  returning true into published_now;

  if published_now then
    insert into public.notifications (user_id, actor_id, type, session_id)
    values (source_session.user_id, target_user_id, 'repost', repost_id);
  end if;

  return repost_id;
end;
$$;

revoke all on function repost_internal.create_repost(uuid, uuid) from public, anon;
grant execute on function repost_internal.create_repost(uuid, uuid) to authenticated;
