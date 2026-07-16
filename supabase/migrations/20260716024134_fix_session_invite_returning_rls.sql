-- Allow an invite host to read the row being returned by the insert that
-- creates it. The security-definer helper re-queries session_invites and does
-- not see that row until the insert statement completes, so relying on the
-- helper alone causes INSERT ... RETURNING to fail its SELECT policy.

drop policy if exists "session_invites_read" on public.session_invites;

create policy "session_invites_read" on public.session_invites
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and (
      host_id = (select auth.uid())
      or private.can_view_invite((select auth.uid()), id)
    )
  );
