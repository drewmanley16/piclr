-- Scoped lookup for contact matching so the edge function never needs the
-- `private` schema exposed through PostgREST. SECURITY DEFINER runs as the
-- function owner (which can read private.phone_lookup); execute is granted only
-- to service_role (the match-contacts edge function).

create or replace function public.match_phone_lookup(phones text[])
returns table (profile_id uuid, phone_e164 text)
language sql
security definer
set search_path = ''
as $$
  select p.profile_id, p.phone_e164
  from private.phone_lookup p
  where p.phone_e164 = any(phones);
$$;

revoke all on function public.match_phone_lookup(text[]) from public, anon, authenticated;
grant execute on function public.match_phone_lookup(text[]) to service_role;
