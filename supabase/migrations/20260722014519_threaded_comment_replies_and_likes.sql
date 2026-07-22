-- One-level comment replies, per-comment likes, deletion placeholders, and
-- notification delivery. Existing rows remain top-level comments.

-- ---------------------------------------------------------------------------
-- Thread shape
-- ---------------------------------------------------------------------------

alter table public.comments
  add column if not exists parent_id uuid,
  add column if not exists deleted_at timestamptz;

alter table public.comments
  drop constraint if exists comments_parent_id_fkey;
alter table public.comments
  add constraint comments_parent_id_fkey
  foreign key (parent_id) references public.comments(id) on delete cascade;

alter table public.comments
  drop constraint if exists comments_parent_not_self_check;
alter table public.comments
  add constraint comments_parent_not_self_check
  check (parent_id is null or parent_id <> id);

create index if not exists comments_parent_created_idx
  on public.comments (parent_id, created_at)
  where parent_id is not null;

create or replace function private.validate_comment_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.comments;
begin
  if tg_op = 'INSERT' and new.deleted_at is not null then
    raise exception 'New comments cannot be deleted';
  end if;

  if new.parent_id is null then
    return new;
  end if;

  select * into target
  from public.comments c
  where c.id = new.parent_id;

  if target.id is null then
    raise exception 'Parent comment not found';
  end if;
  if target.session_id <> new.session_id then
    raise exception 'Reply must belong to the same session';
  end if;
  if target.parent_id is not null then
    raise exception 'Replies may only target top-level comments';
  end if;
  if target.deleted_at is not null then
    raise exception 'Cannot reply to a deleted comment';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_comment_thread() from public;

drop trigger if exists validate_comment_thread on public.comments;
create trigger validate_comment_thread
  before insert or update of parent_id, session_id on public.comments
  for each row execute function private.validate_comment_thread();

-- ---------------------------------------------------------------------------
-- Comment likes
-- ---------------------------------------------------------------------------

create table if not exists public.comment_likes (
  session_id uuid not null references public.sessions(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (session_id, comment_id, user_id),
  unique (comment_id, user_id)
);

create index if not exists comment_likes_user_comment_idx
  on public.comment_likes (user_id, comment_id);

create or replace function private.prepare_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_session uuid;
  target_deleted_at timestamptz;
begin
  select c.session_id, c.deleted_at
    into target_session, target_deleted_at
  from public.comments c
  where c.id = new.comment_id;

  if target_session is null then
    raise exception 'Comment not found';
  end if;
  if target_deleted_at is not null then
    raise exception 'Cannot like a deleted comment';
  end if;

  new.session_id := target_session;
  return new;
end;
$$;

revoke all on function private.prepare_comment_like() from public;

drop trigger if exists prepare_comment_like on public.comment_likes;
create trigger prepare_comment_like
  before insert or update of comment_id on public.comment_likes
  for each row execute function private.prepare_comment_like();

alter table public.comment_likes enable row level security;

drop policy if exists "comment_likes_read" on public.comment_likes;
drop policy if exists "comment_likes_insert" on public.comment_likes;
drop policy if exists "comment_likes_delete" on public.comment_likes;

create policy "comment_likes_read" on public.comment_likes
  for select to authenticated
  using (
    private.can_view_session((select auth.uid()), session_id)
    and not private.is_blocked_between((select auth.uid()), user_id)
  );

create policy "comment_likes_insert" on public.comment_likes
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and private.can_view_session((select auth.uid()), session_id)
    and exists (
      select 1
      from public.comments c
      where c.id = comment_likes.comment_id
        and c.session_id = comment_likes.session_id
        and c.deleted_at is null
        and not private.is_blocked_between((select auth.uid()), c.user_id)
    )
  );

create policy "comment_likes_delete" on public.comment_likes
  for delete to authenticated
  using (
    user_id = (select auth.uid())
    and private.is_active_user((select auth.uid()))
  );

revoke all on public.comment_likes from anon, authenticated;
grant select, delete on public.comment_likes to authenticated;
grant insert (comment_id, user_id) on public.comment_likes to authenticated;

-- Publish new likes so open comment threads can update their reaction counts.
-- DELETE events are intentionally not consumed by clients because Supabase
-- cannot apply RLS policies or filters to Postgres Changes DELETE events.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'comment_likes'
  ) then
    alter publication supabase_realtime add table public.comment_likes;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Preserve reply threads when their top-level comment is deleted
