-- Squads: formal named groups (a "clan"), distinct from the existing
-- crew_leaderboard() concept (you + everyone you follow). Members join
-- either via an owner-issued join code or a direct invite of an existing
-- follower. Users may belong to multiple squads. v1 roles: owner (create/
-- rename/delete/invite/remove) + member — no separate admin role.

create table if not exists public.squads (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 40),
  emoji      text not null default '🏓',
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  join_code  text not null unique,
  created_at timestamptz not null default now()
);
create index if not exists squads_owner_idx on public.squads (owner_id);
create table if not exists public.squad_members (
  id         uuid primary key default gen_random_uuid(),
  squad_id   uuid not null references public.squads(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null default 'member' check (role in ('owner', 'member')),
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at  timestamptz not null default now(),
  unique (squad_id, user_id)
);
create index if not exists squad_members_squad_idx on public.squad_members (squad_id);
create index if not exists squad_members_user_idx  on public.squad_members (user_id);
alter table public.squads enable row level security;
alter table public.squad_members enable row level security;
-- ---------------------------------------------------------------------------
-- Authorization helpers
-- ---------------------------------------------------------------------------

create or replace function private.is_squad_member(candidate_id uuid, target_squad_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.squad_members m
    where m.squad_id = target_squad_id and m.user_id = candidate_id
  );
$$;
create or replace function private.is_squad_owner(candidate_id uuid, target_squad_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.squad_members m
    where m.squad_id = target_squad_id and m.user_id = candidate_id and m.role = 'owner'
  );
$$;
-- Unambiguous alphabet (no O/0/I/1) — codes aren't secrets protecting
-- sensitive data, same tier as session invites, just need to be typeable.
create or replace function private.generate_squad_code()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
  tries int := 0;
begin
  loop
    code := '';
    for i in 1..7 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.squads where join_code = code);
    tries := tries + 1;
    if tries > 20 then
      raise exception 'squad code generation failed';
    end if;
  end loop;
  return code;
end;
$$;
-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

drop policy if exists "squads_read"   on public.squads;
drop policy if exists "squads_insert" on public.squads;
drop policy if exists "squads_update" on public.squads;
drop policy if exists "squads_delete" on public.squads;
create policy "squads_read" on public.squads
  for select to authenticated
  using (private.is_squad_member((select auth.uid()), id));
create policy "squads_insert" on public.squads
  for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and private.is_active_user((select auth.uid()))
  );
create policy "squads_update" on public.squads
  for update to authenticated
  using (private.is_squad_owner((select auth.uid()), id))
  with check (owner_id = (select auth.uid()));
create policy "squads_delete" on public.squads
  for delete to authenticated
  using (private.is_squad_owner((select auth.uid()), id));
-- squad_members: members read their squad's roster. Raw insert is owner-only
-- (direct invite); self-join happens only through redeem_squad_code(), which
-- runs security definer and bypasses this policy intentionally. A member
-- may delete their own row (leave); the owner may delete anyone (remove).
drop policy if exists "squad_members_read"   on public.squad_members;
drop policy if exists "squad_members_insert" on public.squad_members;
drop policy if exists "squad_members_delete" on public.squad_members;
create policy "squad_members_read" on public.squad_members
  for select to authenticated
  using (private.is_squad_member((select auth.uid()), squad_id));
create policy "squad_members_insert" on public.squad_members
  for insert to authenticated
  with check (
    private.is_squad_owner((select auth.uid()), squad_id)
    and invited_by = (select auth.uid())
  );
create policy "squad_members_delete" on public.squad_members
  for delete to authenticated
  using (
    user_id = (select auth.uid())
    or private.is_squad_owner((select auth.uid()), squad_id)
  );
-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Atomically creates a squad and seats the caller as owner. security definer
-- because squad_members_insert (owner-only) can't be satisfied until the
-- first row exists — this RPC bootstraps that first row.
create or replace function public.create_squad(p_name text, p_emoji text default '🏓')
returns public.squads
language plpgsql
security definer
set search_path = public
as $$
declare
  new_squad public.squads;
begin
  if not private.is_active_user(auth.uid()) then
    raise exception 'not_active_user' using errcode = 'P0001';
  end if;

  insert into public.squads (name, emoji, owner_id, join_code)
  values (
    trim(p_name),
    coalesce(nullif(trim(p_emoji), ''), '🏓'),
    auth.uid(),
    private.generate_squad_code()
  )
  returning * into new_squad;

  insert into public.squad_members (squad_id, user_id, role, invited_by)
  values (new_squad.id, auth.uid(), 'owner', auth.uid());

  return new_squad;
end;
$$;
revoke all on function public.create_squad(text, text) from public;
grant execute on function public.create_squad(text, text) to authenticated;
-- Redeem a join code: the only self-join path. security definer to bypass
-- the owner-only squad_members insert policy for this one controlled route.
create or replace function public.redeem_squad_code(p_code text)
returns public.squads
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.squads;
begin
  if not private.is_active_user(auth.uid()) then
    raise exception 'not_active_user' using errcode = 'P0001';
  end if;

  select * into target from public.squads where join_code = upper(trim(p_code));
  if target.id is null then
    raise exception 'invalid_code' using errcode = 'P0001';
  end if;

  insert into public.squad_members (squad_id, user_id, role, invited_by)
  values (target.id, auth.uid(), 'member', target.owner_id)
  on conflict (squad_id, user_id) do nothing;

  return target;
