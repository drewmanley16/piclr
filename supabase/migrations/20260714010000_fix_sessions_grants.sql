-- The `authenticated` role was missing INSERT/UPDATE on public.sessions, so
-- posting a session failed with "permission denied for table sessions" (a
-- grant-level error, distinct from RLS). Restore them; RLS still gates rows.
grant insert, update on public.sessions to authenticated;