-- ---------------------------------------------------------------------------

create or replace function private.preserve_deleted_comment_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Let FK cascades from session/account deletion remain true hard deletes.
  if pg_trigger_depth() > 1 or auth.uid() is null then
    return old;
  end if;

  if old.parent_id is null and exists (
    select 1
    from public.comments reply
    where reply.parent_id = old.id
      and reply.deleted_at is null
  ) then
    delete from public.comment_likes where comment_id = old.id;
    delete from public.notifications where comment_id = old.id;
    update public.comments
    set body = '', deleted_at = coalesce(deleted_at, now())
    where id = old.id;
    return null;
  end if;

  return old;
end;
$$;

revoke all on function private.preserve_deleted_comment_thread() from public;

drop trigger if exists preserve_deleted_comment_thread on public.comments;
create trigger preserve_deleted_comment_thread
  before delete on public.comments
  for each row execute function private.preserve_deleted_comment_thread();

-- A placeholder only earns its keep while it still has replies to anchor. Once
-- the last one goes, drop it so tombstones don't accumulate. The inner delete
-- re-enters preserve_deleted_comment_thread at depth > 1, which lets it through
-- as a real hard delete.
create or replace function private.reap_orphaned_comment_placeholder()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.parent_id is null then
    return old;
  end if;

  delete from public.comments c
  where c.id = old.parent_id
    and c.deleted_at is not null
    and not exists (
      select 1 from public.comments reply where reply.parent_id = c.id
    );

  return old;
end;
$$;

revoke all on function private.reap_orphaned_comment_placeholder() from public;

drop trigger if exists reap_orphaned_comment_placeholder on public.comments;
create trigger reap_orphaned_comment_placeholder
  after delete on public.comments
  for each row execute function private.reap_orphaned_comment_placeholder();

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention'));

drop trigger if exists on_comment_created on public.comments;
drop function if exists public.notify_on_comment();

create or replace function private.notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_author uuid;
  parent_author uuid;
begin
  select s.user_id into session_author
  from public.sessions s
  where s.id = new.session_id;

  if session_author is not null and session_author <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
    values (session_author, new.user_id, 'comment', new.session_id, new.id);
  end if;

  if new.parent_id is not null then
    select c.user_id into parent_author
    from public.comments c
    where c.id = new.parent_id;

    if parent_author is not null
       and parent_author <> new.user_id
       and parent_author is distinct from session_author then
      insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
      values (parent_author, new.user_id, 'comment_reply', new.session_id, new.id);
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.notify_on_comment() from public;

create trigger on_comment_created
  after insert on public.comments
  for each row execute function private.notify_on_comment();

drop trigger if exists on_comment_mentions on public.comments;
drop function if exists public.notify_on_comment_mentions();

create or replace function private.notify_on_comment_mentions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_author uuid;
  parent_author uuid;
  handle text;
  mentioned uuid;
begin
  select s.user_id into session_author
  from public.sessions s
  where s.id = new.session_id;

  if new.parent_id is not null then
    select c.user_id into parent_author
    from public.comments c
    where c.id = new.parent_id;
  end if;

  for handle in
    select distinct lower(m[1])
    from regexp_matches(new.body, '@([a-z0-9_.]+)', 'gi') as m
  loop
    select p.id into mentioned
    from public.profiles p
    where lower(p.username) = handle;

    if mentioned is not null
       and mentioned <> new.user_id
       and mentioned is distinct from session_author
       and mentioned is distinct from parent_author then
      insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
      values (mentioned, new.user_id, 'mention', new.session_id, new.id);
    end if;
  end loop;

  return new;
end;
$$;

revoke all on function private.notify_on_comment_mentions() from public;

create trigger on_comment_mentions
  after insert on public.comments
  for each row execute function private.notify_on_comment_mentions();

create or replace function private.notify_on_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  comment_author uuid;
begin
  select c.user_id into comment_author
  from public.comments c
  where c.id = new.comment_id and c.deleted_at is null;

  if comment_author is not null and comment_author <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
    values (comment_author, new.user_id, 'comment_like', new.session_id, new.comment_id);
  end if;

  return new;
end;
$$;

revoke all on function private.notify_on_comment_like() from public;

drop trigger if exists on_comment_like_created on public.comment_likes;
create trigger on_comment_like_created
  after insert on public.comment_likes
  for each row execute function private.notify_on_comment_like();
