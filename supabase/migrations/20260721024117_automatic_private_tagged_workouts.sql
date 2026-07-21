-- Automatically credit posted matches to tagged mutual friends without
-- publishing anything on their behalf. The existing repost wrapper remains a
-- lightweight reference to the canonical session; `posted = false` makes the
-- credit private while still allowing the owner to load it in Workout.

create or replace function repost_internal.ensure_private_workout_credit(
  source_session_id uuid,
  target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  source_session public.sessions;
  credit_id uuid := gen_random_uuid();
begin
  select s.* into source_session
  from public.sessions s
  where s.id = source_session_id
  for share;

  if source_session.id is null
     or source_session.reposted_from is not null
     or not source_session.posted
     or source_session.user_id = target_user_id
     or not private.is_mutual_follow(source_session.user_id, target_user_id)
     or private.is_blocked_between(source_session.user_id, target_user_id)
     or not exists (
       select 1
       from public.activity_participants ap
       join public.session_activities sa on sa.id = ap.activity_id
       where ap.session_id = source_session_id
         and ap.profile_id = target_user_id
         and sa.kind = 'match'
     ) then
    return null;
  end if;

  insert into public.sessions (
    id, user_id, title, location, duration_minutes, focus, takeaway, posted,
    started_at, ended_at, reposted_from, created_at
  ) values (
    credit_id, target_user_id, source_session.title, source_session.location,
    source_session.duration_minutes, source_session.focus, source_session.takeaway,
    false, source_session.started_at, source_session.ended_at,
    source_session.id, source_session.created_at
  )
  on conflict (user_id, reposted_from) where reposted_from is not null
  do nothing
  returning id into credit_id;

  if credit_id is null then
    select s.id into credit_id
    from public.sessions s
    where s.user_id = target_user_id
      and s.reposted_from = source_session_id;
  end if;

  return credit_id;
end;
$$;

revoke all on function repost_internal.ensure_private_workout_credit(uuid, uuid)
  from public, anon, authenticated;

-- Mutual friends can still choose to make the credited session a public
-- repost. No approval request is required. If the private credit already
-- exists, publishing simply promotes that wrapper instead of duplicating it.
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
      created_at = case when posted then created_at else now() end
  where id = repost_id;

  return repost_id;
end;
$$;

revoke all on function repost_internal.create_repost(uuid, uuid) from public, anon;
grant execute on function repost_internal.create_repost(uuid, uuid) to authenticated;

-- Removing a public repost returns it to its original private-credit state;
-- it must not erase the workout record that was added automatically.
create or replace function repost_internal.unpublish_repost(
  wrapper_session_id uuid,
  target_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or auth.uid() <> target_user_id then
    raise exception 'You can only remove your own repost';
  end if;

  update public.sessions
  set posted = false
  where id = wrapper_session_id
    and user_id = target_user_id
    and reposted_from is not null;

  if not found then raise exception 'Repost not found'; end if;
end;
$$;

revoke all on function repost_internal.unpublish_repost(uuid, uuid)
  from public, anon;
grant execute on function repost_internal.unpublish_repost(uuid, uuid)
  to authenticated;

create or replace function public.unrepost_session(wrapper_session_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  select repost_internal.unpublish_repost(wrapper_session_id, auth.uid());
$$;

revoke all on function public.unrepost_session(uuid) from public, anon;
grant execute on function public.unrepost_session(uuid) to authenticated;

-- Reconcile all tagged mutual friends whenever an original becomes public.
-- Making the original private again removes the derived workout credits.
create or replace function repost_internal.sync_credits_after_session_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  tagged_user_id uuid;
begin
  if new.reposted_from is not null then return new; end if;

  if not new.posted then
    delete from public.sessions wrapper
    where wrapper.reposted_from = new.id;
    return new;
  end if;

  for tagged_user_id in
    select distinct ap.profile_id
    from public.activity_participants ap
    join public.session_activities sa on sa.id = ap.activity_id
    where ap.session_id = new.id
      and ap.profile_id is not null
      and sa.kind = 'match'
      and private.is_mutual_follow(new.user_id, ap.profile_id)
  loop
    perform repost_internal.ensure_private_workout_credit(new.id, tagged_user_id);
  end loop;
  return new;
end;
$$;

revoke all on function repost_internal.sync_credits_after_session_change()
  from public, anon, authenticated;
drop trigger if exists sync_tagged_workouts_after_session_change on public.sessions;
create trigger sync_tagged_workouts_after_session_change
  after insert or update of posted on public.sessions
  for each row execute function repost_internal.sync_credits_after_session_change();

-- Edits can tag a new friend after the session is already public, so also
-- create the private credit when a qualifying participant row is inserted.
create or replace function repost_internal.credit_after_participant_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  source_session public.sessions;
  activity_kind text;
begin
  if new.profile_id is null then return new; end if;

  select s.* into source_session
  from public.sessions s
  where s.id = new.session_id;
  select sa.kind into activity_kind
  from public.session_activities sa
  where sa.id = new.activity_id;

  if source_session.id is not null
     and source_session.reposted_from is null
     and source_session.posted
     and activity_kind = 'match'
     and private.is_mutual_follow(source_session.user_id, new.profile_id) then
    perform repost_internal.ensure_private_workout_credit(
      source_session.id,
      new.profile_id
    );
  end if;
  return new;
end;
$$;

revoke all on function repost_internal.credit_after_participant_change()
  from public, anon, authenticated;
drop trigger if exists credit_tagged_workout_after_participant_change
  on public.activity_participants;
create trigger credit_tagged_workout_after_participant_change
  after insert or update of profile_id, activity_id, session_id
  on public.activity_participants
  for each row execute function repost_internal.credit_after_participant_change();

-- A credit remains valid only while the user is tagged in at least one match.
create or replace function private.cleanup_repost_after_tag_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.profile_id is not null
     and not exists (
       select 1
       from public.activity_participants ap
       join public.session_activities sa on sa.id = ap.activity_id
       where ap.session_id = old.session_id
         and ap.profile_id = old.profile_id
         and sa.kind = 'match'
     ) then
    delete from public.sessions s
    where s.user_id = old.profile_id
      and s.reposted_from = old.session_id;
  end if;
  return null;
end;
$$;

revoke all on function private.cleanup_repost_after_tag_change()
  from public, anon, authenticated;

-- Backfill already-posted matches without changing any public repost that the
-- tagged player previously chose to publish.
insert into public.sessions (
  id, user_id, title, location, duration_minutes, focus, takeaway, posted,
  started_at, ended_at, reposted_from, created_at
)
select
  gen_random_uuid(), tagged.profile_id, source.title, source.location,
  source.duration_minutes, source.focus, source.takeaway, false,
  source.started_at, source.ended_at, source.id, source.created_at
from public.sessions source
join (
  select distinct ap.session_id, ap.profile_id
  from public.activity_participants ap
  join public.session_activities sa on sa.id = ap.activity_id
  where ap.profile_id is not null and sa.kind = 'match'
) tagged on tagged.session_id = source.id
where source.reposted_from is null
  and source.posted
  and source.user_id <> tagged.profile_id
  and private.is_mutual_follow(source.user_id, tagged.profile_id)
  and not private.is_blocked_between(source.user_id, tagged.profile_id)
on conflict (user_id, reposted_from) where reposted_from is not null do nothing;
