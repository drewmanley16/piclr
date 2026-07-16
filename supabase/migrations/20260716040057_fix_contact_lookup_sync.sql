-- Keep the private contact-discovery index in sync with the verified phone
-- stored by Supabase Auth. The index is derived data: application code should
-- never need direct write access to it.

create or replace function private.sync_phone_lookup(target_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  verified_phone text;
begin
  select u.phone
    into verified_phone
  from auth.users u
  join public.profiles p on p.id = u.id
  where u.id = target_profile_id
    and p.onboarding_completed_at is not null
    and u.phone is not null;

  if verified_phone is null then
    delete from private.phone_lookup
    where profile_id = target_profile_id;
    return;
  end if;

  -- Auth phone numbers are unique. If an older lookup row still owns the
  -- newly verified number, it is stale and must not block the current owner.
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

create or replace function private.sync_phone_lookup_from_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.sync_phone_lookup(new.id);
  return new;
end;
$$;

create or replace function private.sync_phone_lookup_from_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.sync_phone_lookup(new.id);
  return new;
end;
$$;

revoke all on function private.sync_phone_lookup(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.sync_phone_lookup_from_profile()
  from public, anon, authenticated, service_role;
revoke all on function private.sync_phone_lookup_from_auth_user()
  from public, anon, authenticated, service_role;

drop trigger if exists sync_phone_lookup_after_profile_onboarding on public.profiles;
create trigger sync_phone_lookup_after_profile_onboarding
after insert or update of onboarding_completed_at on public.profiles
for each row
execute function private.sync_phone_lookup_from_profile();

drop trigger if exists sync_phone_lookup_after_auth_phone_change on auth.users;
create trigger sync_phone_lookup_after_auth_phone_change
after update of phone on auth.users
for each row
when (old.phone is distinct from new.phone)
execute function private.sync_phone_lookup_from_auth_user();

-- Repair the current index before enabling read access through the RPC. This
-- removes both missing entries and entries left stale by prior phone changes.
delete from private.phone_lookup l
where not exists (
  select 1
  from auth.users u
  join public.profiles p on p.id = u.id
  where u.id = l.profile_id
    and p.onboarding_completed_at is not null
    and u.phone is not null
    and u.phone = l.phone_e164
);

insert into private.phone_lookup (profile_id, phone_e164, updated_at)
select p.id, u.phone, now()
from public.profiles p
join auth.users u on u.id = p.id
where p.onboarding_completed_at is not null
  and u.phone is not null
on conflict (profile_id) do update
set phone_e164 = excluded.phone_e164,
    updated_at = excluded.updated_at;

-- The Data API invokes this public RPC as service_role. Keep the function
-- security-invoker and grant that role only the private read privileges needed
-- by the query; all writes remain owned by the database triggers above.
create or replace function public.match_phone_lookup(phones text[])
returns table (profile_id uuid, phone_e164 text)
language sql
security invoker
set search_path = ''
as $$
  select p.profile_id, p.phone_e164
  from private.phone_lookup p
  where p.phone_e164 = any(phones);
$$;

revoke all on schema private from public, anon, authenticated;
revoke all on table private.phone_lookup from public, anon, authenticated, service_role;
grant usage on schema private to service_role;
grant select on table private.phone_lookup to service_role;

revoke all on function public.match_phone_lookup(text[])
  from public, anon, authenticated;
grant execute on function public.match_phone_lookup(text[]) to service_role;

-- The private schema no longer needs a Data API endpoint. The public RPC above
-- remains available while direct private-schema requests are rejected.
alter role authenticator set pgrst.db_schemas = 'public, graphql_public';
notify pgrst, 'reload config';
