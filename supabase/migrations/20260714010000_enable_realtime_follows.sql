-- Enable Supabase Realtime on the follows table so follow/unfollow and request
-- accepts surface live (follower count, follow-request banner) without a manual
-- refresh. Idempotent.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'follows'
  ) then
    alter publication supabase_realtime add table public.follows;
  end if;
end $$;
