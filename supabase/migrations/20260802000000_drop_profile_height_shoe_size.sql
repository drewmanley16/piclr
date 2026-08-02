-- Drops height and shoe size from Measures, which is now a weight-only sheet.
--
-- DESTRUCTIVE AND IRREVERSIBLE: the stored values go with the columns.
--
-- Reads are safe for older clients: every profile select is `*` or an explicit
-- column list that never named these two, and the iOS model decoded both with
-- `decodeIfPresent`. The write path is not: an older build tapping "Save
-- Measures" sends `height_inches`/`shoe_size` in the update body and PostgREST
-- will 400 on the unknown columns. Weight-only saves and every other profile
-- write are unaffected.

do $$
declare
  with_height    bigint;
  with_shoe_size bigint;
begin
  select count(*) filter (where height_inches is not null),
         count(*) filter (where shoe_size is not null)
    into with_height, with_shoe_size
    from public.profiles;
  raise notice 'dropping profiles.height_inches (% rows with a value) and profiles.shoe_size (% rows with a value)',
    with_height, with_shoe_size;
end $$;

alter table public.profiles
  drop column if exists height_inches,
  drop column if exists shoe_size;
