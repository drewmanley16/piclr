-- Drop the emoji field from squads — a plain name is enough; no picker in
-- the client. create_squad() no longer takes an emoji parameter.

alter table public.squads drop column if exists emoji;

drop function if exists public.create_squad(text, text);

create or replace function public.create_squad(p_name text)
returns public.squads
language plpgsql
security definer
set search_path = public
as $$
declare
  new_squad public.squads;
begin
  if not private.is_active_user(auth.uid()) then
    raise exception 'not_active_user' using errcode = 'P0001';
  end if;

  insert into public.squads (name, owner_id, join_code)
  values (trim(p_name), auth.uid(), private.generate_squad_code())
  returning * into new_squad;

  insert into public.squad_members (squad_id, user_id, role, invited_by)
  values (new_squad.id, auth.uid(), 'owner', auth.uid());

  return new_squad;
end;
$$;
revoke all on function public.create_squad(text) from public;
grant execute on function public.create_squad(text) to authenticated;
