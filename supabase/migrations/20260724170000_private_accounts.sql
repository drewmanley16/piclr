-- Private accounts: an owner-controlled toggle. Public accounts behave as
-- before (posted sessions visible to everyone); private accounts require an
-- accepted follow to view sessions/comments/likes. Follower/following list
-- visibility is enforced client-side (AppStore.followList), same as before.

alter table public.profiles add column if not exists is_private boolean not null default false;

-- Whether viewer_id is allowed to see subject_id's follow graph (their
-- followers list / who they follow): always true for the subject themselves,
-- otherwise only if subject_id is public or viewer_id accepted-follows them.
create or replace function private.profile_graph_visible(viewer_id uuid, subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    viewer_id = subject_id
    or not exists (
      select 1 from public.profiles p where p.id = subject_id and p.is_private = true
    )
    or exists (
      select 1 from public.follows f
      where f.follower_id = viewer_id and f.followee_id = subject_id and f.status = 'accepted'
    );
$$;

-- A follow edge is visible to a non-participant viewer only if they're
-- allowed to see both endpoints' follow graphs; the two parties to the edge
-- can always see their own relationship (pending/incoming requests, etc.).
create or replace function private.can_view_follow_edge(viewer_id uuid, follower_id uuid, followee_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    viewer_id = follower_id
    or viewer_id = followee_id
    or (
      private.profile_graph_visible(viewer_id, follower_id)
      and private.profile_graph_visible(viewer_id, followee_id)
    );
$$;

drop policy if exists "follows_read" on public.follows;
create policy "follows_read" on public.follows
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and not private.is_blocked_between((select auth.uid()), follower_id)
    and not private.is_blocked_between((select auth.uid()), followee_id)
    and private.can_view_follow_edge((select auth.uid()), follower_id, followee_id)
  );

-- Follower/following counts stay public even for private accounts (matches
-- the client's "counts show, list hidden" behavior) — a security-definer RPC
-- so the tightened follows_read policy above doesn't undercount them.
create or replace function public.follow_counts(target_id uuid)
returns table(follower_count bigint, following_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.follows where followee_id = target_id and status = 'accepted'),
    (select count(*) from public.follows where follower_id = target_id and status = 'accepted')
  where private.is_active_user(auth.uid())
    and not private.is_blocked_between(auth.uid(), target_id);
$$;

revoke all on function public.follow_counts(uuid) from public, anon;
grant execute on function public.follow_counts(uuid) to authenticated;

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
      join public.profiles p on p.id = s.user_id
      where s.id = target_session_id
        and not private.is_blocked_between(viewer_id, s.user_id)
        and (
          s.user_id = viewer_id
          or exists (
            select 1 from public.activity_participants ap
            where ap.session_id = s.id and ap.profile_id = viewer_id
          )
          or (
            s.posted = true
            and (
              p.is_private = false
              or exists (
                select 1 from public.follows f
                where f.follower_id = viewer_id
                  and f.followee_id = s.user_id
                  and f.status = 'accepted'
              )
            )
          )
        )
    );
$$;
