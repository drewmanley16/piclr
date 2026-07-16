alter table public.profiles
  add column if not exists first_name text,
  add column if not exists last_name text;

-- Preserve existing display_name consumers while making completed profiles
-- available to the new structured-name UI.
update public.profiles
set
  first_name = coalesce(
    first_name,
    nullif(substring(btrim(display_name) from '^\S+'), '')
  ),
  last_name = coalesce(
    last_name,
    nullif(btrim(regexp_replace(btrim(display_name), '^\S+\s*', '')), '')
  )
where onboarding_completed_at is not null
  and (first_name is null or last_name is null);

-- Usernames are case-insensitively unique. Keeping this at the database layer
-- prevents concurrent onboarding requests from claiming the same handle.
create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username));
