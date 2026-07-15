-- User control and safety: blocking, reporting, moderation, full session edits,
-- participant self-removal, hard-delete-safe relationships, and private media.

-- ---------------------------------------------------------------------------
-- Safety tables and deletion-safe relationships
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists avatar_path text;
alter table public.sessions add column if not exists photo_path text;

update public.profiles
set avatar_path = regexp_replace(avatar_url, '^.*/avatars/', '')
where avatar_path is null and avatar_url like '%/avatars/%';

update public.sessions
set photo_path = regexp_replace(photo_url, '^.*/post-photos/', '')
where photo_path is null and photo_url like '%/post-photos/%';

-- SET NULL conflicts with the participant row's "member or guest" check and
-- can prevent account deletion. Removing the deleted member's tag is the
-- privacy-preserving behavior for a hard delete.
alter table public.activity_participants
  drop constraint if exists activity_participants_profile_id_fkey;
alter table public.activity_participants
  add constraint activity_participants_profile_id_fkey
  foreign key (profile_id) references public.profiles(id) on delete cascade;

-- Reposts are full copies of the original session. Cascade through the
-- self-reference so deleting a session or account also removes every copy.
alter table public.sessions
  drop constraint if exists sessions_reposted_from_fkey;
alter table public.sessions
  add constraint sessions_reposted_from_fkey
  foreign key (reposted_from) references public.sessions(id) on delete cascade;

-- Support common session lookups and keep account/session cascades from
-- scanning entire social tables as data grows.
create index if not exists comments_session_created_idx
  on public.comments (session_id, created_at);
create index if not exists comments_user_idx
  on public.comments (user_id);
create index if not exists likes_session_idx
  on public.likes (session_id);
create index if not exists sessions_reposted_from_idx
  on public.sessions (reposted_from) where reposted_from is not null;
create index if not exists notifications_actor_idx
  on public.notifications (actor_id) where actor_id is not null;
create index if not exists notifications_comment_idx
  on public.notifications (comment_id) where comment_id is not null;
create index if not exists notifications_session_idx
  on public.notifications (session_id) where session_id is not null;

