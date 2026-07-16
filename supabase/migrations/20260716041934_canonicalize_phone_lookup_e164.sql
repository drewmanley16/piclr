-- Supabase Auth may expose verified phone numbers without a leading `+`, while
-- the iOS importer and match-contacts function canonicalize requests as
-- `+<digits>`. Store one representation on both sides so exact matching works.

create or replace function private.sync_phone_lookup(target_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  verified_phone text;
begin
  select '+' || regexp_replace(u.phone, '[^0-9]', '', 'g')
    into verified_phone
  from auth.users u
  join public.profiles p on p.id = u.id
  where u.id = target_profile_id
    and p.onboarding_completed_at is not null
    and u.phone is not null
    and regexp_replace(u.phone, '[^0-9]', '', 'g') ~ '^[1-9][0-9]{7,14}$';

  if verified_phone is null then
    delete from private.phone_lookup
    where profile_id = target_profile_id;
    return;
  end if;

  delete from private.phone_lookup
  where phone_e164 = verified_phone
    and profile_id <> target_profile_id;

  insert into private.phone_lookup (profile_id, phone_e164, updated_at)
  values (target_profile_id, verified_phone, now())
  on conflict (profile_id) do update
  set phone_e164 = excluded.phone_e164,
      updated_at = excluded.updated_at;
end;
$$;

revoke all on function private.sync_phone_lookup(uuid)
  from public, anon, authenticated, service_role;

do $backfill$
declare
  completed_profile record;
begin
  for completed_profile in
    select p.id
    from public.profiles p
    where p.onboarding_completed_at is not null
  loop
    perform private.sync_phone_lookup(completed_profile.id);
  end loop;
end;
$backfill$;
