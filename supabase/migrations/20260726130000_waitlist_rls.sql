-- The public.waitlist table was created without RLS enabled, which (combined
-- with Supabase's default "grant all to anon, authenticated" on new tables)
-- meant anyone with the app's public anon key could select/update/delete every
-- row, exposing every collected email address. Lock it down: anon may only
-- insert (the landing page signup flow), and only the service role (used by
-- the waitlist-notify edge function) may read.

alter table public.waitlist enable row level security;

revoke all on public.waitlist from anon, authenticated;
grant insert on public.waitlist to anon, authenticated;

create policy "anon can join waitlist"
    on public.waitlist
    for insert
    to anon, authenticated
    with check (true);