create table if not exists public.blocks (
  blocker_id           uuid not null references public.profiles(id) on delete cascade,
  blocked_id           uuid not null references public.profiles(id) on delete cascade,
  blocked_username     text not null,
  blocked_display_name text not null,
  blocked_avatar_path  text,
  created_at           timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists blocks_blocked_blocker_idx
  on public.blocks (blocked_id, blocker_id);

create table if not exists public.reports (
  id              uuid primary key default gen_random_uuid(),
  reporter_id     uuid not null references public.profiles(id) on delete cascade,
  subject_user_id uuid not null references public.profiles(id) on delete cascade,
  target_type     text not null check (target_type in ('user', 'session', 'comment')),
  target_id       uuid not null,
  reason          text not null check (
    reason in ('harassment', 'spam', 'impersonation', 'inappropriate', 'cheating', 'other')
  ),
  details         text check (details is null or char_length(details) <= 1000),
  snapshot        jsonb not null default '{}'::jsonb,
  status          text not null default 'open' check (
    status in ('open', 'reviewing', 'actioned', 'dismissed')
  ),
  created_at      timestamptz not null default now()
);
create index if not exists reports_status_created_idx
  on public.reports (status, created_at desc);
create index if not exists reports_subject_created_idx
  on public.reports (subject_user_id, created_at desc);
create unique index if not exists reports_one_active_target_idx
  on public.reports (reporter_id, target_type, target_id)
  where status in ('open', 'reviewing');

alter table public.blocks enable row level security;
alter table public.reports enable row level security;

-- ---------------------------------------------------------------------------
-- Private authorization helpers. These bypass RLS only to answer narrowly
-- scoped authorization questions and are not exposed through the Data API.
-- ---------------------------------------------------------------------------

create or replace function private.is_active_user(candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select candidate_id is not null and exists (
    select 1 from public.profiles p where p.id = candidate_id
  );
$$;

create or replace function private.is_blocked_between(first_id uuid, second_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select first_id is not null
    and second_id is not null
    and first_id <> second_id
    and exists (
      select 1
      from public.blocks b
      where (b.blocker_id = first_id and b.blocked_id = second_id)
         or (b.blocker_id = second_id and b.blocked_id = first_id)
    );
$$;

create or replace function private.can_view_profile(viewer_id uuid, profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_user(viewer_id)
    and exists (
      select 1
      from public.profiles p
      where p.id = profile_id
        and (p.id = viewer_id or p.onboarding_completed_at is not null)
    )
    and not private.is_blocked_between(viewer_id, profile_id);
$$;

create or replace function private.can_view_session(viewer_id uuid, target_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_user(viewer_id)
    and exists (
      select 1
      from public.sessions s
      where s.id = target_session_id
        and not private.is_blocked_between(viewer_id, s.user_id)
        and (
          s.user_id = viewer_id
          -- Posted sessions are globally discoverable. The block check above
          -- still removes them from both sides of a blocked relationship.
          or s.posted = true
          or exists (
            select 1 from public.activity_participants ap
            where ap.session_id = s.id and ap.profile_id = viewer_id
          )
        )
    );
$$;

create or replace function private.can_read_media(
  viewer_id uuid,
  bucket_name text,
  object_name text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uuid_pattern constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  owner_text text := split_part(object_name, '/', 1);
  target_text text;
  owner_id uuid;
  target_session_id uuid;
begin
  if viewer_id is null or owner_text !~ uuid_pattern then return false; end if;
  owner_id := owner_text::uuid;

  if bucket_name = 'avatars' then
    return private.can_view_profile(viewer_id, owner_id);
  end if;

  if bucket_name = 'post-photos' then
    target_text := split_part(split_part(object_name, '/', 2), '.', 1);
    if target_text !~ uuid_pattern then return false; end if;
    target_session_id := target_text::uuid;
    return private.can_view_session(viewer_id, target_session_id)
      and exists (
        select 1 from public.sessions s
        where s.id = target_session_id and s.user_id = owner_id
      );
  end if;

  return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block and report integrity triggers
-- ---------------------------------------------------------------------------

create or replace function private.prepare_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  blocked_profile public.profiles;
begin
  if new.blocker_id is distinct from auth.uid() then
    raise exception 'You can only create your own block';
  end if;
  if new.blocker_id = new.blocked_id then
    raise exception 'You cannot block yourself';
  end if;

  select * into blocked_profile
  from public.profiles p
  where p.id = new.blocked_id and p.onboarding_completed_at is not null;
  if blocked_profile.id is null then raise exception 'Player not found'; end if;

  new.blocked_username := blocked_profile.username;
  new.blocked_display_name := blocked_profile.display_name;
  new.blocked_avatar_path := blocked_profile.avatar_path;
  return new;
end;
$$;

create or replace function private.cleanup_blocked_relationships()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.follows f
  where (f.follower_id = new.blocker_id and f.followee_id = new.blocked_id)
     or (f.follower_id = new.blocked_id and f.followee_id = new.blocker_id);

  delete from public.friend_requests fr
  where (fr.requester_id = new.blocker_id and fr.addressee_id = new.blocked_id)
     or (fr.requester_id = new.blocked_id and fr.addressee_id = new.blocker_id);

  delete from public.repost_requests rr
  using public.sessions s
  where rr.session_id = s.id
    and (
      (rr.requester_id = new.blocker_id and s.user_id = new.blocked_id)
      or (rr.requester_id = new.blocked_id and s.user_id = new.blocker_id)
    );

  delete from public.notifications n
  where (n.user_id = new.blocker_id and n.actor_id = new.blocked_id)
     or (n.user_id = new.blocked_id and n.actor_id = new.blocker_id);

  return new;
end;
$$;

drop trigger if exists prepare_block on public.blocks;
create trigger prepare_block
  before insert on public.blocks
  for each row execute function private.prepare_block();

drop trigger if exists cleanup_blocked_relationships on public.blocks;
create trigger cleanup_blocked_relationships
  after insert on public.blocks
  for each row execute function private.cleanup_blocked_relationships();

create or replace function private.prepare_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_profile public.profiles;
  target_session public.sessions;
  target_comment public.comments;
begin
  if new.reporter_id is distinct from auth.uid() then
    raise exception 'You can only submit your own report';
  end if;

  new.details := nullif(btrim(new.details), '');

  case new.target_type
    when 'user' then
      select * into target_profile from public.profiles p where p.id = new.target_id;
      if target_profile.id is null
         or not private.can_view_profile(new.reporter_id, target_profile.id) then
        raise exception 'Player not found';
      end if;
      new.subject_user_id := target_profile.id;
      new.snapshot := jsonb_build_object(
        'username', target_profile.username,
        'display_name', target_profile.display_name
      );

    when 'session' then
      select * into target_session from public.sessions s where s.id = new.target_id;
      if target_session.id is null
         or not private.can_view_session(new.reporter_id, target_session.id) then
        raise exception 'Session not found';
      end if;
      new.subject_user_id := target_session.user_id;
      new.snapshot := jsonb_build_object(
        'session_id', target_session.id,
        'title', target_session.title,
        'created_at', target_session.created_at
      );

    when 'comment' then
      select * into target_comment from public.comments c where c.id = new.target_id;
      if target_comment.id is null
         or not private.can_view_session(new.reporter_id, target_comment.session_id) then
        raise exception 'Comment not found';
      end if;
      new.subject_user_id := target_comment.user_id;
      new.snapshot := jsonb_build_object(
        'comment_id', target_comment.id,
        'session_id', target_comment.session_id,
        'body', target_comment.body,
        'created_at', target_comment.created_at
      );

    else
      raise exception 'Unsupported report target';
  end case;

  if new.subject_user_id = new.reporter_id then
    raise exception 'You cannot report your own content';
  end if;
  return new;
end;
$$;

drop trigger if exists prepare_report on public.reports;
create trigger prepare_report
  before insert on public.reports
  for each row execute function private.prepare_report();

-- ---------------------------------------------------------------------------
-- Block-aware RLS and moderation permissions
-- ---------------------------------------------------------------------------

drop policy if exists "blocks_read" on public.blocks;
drop policy if exists "blocks_insert" on public.blocks;
drop policy if exists "blocks_delete" on public.blocks;
create policy "blocks_read" on public.blocks
  for select to authenticated
  using (blocker_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "blocks_insert" on public.blocks
  for insert to authenticated
  with check (
    blocker_id = (select auth.uid())
    and private.is_active_user((select auth.uid()))
    and private.can_view_profile((select auth.uid()), blocked_id)
  );
create policy "blocks_delete" on public.blocks
  for delete to authenticated
  using (blocker_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "reports_read_own" on public.reports;
drop policy if exists "reports_insert_own" on public.reports;
create policy "reports_read_own" on public.reports
  for select to authenticated
  using (reporter_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "reports_insert_own" on public.reports
  for insert to authenticated
  with check (reporter_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "profiles_read" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_read" on public.profiles
  for select to authenticated
  using (private.can_view_profile((select auth.uid()), id));
create policy "profiles_update" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) and private.is_active_user((select auth.uid())))
  with check (id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "sessions_read" on public.sessions;
drop policy if exists "sessions_insert" on public.sessions;
drop policy if exists "sessions_update" on public.sessions;
drop policy if exists "sessions_delete" on public.sessions;
create policy "sessions_read" on public.sessions
  for select to authenticated
  using (private.can_view_session((select auth.uid()), id));
create policy "sessions_insert" on public.sessions
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "sessions_update" on public.sessions
  for update to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
  with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy "sessions_delete" on public.sessions
  for delete to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "likes_read" on public.likes;
drop policy if exists "likes_insert" on public.likes;
drop policy if exists "likes_delete" on public.likes;
create policy "likes_read" on public.likes
  for select to authenticated
  using (
    private.can_view_session((select auth.uid()), session_id)
    and not private.is_blocked_between((select auth.uid()), user_id)
  );
create policy "likes_insert" on public.likes
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and private.can_view_session((select auth.uid()), session_id)
  );
create policy "likes_delete" on public.likes
  for delete to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "comments_read" on public.comments;
drop policy if exists "comments_insert" on public.comments;
drop policy if exists "comments_delete" on public.comments;
create policy "comments_read" on public.comments
  for select to authenticated
  using (
    private.can_view_session((select auth.uid()), session_id)
    and not private.is_blocked_between((select auth.uid()), user_id)
  );
create policy "comments_insert" on public.comments
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and private.can_view_session((select auth.uid()), session_id)
  );
create policy "comments_delete" on public.comments
  for delete to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and (
      user_id = (select auth.uid())
      or exists (
        select 1 from public.sessions s
        where s.id = comments.session_id and s.user_id = (select auth.uid())
      )
    )
  );

drop policy if exists "gear_read" on public.gear;
create policy "gear_read" on public.gear
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and not private.is_blocked_between((select auth.uid()), user_id)
  );

drop policy if exists "follows_read" on public.follows;
drop policy if exists "follows_insert" on public.follows;
drop policy if exists "follows_update" on public.follows;
drop policy if exists "follows_delete" on public.follows;
create policy "follows_read" on public.follows
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and not private.is_blocked_between((select auth.uid()), follower_id)
    and not private.is_blocked_between((select auth.uid()), followee_id)
  );
create policy "follows_insert" on public.follows
  for insert to authenticated
  with check (
    follower_id = (select auth.uid())
    and status = 'pending'
    and private.is_active_user((select auth.uid()))
    and not private.is_blocked_between(follower_id, followee_id)
  );
create policy "follows_update" on public.follows
  for update to authenticated
  using (
    followee_id = (select auth.uid())
    and private.is_active_user((select auth.uid()))
    and not private.is_blocked_between(follower_id, followee_id)
  )
  with check (
    followee_id = (select auth.uid())
    and status in ('accepted', 'rejected')
    and not private.is_blocked_between(follower_id, followee_id)
  );
create policy "follows_delete" on public.follows
  for delete to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and (follower_id = (select auth.uid()) or followee_id = (select auth.uid()))
  );

-- The app no longer writes the legacy mutual friend graph, but keep it from
-- becoming a block bypass for direct Data API callers.
drop policy if exists "friend_requests_read" on public.friend_requests;
drop policy if exists "friend_requests_insert" on public.friend_requests;
drop policy if exists "friend_requests_update" on public.friend_requests;
drop policy if exists "friend_requests_delete" on public.friend_requests;
create policy "friend_requests_read" on public.friend_requests
  for select to authenticated
  using (
    (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()))
    and not private.is_blocked_between(requester_id, addressee_id)
  );
create policy "friend_requests_insert" on public.friend_requests
  for insert to authenticated
  with check (
    requester_id = (select auth.uid())
    and requester_id <> addressee_id
    and status = 'pending'
    and private.is_active_user((select auth.uid()))
    and not private.is_blocked_between(requester_id, addressee_id)
  );
create policy "friend_requests_update" on public.friend_requests
  for update to authenticated
  using (
    addressee_id = (select auth.uid())
    and status = 'pending'
    and not private.is_blocked_between(requester_id, addressee_id)
  )
  with check (
    addressee_id = (select auth.uid())
    and status in ('accepted', 'declined')
    and not private.is_blocked_between(requester_id, addressee_id)
  );
create policy "friend_requests_delete" on public.friend_requests
  for delete to authenticated
  using (requester_id = (select auth.uid()) and status = 'pending');

drop policy if exists "session_activities_read" on public.session_activities;
drop policy if exists "session_activities_write" on public.session_activities;
create policy "session_activities_read" on public.session_activities
  for select to authenticated
  using (private.can_view_session((select auth.uid()), session_id));
create policy "session_activities_write" on public.session_activities
  for all to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and exists (
      select 1 from public.sessions s
      where s.id = session_activities.session_id and s.user_id = (select auth.uid())
    )
  )
  with check (
    private.is_active_user((select auth.uid()))
    and exists (
      select 1 from public.sessions s
      where s.id = session_activities.session_id and s.user_id = (select auth.uid())
    )
  );

drop policy if exists "activity_participants_read" on public.activity_participants;
drop policy if exists "activity_participants_write" on public.activity_participants;
drop policy if exists "activity_participants_owner_insert" on public.activity_participants;
drop policy if exists "activity_participants_owner_update" on public.activity_participants;
drop policy if exists "activity_participants_owner_delete" on public.activity_participants;
drop policy if exists "activity_participants_self_delete" on public.activity_participants;
create policy "activity_participants_read" on public.activity_participants
  for select to authenticated
  using (
    private.can_view_session((select auth.uid()), session_id)
    and (profile_id is null or not private.is_blocked_between((select auth.uid()), profile_id))
  );
create policy "activity_participants_owner_insert" on public.activity_participants
  for insert to authenticated
  with check (
    private.is_active_user((select auth.uid()))
    and (profile_id is null or not private.is_blocked_between((select auth.uid()), profile_id))
    and exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id and s.user_id = (select auth.uid())
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
    where s.id = activity_participants.session_id and s.user_id = (select auth.uid())
  ))
  with check (
    (profile_id is null or not private.is_blocked_between((select auth.uid()), profile_id))
    and exists (
      select 1 from public.sessions s
      where s.id = activity_participants.session_id and s.user_id = (select auth.uid())
    )
  );
