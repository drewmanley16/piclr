-- Drop the duplicate waitlist INSERT policy.
--
-- `public.waitlist` carries two functionally identical INSERT policies:
--
--   "anon can join waitlist"  -- from 20260726130000_waitlist_rls.sql
--   "waitlist_public_insert"  -- exists in no migration; a dashboard hand-edit
--
-- Both are `to anon, authenticated with check (true)`, so the second grants
-- nothing the first doesn't. Postgres evaluates every permissive policy for a
-- command, so the duplicate is pure overhead and one more thing that makes
-- `supabase/migrations/` disagree with the live database.
--
-- Keep the one that exists in a migration; drop the one that doesn't.

drop policy if exists "waitlist_public_insert" on public.waitlist;
