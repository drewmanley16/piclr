-- Optional birthday on the profile (edited in Settings).
alter table public.profiles add column if not exists birthday date;