create policy "activity_participants_owner_delete" on public.activity_participants
  for delete to authenticated
  using (exists (
    select 1 from public.sessions s
    where s.id = activity_participants.session_id and s.user_id = (select auth.uid())
  ));
create policy "activity_participants_self_delete" on public.activity_participants
  for delete to authenticated
  using (profile_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

drop policy if exists "repost_requests_read" on public.repost_requests;
drop policy if exists "repost_requests_insert" on public.repost_requests;
drop policy if exists "repost_requests_update" on public.repost_requests;
drop policy if exists "repost_requests_delete" on public.repost_requests;
create policy "repost_requests_read" on public.repost_requests
  for select to authenticated
  using (
    not private.is_blocked_between((select auth.uid()), requester_id)
    and (
      requester_id = (select auth.uid())
      or exists (
        select 1 from public.sessions s
        where s.id = repost_requests.session_id and s.user_id = (select auth.uid())
      )
    )
  );
create policy "repost_requests_insert" on public.repost_requests
  for insert to authenticated
  with check (
    requester_id = (select auth.uid())
    and status = 'pending'
    and private.can_view_session((select auth.uid()), session_id)
    and exists (
      select 1 from public.activity_participants ap
      where ap.session_id = repost_requests.session_id and ap.profile_id = (select auth.uid())
    )
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id <> (select auth.uid())
    )
  );
