-- Permission-gated reposts: a player tagged in a session can request to repost
-- it; the original author approves, which copies the session into the
-- requester's log (a new session pointing back via reposted_from).

alter table public.sessions
  add column if not exists reposted_from uuid references public.sessions(id) on delete set null;

create table if not exists public.repost_requests (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.sessions(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (session_id, requester_id)
);
create index if not exists repost_requests_requester_idx on public.repost_requests (requester_id, status);
create index if not exists repost_requests_session_idx on public.repost_requests (session_id, status);

alter table public.repost_requests enable row level security;

-- Visible to the requester and to the session's author.
drop policy if exists "repost_requests_read"   on public.repost_requests;
drop policy if exists "repost_requests_insert" on public.repost_requests;
drop policy if exists "repost_requests_update" on public.repost_requests;
create policy "repost_requests_read" on public.repost_requests
  for select to authenticated using (
    requester_id = auth.uid()
    or exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid())
  );
-- Only a tagged participant may request to repost, and only as themselves.
create policy "repost_requests_insert" on public.repost_requests
  for insert to authenticated with check (
    requester_id = auth.uid()
    and exists (
      select 1 from public.activity_participants ap
      where ap.session_id = repost_requests.session_id and ap.profile_id = auth.uid()
    )
  );
-- The session's author resolves the request (approve/decline).
create policy "repost_requests_update" on public.repost_requests
  for update to authenticated using (
    exists (select 1 from public.sessions s where s.id = session_id and s.user_id = auth.uid())
  );

-- Approve + copy the session into the requester's log. SECURITY DEFINER so the
-- copy can be written as the requester; the caller must be the original author.
create or replace function public.approve_repost(request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  req  public.repost_requests;
  orig public.sessions;
  new_session_id uuid := gen_random_uuid();
  act  public.session_activities;
  new_act_id uuid;
begin
  select * into req from public.repost_requests where id = request_id;
  if req.id is null then raise exception 'Repost request not found'; end if;

  select * into orig from public.sessions where id = req.session_id;
  if orig.user_id <> auth.uid() then raise exception 'Only the author can approve'; end if;

  update public.repost_requests set status = 'approved', updated_at = now() where id = request_id;

  insert into public.sessions
    (id, user_id, title, location, duration_minutes, focus, takeaway, posted, reposted_from, created_at)
  values
    (new_session_id, req.requester_id, orig.title, orig.location, orig.duration_minutes,
     orig.focus, orig.takeaway, true, orig.id, now());

  for act in
    select * from public.session_activities where session_id = orig.id order by position
  loop
    new_act_id := gen_random_uuid();
    insert into public.session_activities
      (id, session_id, kind, position, focus, reps, notes, team_score, opponent_score, won)
    values
      (new_act_id, new_session_id, act.kind, act.position, act.focus, act.reps, act.notes,
       act.team_score, act.opponent_score, act.won);
    insert into public.activity_participants (activity_id, session_id, profile_id, guest_name, role)
      select new_act_id, new_session_id, profile_id, guest_name, role
      from public.activity_participants where activity_id = act.id;
  end loop;

  return new_session_id;
end;
$$;

revoke all on function public.approve_repost(uuid) from public, anon;
grant execute on function public.approve_repost(uuid) to authenticated;
