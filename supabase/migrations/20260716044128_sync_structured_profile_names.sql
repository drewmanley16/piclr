create or replace function private.sync_profile_name_parts()
returns trigger
language plpgsql
set search_path = public, private
as $$
begin
  if tg_op = 'INSERT' then
    if new.first_name is null and new.last_name is null then
      new.first_name := nullif(substring(btrim(new.display_name) from '^[^[:space:]]+'), '');
      new.last_name := nullif(
        btrim(regexp_replace(btrim(new.display_name), '^[^[:space:]]+[[:space:]]*', '')),
        ''
      );
    end if;
  elsif new.display_name is distinct from old.display_name
    and new.first_name is not distinct from old.first_name
    and new.last_name is not distinct from old.last_name then
    new.first_name := nullif(substring(btrim(new.display_name) from '^[^[:space:]]+'), '');
    new.last_name := nullif(
      btrim(regexp_replace(btrim(new.display_name), '^[^[:space:]]+[[:space:]]*', '')),
      ''
    );
  end if;

  return new;
end;
$$;

drop trigger if exists sync_profile_name_parts on public.profiles;
create trigger sync_profile_name_parts
  before insert or update of display_name on public.profiles
  for each row execute function private.sync_profile_name_parts();
