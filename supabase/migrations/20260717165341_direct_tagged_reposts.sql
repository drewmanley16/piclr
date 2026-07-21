-- A tag is consent to repost. A repost is only an event owned by the tagged
-- player; all post content remains canonical on the original session.

-- Keep privileged implementations outside the Data API's exposed schema.
create schema if not exists repost_internal;
revoke all on schema repost_internal from public, anon;
grant usage on schema repost_internal to authenticated;

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
  new_session_id uuid := gen_random_uuid();
begin
  if caller_id is null or caller_id <> target_user_id then
    raise exception 'You can only repost into your own log';
  end if;

  select s.* into source_session
  from public.sessions s
  where s.id = source_session_id
  for share;

  if source_session.id is null then
    raise exception 'Session not found';
  end if;
  if source_session.user_id = target_user_id then
    raise exception 'You cannot repost your own session';
  end if;
  if source_session.reposted_from is not null then
    raise exception 'Reposted sessions cannot be reposted again';
  end if;
  if not source_session.posted then
    raise exception 'Only posted sessions can be reposted';
  end if;
  if not private.can_view_session(target_user_id, source_session_id) then
    raise exception 'Session not found';
  end if;
  if not exists (
    select 1
    from public.activity_participants ap
    where ap.session_id = source_session_id
      and ap.profile_id = target_user_id
  ) then
    raise exception 'You are not tagged in this session';
  end if;

  -- The wrapper carries the repost owner, repost time, and canonical reference.
  -- Source metadata is copied only as a compatibility fallback for older reads;
  -- new clients always render through reposted_from.
  insert into public.sessions (
    id, user_id, title, location, duration_minutes, focus, takeaway, posted,
    started_at, ended_at, reposted_from, created_at
  ) values (
    new_session_id, target_user_id, source_session.title, source_session.location,
    source_session.duration_minutes, source_session.focus, source_session.takeaway,
    true, source_session.started_at, source_session.ended_at, source_session.id, now()
  )
  on conflict (user_id, reposted_from) where reposted_from is not null
  do nothing
  returning id into new_session_id;

  if new_session_id is null then
    select s.id into new_session_id
    from public.sessions s
    where s.user_id = target_user_id
      and s.reposted_from = source_session_id;
  end if;

  update public.repost_requests
  set status = 'approved', updated_at = now()
  where session_id = source_session_id
    and requester_id = target_user_id
    and status = 'pending';

  return new_session_id;
end;
$$;

revoke all on function repost_internal.create_repost(uuid, uuid) from public, anon;
grant execute on function repost_internal.create_repost(uuid, uuid) to authenticated;

create or replace function public.repost_session(source_session_id uuid)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select repost_internal.create_repost(source_session_id, auth.uid());
$$;

revoke all on function public.repost_session(uuid) from public, anon;
grant execute on function public.repost_session(uuid) to authenticated;

-- PostgREST requires a computed relationship for recursive/self-referencing
-- embeds. ROWS 1 marks this as the to-one canonical source of a wrapper.
create or replace function public.repost_source(wrapper public.sessions)
returns setof public.sessions
rows 1
language sql
stable
security invoker
set search_path = ''
as $$
  select source.*
  from public.sessions source
  where source.id = wrapper.reposted_from;
$$;
revoke all on function public.repost_source(public.sessions) from public, anon;
grant execute on function public.repost_source(public.sessions) to authenticated;

-- Repost wrappers are immutable content references. Their owner may delete the
-- wrapper to undo a repost, but may not edit it or attach child activities.
drop policy if exists "sessions_update" on public.sessions;
create policy "sessions_update" on public.sessions
  for update to authenticated
  using (
    user_id = (select auth.uid())
    and reposted_from is null
    and private.is_active_user((select auth.uid()))
  )
  with check (
    user_id = (select auth.uid())
    and reposted_from is null
    and private.is_active_user((select auth.uid()))
  );

drop policy if exists "session_activities_write" on public.session_activities;
create policy "session_activities_write" on public.session_activities
  for all to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and exists (
      select 1 from public.sessions s
      where s.id = session_activities.session_id
        and s.user_id = (select auth.uid())
        and s.reposted_from is null
    )
  )
  with check (
    private.is_active_user((select auth.uid()))
    and exists (
      select 1 from public.sessions s
      where s.id = session_activities.session_id
        and s.user_id = (select auth.uid())
        and s.reposted_from is null
    )
  );

drop policy if exists "activity_participants_owner_insert" on public.activity_participants;
drop policy if exists "activity_participants_owner_update" on public.activity_participants;
drop policy if exists "activity_participants_owner_delete" on public.activity_participants;
create policy "activity_participants_owner_insert" on public.activity_participants
  for insert to authenticated
  with check (
    private.is_active_user((select auth.uid()))
    and (profile_id is null or not private.is_blocked_between((select auth.uid()), profile_id))
    and exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id
        and s.user_id = (select auth.uid())
        and s.reposted_from is null
    )
    and exists (
      select 1 from public.session_activities a
      where a.id = activity_participants.activity_id
        and a.session_id = activity_participants.session_id
    )
  );
