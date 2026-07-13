-- Directional follow graph — the app's social model.
--
-- Converts the legacy `follows` table (follower_id -> following_id, no state)
-- into a directed friend-request model:
--   status: pending (requested) | accepted | rejected
-- Following is directional: B accepting A's request does NOT make B follow A
-- back. This supersedes the mutual `friend_requests` table for app code;
-- friend_requests is left in place for now and will be dropped later.
--
-- Idempotent: applies cleanly whether or not the table was already migrated.

-- 1. Rename following_id -> followee_id if the legacy column is present.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'follows' and column_name = 'following_id'
  ) then
    alter table public.follows rename column following_id to followee_id;
    if exists (
      select 1 from pg_constraint where conname = 'follows_following_id_fkey'
    ) then
      alter table public.follows rename constraint follows_following_id_fkey to follows_followee_id_fkey;
    end if;
  end if;
end $$;

-- 2. Relationship state.
alter table public.follows
  add column if not exists status text not null default 'pending';
alter table public.follows
  drop constraint if exists follows_status_check;
alter table public.follows
  add constraint follows_status_check check (status in ('pending', 'accepted', 'rejected'));

-- 3. Follower lists + pending-request inboxes ("edges into B, by status").
--    Follower-side lists (edges out of A) are served by the primary key.
create index if not exists follows_followee_status_idx
  on public.follows (followee_id, status);

-- 4. RLS: requester controls the request (create pending / cancel); the
--    recipient controls acceptance (accept/reject).
drop policy if exists "follows_read"   on public.follows;
drop policy if exists "follows_insert" on public.follows;
drop policy if exists "follows_update" on public.follows;
drop policy if exists "follows_delete" on public.follows;

create policy "follows_read" on public.follows
  for select to authenticated using (true);
-- You may only create your own request, and it must start as pending.
create policy "follows_insert" on public.follows
  for insert to authenticated
  with check (follower_id = auth.uid() and status = 'pending');
-- Only the recipient can act on a request, and only to accept or reject it.
create policy "follows_update" on public.follows
  for update to authenticated
  using (followee_id = auth.uid())
  with check (followee_id = auth.uid() and status in ('accepted', 'rejected'));
-- The requester can cancel/unfollow; the recipient can reject/remove.
create policy "follows_delete" on public.follows
  for delete to authenticated
  using (follower_id = auth.uid() or followee_id = auth.uid());

grant select, insert, update, delete on public.follows to authenticated;

-- 5. Feed visibility now follows the directional graph: you can read your own
--    sessions, plus posted sessions of people you follow (accepted). This
--    replaces the previous friend_requests-based visibility check.
drop policy if exists "sessions_read" on public.sessions;
create policy "sessions_read" on public.sessions
  for select to authenticated
  using (
    user_id = auth.uid()
    or (
      posted = true
      and exists (
        select 1 from public.follows f
        where f.status = 'accepted'
          and f.follower_id = auth.uid()
          and f.followee_id = sessions.user_id
      )
    )
  );