end;
$$;
revoke all on function public.redeem_squad_code(text) from public;
grant execute on function public.redeem_squad_code(text) to authenticated;
-- Owner invites an existing follower directly (no code needed).
create or replace function public.invite_to_squad(p_squad_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not private.is_squad_owner(auth.uid(), p_squad_id) then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;
  if not private.is_active_user(p_user_id) then
    raise exception 'invalid_user' using errcode = 'P0001';
  end if;

  insert into public.squad_members (squad_id, user_id, role, invited_by)
  values (p_squad_id, p_user_id, 'member', auth.uid())
  on conflict (squad_id, user_id) do nothing;
end;
$$;
revoke all on function public.invite_to_squad(uuid, uuid) from public;
grant execute on function public.invite_to_squad(uuid, uuid) to authenticated;
-- Squad-scoped leaderboard, same stat shape as crew_leaderboard() but scoped
-- to squad_members instead of the follow graph. security definer to read
-- other members' match aggregates; validates caller membership itself as
-- defense in depth (RLS on squad_members already blocks non-members from
-- resolving a given squad_id in the first place).
create or replace function public.squad_leaderboard(p_squad_id uuid, p_period text default 'all')
returns table (
  user_id         uuid,
  username        text,
  display_name    text,
  avatar_url      text,
  avatar_initials text,
  is_pro          boolean,
  wins            int,
  losses          int,
  matches         int
)
language sql
stable
security definer
set search_path = public
as $$
  with member_check as (
    select 1 from public.squad_members m
    where m.squad_id = p_squad_id and m.user_id = auth.uid()
  ),
  window_start as (
    select case p_period
      when 'month'  then date_trunc('month', now())
      when 'season' then date_trunc('month', now()) - interval '2 months'
      else timestamptz '-infinity'
    end as start
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    p.is_pro,
    coalesce(count(*) filter (where sa.won is true), 0)::int  as wins,
    coalesce(count(*) filter (where sa.won is false), 0)::int as losses,
    coalesce(count(*) filter (where sa.won is not null), 0)::int as matches
  from public.squad_members sm
  join public.profiles p on p.id = sm.user_id
  left join public.sessions s
    on s.user_id = p.id
    and coalesce(s.started_at, s.created_at) >= (select start from window_start)
  left join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match'
  where sm.squad_id = p_squad_id
    and exists (select 1 from member_check)
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials, p.is_pro;
$$;
revoke all on function public.squad_leaderboard(uuid, text) from public;
grant execute on function public.squad_leaderboard(uuid, text) to authenticated;
-- ---------------------------------------------------------------------------
-- Notifications integration
-- ---------------------------------------------------------------------------

-- Appending 'squad_invite' to the existing type list (as of
-- 20260725120000_remove_season_awards.sql) — every prior value is preserved.
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'comment_reply', 'comment_like',
                  'follow', 'tag', 'repost_approved', 'invite_received',
                  'invite_response', 'invite_cancelled', 'rivalry', 'streak',
                  'mention', 'weekly_wrap', 'milestone_unlocked', 'squad_invite'));
alter table public.notifications add column if not exists squad_id uuid references public.squads(id) on delete cascade;
create index if not exists notifications_squad_idx
  on public.notifications (squad_id) where squad_id is not null;
-- Notify a member when they're added to a squad (direct invite or code
-- redemption) — skip the owner's own bootstrap row from create_squad().
create or replace function public.notify_on_squad_member_added()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role <> 'owner' and new.invited_by is not null and new.invited_by <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, squad_id)
    values (new.user_id, new.invited_by, 'squad_invite', new.squad_id);
  end if;
  return new;
end;
$$;
drop trigger if exists on_squad_member_added on public.squad_members;
create trigger on_squad_member_added after insert on public.squad_members
  for each row execute function public.notify_on_squad_member_added();
-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'squad_members'
  ) then
    alter publication supabase_realtime add table public.squad_members;
  end if;
end $$;
-- ---------------------------------------------------------------------------
-- Data API grants
-- ---------------------------------------------------------------------------

-- squads: select via RLS, insert reachable directly by squads_insert policy
-- (create_squad wraps it for the atomic 2-row transaction, but the grant
-- still needs to exist for the policy to be reachable at all). No update/
-- delete grant — those go through owner-gated app flows only if ever added;
-- omitted from v1 UI (rename/delete not yet exposed via raw table access).
grant select, insert on public.squads to authenticated;
-- squad_members: select via RLS, delete via RLS (leave/remove); insert is
-- intentionally NOT granted — the only insert paths are the security
-- definer RPCs above (create_squad, redeem_squad_code, invite_to_squad),
-- which run as the function owner and bypass grants entirely.
grant select, delete on public.squad_members to authenticated;
