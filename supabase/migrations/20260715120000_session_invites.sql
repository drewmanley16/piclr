-- Session invites: tag mutual-follower friends to a court + date/time, they
-- RSVP yes/no/maybe. Notifications fire on invite-received and on every RSVP
-- change. Courts are a minimal crowdsourced registry (id/name/lat/lng) found
-- via on-device MapKit search and deduplicated client-side by proximity —
-- see findOrCreateCourt in AppStore.

create table if not exists public.courts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  latitude   numeric not null,
  longitude  numeric not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists courts_lat_lng_idx on public.courts (latitude, longitude);

create table if not exists public.session_invites (
  id           uuid primary key default gen_random_uuid(),
  host_id      uuid not null references public.profiles(id) on delete cascade,
  court_id     uuid not null references public.courts(id) on delete cascade,
  scheduled_at timestamptz not null,
  note         text check (note is null or char_length(note) <= 280),
  created_at   timestamptz not null default now()
);
create index if not exists session_invites_host_idx on public.session_invites (host_id);
create index if not exists session_invites_scheduled_idx on public.session_invites (scheduled_at);

create table if not exists public.invite_recipients (
  id           uuid primary key default gen_random_uuid(),
  invite_id    uuid not null references public.session_invites(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'yes', 'no', 'maybe')),
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (invite_id, user_id)
);
create index if not exists invite_recipients_invite_idx on public.invite_recipients (invite_id);
create index if not exists invite_recipients_user_idx on public.invite_recipients (user_id);

alter table public.courts enable row level security;
alter table public.session_invites enable row level security;
alter table public.invite_recipients enable row level security;

-- ---------------------------------------------------------------------------
-- Authorization helpers
-- ---------------------------------------------------------------------------

-- Mutual follow: both directions must be an accepted `follows` edge.
create or replace function private.is_mutual_follow(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.follows f1
    where f1.follower_id = a and f1.followee_id = b and f1.status = 'accepted'
  ) and exists (
    select 1 from public.follows f2
    where f2.follower_id = b and f2.followee_id = a and f2.status = 'accepted'
  );
$$;

create or replace function private.can_view_invite(viewer_id uuid, target_invite_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_user(viewer_id)
    and exists (
      select 1
      from public.session_invites si
      where si.id = target_invite_id
        and (
          si.host_id = viewer_id
          or exists (
            select 1 from public.invite_recipients r
            where r.invite_id = si.id and r.user_id = viewer_id
          )
        )
    );
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

drop policy if exists "courts_read" on public.courts;
drop policy if exists "courts_insert" on public.courts;
create policy "courts_read" on public.courts
  for select to authenticated
  using (private.is_active_user((select auth.uid())));
create policy "courts_insert" on public.courts
  for insert to authenticated
  with check (
    private.is_active_user((select auth.uid()))
    and created_by = (select auth.uid())
  );

drop policy if exists "session_invites_read" on public.session_invites;
drop policy if exists "session_invites_insert" on public.session_invites;
create policy "session_invites_read" on public.session_invites
  for select to authenticated
  using (private.can_view_invite((select auth.uid()), id));
create policy "session_invites_insert" on public.session_invites
  for insert to authenticated
  with check (
    host_id = (select auth.uid())
    and private.is_active_user((select auth.uid()))
  );

drop policy if exists "invite_recipients_read" on public.invite_recipients;
drop policy if exists "invite_recipients_insert" on public.invite_recipients;
drop policy if exists "invite_recipients_update" on public.invite_recipients;
create policy "invite_recipients_read" on public.invite_recipients
  for select to authenticated
  using (private.can_view_invite((select auth.uid()), invite_id));
create policy "invite_recipients_insert" on public.invite_recipients
  for insert to authenticated
  with check (
    private.is_active_user((select auth.uid()))
    and private.is_mutual_follow((select auth.uid()), user_id)
    and exists (
      select 1 from public.session_invites si
      where si.id = invite_id and si.host_id = (select auth.uid())
    )
  );
create policy "invite_recipients_update" on public.invite_recipients
  for update to authenticated
  using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Notifications integration
-- ---------------------------------------------------------------------------

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved', 'invite_received', 'invite_response'));
alter table public.notifications add column if not exists invite_id uuid references public.session_invites(id) on delete cascade;
create index if not exists notifications_invite_idx
  on public.notifications (invite_id) where invite_id is not null;

-- Notify a tagged friend that they've been invited.
create or replace function public.notify_on_invite_recipient()
returns trigger language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  select host_id into host from public.session_invites where id = new.invite_id;
  if host is not null and host <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, invite_id)
    values (new.user_id, host, 'invite_received', new.invite_id);
  end if;
  return new;
end; $$;
drop trigger if exists on_invite_recipient_created on public.invite_recipients;
create trigger on_invite_recipient_created after insert on public.invite_recipients
  for each row execute function public.notify_on_invite_recipient();

-- Notify the host on every RSVP (yes/no/maybe) change.
create or replace function public.notify_on_invite_response()
returns trigger language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  if new.status is distinct from old.status and new.status <> 'pending' then
    select host_id into host from public.session_invites where id = new.invite_id;
    if host is not null and host <> new.user_id then
      insert into public.notifications (user_id, actor_id, type, invite_id)
      values (host, new.user_id, 'invite_response', new.invite_id);
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists on_invite_recipient_updated on public.invite_recipients;
create trigger on_invite_recipient_updated after update on public.invite_recipients
  for each row execute function public.notify_on_invite_response();

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'session_invites'
  ) then
    alter publication supabase_realtime add table public.session_invites;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'invite_recipients'
  ) then
    alter publication supabase_realtime add table public.invite_recipients;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Data API grants
-- ---------------------------------------------------------------------------

grant select, insert on public.courts to authenticated;
grant select, insert on public.session_invites to authenticated;
grant select, insert on public.invite_recipients to authenticated;
revoke update on public.invite_recipients from authenticated;
grant update (status, responded_at) on public.invite_recipients to authenticated;
