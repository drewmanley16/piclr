-- Activity notifications populated by DB triggers. Recipients read/mark/delete
-- their own; rows are only ever created by the SECURITY DEFINER triggers below.

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,   -- recipient
  actor_id   uuid references public.profiles(id) on delete cascade,            -- who acted
  type       text not null check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved')),
  session_id uuid references public.sessions(id) on delete cascade,
  comment_id uuid references public.comments(id) on delete cascade,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;
drop policy if exists "notifications_read"   on public.notifications;
drop policy if exists "notifications_update" on public.notifications;
drop policy if exists "notifications_delete" on public.notifications;
create policy "notifications_read"   on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "notifications_update" on public.notifications for update to authenticated using (user_id = auth.uid());
create policy "notifications_delete" on public.notifications for delete to authenticated using (user_id = auth.uid());

-- Like on your session
create or replace function public.notify_on_like()
returns trigger language plpgsql security definer set search_path = public as $$
declare author uuid;
begin
  select user_id into author from public.sessions where id = new.session_id;
  if author is not null and author <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, session_id)
    values (author, new.user_id, 'like', new.session_id);
  end if;
  return new;
end; $$;
drop trigger if exists on_like_created on public.likes;
create trigger on_like_created after insert on public.likes
  for each row execute function public.notify_on_like();

-- Comment on your session
create or replace function public.notify_on_comment()
returns trigger language plpgsql security definer set search_path = public as $$
declare author uuid;
begin
  select user_id into author from public.sessions where id = new.session_id;
  if author is not null and author <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
    values (author, new.user_id, 'comment', new.session_id, new.id);
  end if;
  return new;
end; $$;
drop trigger if exists on_comment_created on public.comments;
create trigger on_comment_created after insert on public.comments
  for each row execute function public.notify_on_comment();

-- New follower (a follow becomes accepted)
create or replace function public.notify_on_follow()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'accepted'
     and (tg_op = 'INSERT' or old.status is distinct from 'accepted')
     and new.followee_id <> new.follower_id then
    insert into public.notifications (user_id, actor_id, type)
    values (new.followee_id, new.follower_id, 'follow');
  end if;
  return new;
end; $$;
drop trigger if exists on_follow_accepted on public.follows;
create trigger on_follow_accepted after insert or update on public.follows
  for each row execute function public.notify_on_follow();

-- Tagged as a participant in someone's match
create or replace function public.notify_on_tag()
returns trigger language plpgsql security definer set search_path = public as $$
declare author uuid;
begin
  if new.profile_id is not null then
    select user_id into author from public.sessions where id = new.session_id;
    if author is not null and author <> new.profile_id then
      insert into public.notifications (user_id, actor_id, type, session_id)
      values (new.profile_id, author, 'tag', new.session_id);
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists on_tag_created on public.activity_participants;
create trigger on_tag_created after insert on public.activity_participants
  for each row execute function public.notify_on_tag();

-- Realtime so the bell badge updates live
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
