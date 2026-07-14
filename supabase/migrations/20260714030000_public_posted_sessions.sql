-- Discovery feed: a posted session is public to any authenticated user.
-- Unposted (draft) sessions remain visible only to their author. The
-- "Following" feed still scopes client-side to you + accepted follows.
drop policy if exists "sessions_read" on public.sessions;
create policy "sessions_read" on public.sessions
  for select to authenticated
  using (user_id = auth.uid() or posted = true);