create policy "repost_requests_update" on public.repost_requests
  for update to authenticated
  using (
    status = 'pending'
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id = (select auth.uid())
    )
  )
  with check (
    status = 'declined'
    and exists (
      select 1 from public.sessions s
      where s.id = repost_requests.session_id and s.user_id = (select auth.uid())
    )
  );
create policy "repost_requests_delete" on public.repost_requests
  for delete to authenticated
  using (requester_id = (select auth.uid()) and status = 'pending');

do $$
begin
  if to_regclass('public.notifications') is not null then
    drop policy if exists "notifications_read" on public.notifications;
    drop policy if exists "notifications_update" on public.notifications;
    drop policy if exists "notifications_delete" on public.notifications;
    create policy "notifications_read" on public.notifications
      for select to authenticated
      using (
        user_id = (select auth.uid())
        and private.is_active_user((select auth.uid()))
        and (actor_id is null or not private.is_blocked_between((select auth.uid()), actor_id))
      );
    create policy "notifications_update" on public.notifications
      for update to authenticated
      using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
      with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
    create policy "notifications_delete" on public.notifications
      for delete to authenticated
      using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Atomic full-session update and tagged-player self-removal
-- ---------------------------------------------------------------------------

create or replace function public.update_own_session(
  target_session_id uuid,
  payload jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  activity jsonb;
  participant jsonb;
  current_activity_id uuid;
  current_participant_id uuid;
  current_participant_profile_id uuid;
  participant_ids uuid[];
  activity_ids uuid[] := array[]::uuid[];
  affected integer;
  first_focus text;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(payload->'activities') is distinct from 'array'
     or jsonb_array_length(payload->'activities') = 0 then
    raise exception 'A session must contain at least one activity';
  end if;

  perform 1 from public.sessions s
  where s.id = target_session_id and s.user_id = caller_id
  for update;
  if not found then raise exception 'Session not found'; end if;

  select nullif(item->>'focus', '') into first_focus
  from jsonb_array_elements(payload->'activities') item
  where item->>'kind' = 'practice' and nullif(item->>'focus', '') is not null
  order by coalesce((item->>'position')::integer, 0)
  limit 1;

  update public.sessions
  set title = nullif(btrim(payload->>'title'), ''),
      location = nullif(btrim(payload->>'location'), ''),
      duration_minutes = greatest(1, (payload->>'duration_minutes')::integer),
      focus = first_focus,
      takeaway = nullif(btrim(payload->>'takeaway'), ''),
      posted = coalesce((payload->>'posted')::boolean, posted),
      started_at = (payload->>'started_at')::timestamptz,
      ended_at = (payload->>'ended_at')::timestamptz,
      photo_path = case
        when payload ? 'photo_path' then nullif(payload->>'photo_path', '')
        else photo_path
      end
  where id = target_session_id and user_id = caller_id;

  for activity in select value from jsonb_array_elements(payload->'activities')
  loop
    current_activity_id := (activity->>'id')::uuid;
    activity_ids := array_append(activity_ids, current_activity_id);

    insert into public.session_activities (
      id, session_id, kind, position, focus, reps, notes,
      team_score, opponent_score, won
    ) values (
      current_activity_id,
      target_session_id,
      activity->>'kind',
      coalesce((activity->>'position')::integer, 0),
      nullif(activity->>'focus', ''),
      nullif(activity->>'reps', ''),
      nullif(activity->>'notes', ''),
      nullif(activity->>'team_score', '')::integer,
      nullif(activity->>'opponent_score', '')::integer,
      nullif(activity->>'won', '')::boolean
    )
    on conflict (id) do update set
      kind = excluded.kind,
      position = excluded.position,
      focus = excluded.focus,
      reps = excluded.reps,
      notes = excluded.notes,
      team_score = excluded.team_score,
      opponent_score = excluded.opponent_score,
      won = excluded.won
    where public.session_activities.session_id = target_session_id;
    get diagnostics affected = row_count;
    if affected <> 1 then raise exception 'Invalid activity identifier'; end if;

    participant_ids := array[]::uuid[];
    for participant in
      select value from jsonb_array_elements(coalesce(activity->'participants', '[]'::jsonb))
    loop
      current_participant_id := (participant->>'id')::uuid;
      current_participant_profile_id := nullif(participant->>'profile_id', '')::uuid;
      participant_ids := array_append(participant_ids, current_participant_id);

      if current_participant_profile_id is not null and not exists (
        select 1 from public.profiles p
        where p.id = current_participant_profile_id and p.onboarding_completed_at is not null
      ) then
        raise exception 'Tagged player not found';
      end if;

      insert into public.activity_participants (
        id, activity_id, session_id, profile_id, guest_name, role
      ) values (
        current_participant_id,
        current_activity_id,
        target_session_id,
        current_participant_profile_id,
        case when current_participant_profile_id is null then nullif(btrim(participant->>'guest_name'), '') end,
        participant->>'role'
      )
      on conflict (id) do update set
        activity_id = excluded.activity_id,
        profile_id = excluded.profile_id,
        guest_name = excluded.guest_name,
        role = excluded.role
      where public.activity_participants.session_id = target_session_id;
      get diagnostics affected = row_count;
      if affected <> 1 then raise exception 'Invalid participant identifier'; end if;
    end loop;

    delete from public.activity_participants ap
    where ap.session_id = target_session_id
      and ap.activity_id = current_activity_id
      and not (ap.id = any(participant_ids));
  end loop;

  delete from public.session_activities a
  where a.session_id = target_session_id
    and not (a.id = any(activity_ids));
end;
$$;

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
  if not found then
    raise exception 'Session not found';
  end if;

  delete from public.repost_requests rr
  where rr.session_id = target_session_id
    and rr.requester_id = caller_id
    and rr.status = 'pending';

  delete from public.activity_participants ap
  where ap.session_id = target_session_id and ap.profile_id = caller_id;
  get diagnostics removed = row_count;
  if removed = 0 then raise exception 'You are not tagged in this session'; end if;
  return removed;
end;
$$;

revoke all on function public.update_own_session(uuid, jsonb) from public, anon;
revoke all on function public.remove_self_from_session(uuid) from public, anon;
grant execute on function public.update_own_session(uuid, jsonb) to authenticated;
grant execute on function public.remove_self_from_session(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Private media. Signed URLs are created only after these SELECT policies pass.
-- Existing public URLs are retained only for migration/backfill purposes.
-- ---------------------------------------------------------------------------

update storage.buckets set public = false where id in ('avatars', 'post-photos');

drop policy if exists "avatars_read" on storage.objects;
create policy "avatars_read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and private.can_read_media((select auth.uid()), bucket_id, name)
  );

drop policy if exists "post_photos_read" on storage.objects;
create policy "post_photos_read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'post-photos'
    and private.can_read_media((select auth.uid()), bucket_id, name)
  );

-- ---------------------------------------------------------------------------
-- Data API grants
-- ---------------------------------------------------------------------------

grant select, delete on public.blocks to authenticated;
grant insert (blocker_id, blocked_id) on public.blocks to authenticated;
grant select on public.reports to authenticated;
grant insert (reporter_id, target_type, target_id, reason, details)
  on public.reports to authenticated;
grant delete on public.repost_requests to authenticated;
grant update (photo_path) on public.sessions to authenticated;
grant update (avatar_path) on public.profiles to authenticated;
