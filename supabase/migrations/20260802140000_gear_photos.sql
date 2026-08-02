-- Photos on gear, visible exactly as far as the gear row itself is.
--
-- A gear photo must never outlive its row's visibility: if someone switches
-- `gear_visible` off, the object behind the thumbnail has to stop resolving
-- too, or the switch is a lie. So the visibility rule moves out of the
-- `gear_read` policy body and into `private.can_view_gear`, which both the
-- table policy and Storage's `private.can_read_media` now consult. One rule,
-- two enforcement points, no chance of drift.

alter table public.gear add column if not exists photo_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gear-photos', 'gear-photos', false, 10485760,
        array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- The single source of truth for "can this viewer see this gear item?"
-- Mirrors private.can_view_session: owner always; everyone else needs the
-- locker switched on plus permission to see that owner's profile content.
-- ---------------------------------------------------------------------------

create or replace function private.can_view_gear(viewer_id uuid, target_gear_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_active_user(viewer_id)
    and exists (
      select 1
      from public.gear g
      join public.profiles p on p.id = g.user_id
      where g.id = target_gear_id
        and not private.is_blocked_between(viewer_id, g.user_id)
        and (
          g.user_id = viewer_id
          or (
            p.gear_visible
            and private.profile_graph_visible(viewer_id, g.user_id)
          )
        )
    );
$$;

-- The table policy keeps its predicate on `user_id` (so a locker read stays a
-- single indexed scan rather than a per-row function call), matching
-- can_view_gear condition for condition.
drop policy if exists "gear_read" on public.gear;
create policy "gear_read" on public.gear
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and not private.is_blocked_between((select auth.uid()), user_id)
    and (
      user_id = (select auth.uid())
      or (
        exists (
          select 1 from public.profiles p
          where p.id = gear.user_id and p.gear_visible
        )
        and private.profile_graph_visible((select auth.uid()), user_id)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- Storage. Re-created in full so the existing avatars / post-photos branches
-- carry over unchanged; only the gear-photos branch is new.
-- ---------------------------------------------------------------------------

create or replace function private.can_read_media(
  viewer_id uuid,
  bucket_name text,
  object_name text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uuid_pattern constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  owner_text text := split_part(object_name, '/', 1);
  target_text text;
  owner_id uuid;
  target_session_id uuid;
  target_gear_id uuid;
begin
  if viewer_id is null or owner_text !~ uuid_pattern then return false; end if;
  owner_id := owner_text::uuid;

  if bucket_name = 'avatars' then
    return private.can_view_profile(viewer_id, owner_id);
  end if;

  if bucket_name = 'post-photos' then
    target_text := split_part(split_part(object_name, '/', 2), '.', 1);
    if target_text !~ uuid_pattern then return false; end if;
    target_session_id := target_text::uuid;
    return private.can_view_session(viewer_id, target_session_id)
      and exists (
        select 1 from public.sessions s
        where s.id = target_session_id and s.user_id = owner_id
      );
  end if;

  -- gear-photos objects are <owner-uid>/<gear-id>.jpg. The folder owner must
  -- also be the gear's owner, so a readable item can't be used to serve a file
  -- parked in someone else's folder.
  if bucket_name = 'gear-photos' then
    target_text := split_part(split_part(object_name, '/', 2), '.', 1);
    if target_text !~ uuid_pattern then return false; end if;
    target_gear_id := target_text::uuid;
    return private.can_view_gear(viewer_id, target_gear_id)
      and exists (
        select 1 from public.gear g
        where g.id = target_gear_id and g.user_id = owner_id
      );
  end if;

  return false;
end;
$$;

drop policy if exists "gear_photos_read" on storage.objects;
create policy "gear_photos_read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'gear-photos'
    and private.can_read_media((select auth.uid()), bucket_id, name)
  );

drop policy if exists "gear_photos_insert_own" on storage.objects;
create policy "gear_photos_insert_own"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'gear-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "gear_photos_update_own" on storage.objects;
create policy "gear_photos_update_own"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'gear-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'gear-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "gear_photos_delete_own" on storage.objects;
create policy "gear_photos_delete_own"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'gear-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