create policy "activity_participants_owner_update" on public.activity_participants
  for update to authenticated
  using (exists (
    select 1 from public.sessions s
    where s.id = activity_participants.session_id
      and s.user_id = (select auth.uid())
      and s.reposted_from is null
  ))
  with check (
    (profile_id is null or not private.is_blocked_between((select auth.uid()), profile_id))
    and exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id
        and s.user_id = (select auth.uid())
        and s.reposted_from is null
    )
  );
create policy "activity_participants_owner_delete" on public.activity_participants
  for delete to authenticated
  using (exists (
    select 1 from public.sessions s
    where s.id = activity_participants.session_id
      and s.user_id = (select auth.uid())
      and s.reposted_from is null
  ));

-- If the tagged player removes their last tag, or the author edits it away,
-- consent no longer exists and the corresponding repost wrapper is removed.
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
       where ap.session_id = old.session_id
         and ap.profile_id = old.profile_id
     ) then
    delete from public.sessions s
    where s.user_id = old.profile_id
      and s.reposted_from = old.session_id;
  end if;
  return null;
end;
$$;
revoke all on function private.cleanup_repost_after_tag_change() from public, anon, authenticated;
drop trigger if exists cleanup_repost_after_tag_change on public.activity_participants;
create trigger cleanup_repost_after_tag_change
  after delete or update of profile_id, session_id on public.activity_participants
  for each row execute function private.cleanup_repost_after_tag_change();

-- Blocking removes repost relationships in either direction.
create or replace function private.cleanup_blocked_reposts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.sessions child
  using public.sessions source
  where child.reposted_from = source.id
    and (
      (child.user_id = new.blocker_id and source.user_id = new.blocked_id)
      or (child.user_id = new.blocked_id and source.user_id = new.blocker_id)
    );
  return new;
end;
$$;
revoke all on function private.cleanup_blocked_reposts() from public, anon, authenticated;
drop trigger if exists cleanup_blocked_reposts on public.blocks;
create trigger cleanup_blocked_reposts
  after insert on public.blocks
  for each row execute function private.cleanup_blocked_reposts();

-- Keep notification trigger implementations private. Wrapper creation has no
-- participant inserts, so it cannot generate tag or rivalry notifications.
drop trigger if exists on_tag_created on public.activity_participants;
drop function if exists public.notify_on_tag();
create or replace function private.notify_on_tag()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  author uuid;
  source_id uuid;
begin
  if new.profile_id is not null then
    select s.user_id, s.reposted_from
    into author, source_id
    from public.sessions s
    where s.id = new.session_id;

    if source_id is null and author is not null and author <> new.profile_id then
      insert into public.notifications (user_id, actor_id, type, session_id)
      values (new.profile_id, author, 'tag', new.session_id);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.notify_on_tag() from public, anon, authenticated;
create trigger on_tag_created
  after insert on public.activity_participants
  for each row execute function private.notify_on_tag();

drop trigger if exists on_rivalry_match on public.activity_participants;
drop function if exists public.notify_on_rivalry();
create or replace function private.notify_on_rivalry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  source_id uuid;
  opp uuid;
  this_won boolean;
  wins int;
  losses int;
  prev_wins int;
  prev_losses int;
  total int;
  owner_handle text;
  notification_detail text;
begin
  if new.role <> 'opponent' or new.profile_id is null then
    return new;
  end if;

  opp := new.profile_id;
  select s.user_id, s.reposted_from
  into owner, source_id
  from public.sessions s
  where s.id = new.session_id;

  if source_id is not null or owner is null or owner = opp then
    return new;
  end if;

  select sa.won into this_won
  from public.session_activities sa
  where sa.id = new.activity_id;
  if this_won is null then
    return new;
  end if;

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
    and s.reposted_from is null
    and sa.kind = 'match'
    and sa.won is not null;

  total := wins + losses;
  if total < 2 then return new; end if;

  prev_wins := wins - (case when this_won then 1 else 0 end);
  prev_losses := losses - (case when this_won then 0 else 1 end);
  select p.username into owner_handle from public.profiles p where p.id = owner;

  if wins = losses and prev_wins <> prev_losses then
    notification_detail := '@' || owner_handle || ' evened your rivalry at '
      || wins || '–' || losses;
  elsif wins > losses and prev_wins <= prev_losses then
    notification_detail := '@' || owner_handle || ' took the lead in your rivalry, '
      || losses || '–' || wins;
  elsif losses > wins and prev_losses <= prev_wins then
    notification_detail := 'You took the lead over @' || owner_handle || ', '
      || losses || '–' || wins;
  else
    return new;
  end if;

  insert into public.notifications (user_id, actor_id, type, session_id, detail)
  values (opp, owner, 'rivalry', new.session_id, notification_detail);
  return new;
end;
$$;
revoke all on function private.notify_on_rivalry() from public, anon, authenticated;
create trigger on_rivalry_match
  after insert on public.activity_participants
  for each row execute function private.notify_on_rivalry();

-- Rank records from canonical originals. A reposted match counts only when the
-- repost owner is tagged, and the result is projected from that player's side.
create or replace function repost_internal.crew_leaderboard_for(viewer_id uuid)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  avatar_initials text,
  wins int,
  losses int,
  matches int
)
language sql
stable
security definer
set search_path = ''
as $$
  with crew as (
    select viewer_id as id
    where viewer_id = auth.uid()
    union
    select f.followee_id
    from public.follows f
    where viewer_id = auth.uid()
      and f.follower_id = viewer_id
      and f.status = 'accepted'
  ), projected_matches as (
    select
      s.user_id as player_id,
      case
        when sa.team_score is null or sa.opponent_score is null
          or sa.team_score = sa.opponent_score then null
        else sa.team_score > sa.opponent_score
      end as won
    from public.sessions s
    join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match'
    join crew c on c.id = s.user_id
    where s.reposted_from is null

    union all

    select
      wrapper.user_id as player_id,
      case
        when sa.team_score is null or sa.opponent_score is null
          or sa.team_score = sa.opponent_score then null
        when tag.role = 'opponent' then sa.opponent_score > sa.team_score
        else sa.team_score > sa.opponent_score
      end as won
    from public.sessions wrapper
    join crew c on c.id = wrapper.user_id
    join public.sessions source on source.id = wrapper.reposted_from
    join public.session_activities sa on sa.session_id = source.id and sa.kind = 'match'
    join lateral (
      select min(ap.role) as role
      from public.activity_participants ap
      where ap.activity_id = sa.id
        and ap.profile_id = wrapper.user_id
      having count(*) = 1
    ) tag on true
    where wrapper.reposted_from is not null
      and source.reposted_from is null
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    coalesce(count(*) filter (where pm.won is true), 0)::int,
    coalesce(count(*) filter (where pm.won is false), 0)::int,
    coalesce(count(*) filter (where pm.won is not null), 0)::int
  from crew c
  join public.profiles p on p.id = c.id
  left join projected_matches pm on pm.player_id = p.id
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials;
$$;
revoke all on function repost_internal.crew_leaderboard_for(uuid) from public, anon;
grant execute on function repost_internal.crew_leaderboard_for(uuid) to authenticated;

create or replace function public.crew_leaderboard()
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  avatar_initials text,
  wins int,
  losses int,
  matches int
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from repost_internal.crew_leaderboard_for(auth.uid());
$$;
revoke all on function public.crew_leaderboard() from public, anon;
grant execute on function public.crew_leaderboard() to authenticated;

-- Existing approved reposts become canonical wrappers too. Their copied child
-- rows are the corrupted duplicate records this migration replaces.
delete from public.session_activities sa
using public.sessions wrapper
where sa.session_id = wrapper.id
  and wrapper.reposted_from is not null;

-- Apply the new block invariant to relationships that predate this migration.
delete from public.sessions child
using public.sessions source
where child.reposted_from = source.id
  and exists (
    select 1
    from public.blocks b
    where (b.blocker_id = child.user_id and b.blocked_id = source.user_id)
       or (b.blocker_id = source.user_id and b.blocked_id = child.user_id)
  );

-- A pending request already records the tagged player's intent. Fulfill it
-- under the new tag-as-consent rule when it still passes current checks.
do $$
declare
  pending_request public.repost_requests;
begin
  for pending_request in
    select rr.*
    from public.repost_requests rr
    join public.sessions s on s.id = rr.session_id
    where rr.status = 'pending'
      and s.reposted_from is null
      and s.posted
      and exists (
        select 1 from public.activity_participants ap
        where ap.session_id = rr.session_id
          and ap.profile_id = rr.requester_id
      )
  loop
    begin
      perform set_config('request.jwt.claim.sub', pending_request.requester_id::text, true);
      perform repost_internal.create_repost(
        pending_request.session_id,
        pending_request.requester_id
      );
    exception when others then
      raise warning 'Could not fulfill legacy repost request %: %',
        pending_request.id, sqlerrm;
    end;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

-- Remove in-app notifications produced by legacy copied participant rows.
delete from public.notifications n
using public.sessions s
where n.session_id = s.id
  and s.reposted_from is not null
  and n.type in ('tag', 'rivalry');

-- Retire the approval surface while keeping legacy rows readable for audit and
-- compatible with older account/block cleanup functions.
drop function if exists public.approve_repost(uuid);
drop policy if exists "repost_requests_insert" on public.repost_requests;
drop policy if exists "repost_requests_update" on public.repost_requests;
drop policy if exists "repost_requests_delete" on public.repost_requests;
revoke insert, update, delete on public.repost_requests from authenticated;
grant select on public.repost_requests to authenticated;

create or replace function public.remove_self_from_session(target_session_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  removed integer;
begin
  perform 1 from public.sessions s where s.id = target_session_id;
  if not found then raise exception 'Session not found'; end if;

  delete from public.activity_participants ap
  where ap.session_id = target_session_id
    and ap.profile_id = caller_id;
  get diagnostics removed = row_count;
  if removed = 0 then raise exception 'You are not tagged in this session'; end if;
  return removed;
end;
$$;
revoke all on function public.remove_self_from_session(uuid) from public, anon;
grant execute on function public.remove_self_from_session(uuid) to authenticated;
