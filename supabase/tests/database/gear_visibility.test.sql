-- `gear_read` composes three rules and each one hides gear on its own:
--   * the owner always reads their own rows, even hidden ones
--   * `profiles.gear_visible = false` hides the locker from everyone else
--   * a private owner's locker is only readable by an accepted follower
-- Plus the pre-existing block rule. Each is asserted from a real viewer's seat.

begin;

create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email) values
  ('a0000001-0000-0000-0000-000000000001', 'gear-owner@example.test'),
  ('a0000002-0000-0000-0000-000000000002', 'gear-viewer@example.test'),
  ('a0000003-0000-0000-0000-000000000003', 'gear-private@example.test'),
  ('a0000004-0000-0000-0000-000000000004', 'gear-follower@example.test'),
  ('a0000005-0000-0000-0000-000000000005', 'gear-blocked@example.test')
on conflict (id) do nothing;

insert into public.profiles (
  id, username, display_name, onboarding_completed_at, is_private
) values
  ('a0000001-0000-0000-0000-000000000001', 'gear_owner', 'Gear Owner', now(), false),
  ('a0000002-0000-0000-0000-000000000002', 'gear_viewer', 'Gear Viewer', now(), false),
  ('a0000003-0000-0000-0000-000000000003', 'gear_private', 'Gear Private', now(), true),
  ('a0000004-0000-0000-0000-000000000004', 'gear_follower', 'Gear Follower', now(), false),
  ('a0000005-0000-0000-0000-000000000005', 'gear_blocked', 'Gear Blocked', now(), false)
on conflict (id) do update set
  onboarding_completed_at = excluded.onboarding_completed_at,
  is_private = excluded.is_private;

-- The follower has an accepted follow on the private owner; the plain viewer
-- does not.
insert into public.follows (follower_id, followee_id, status) values
  ('a0000004-0000-0000-0000-000000000004', 'a0000003-0000-0000-0000-000000000003', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

insert into public.gear (id, user_id, category, name, brand) values
  ('a1000000-0000-0000-0000-000000000001',
   'a0000001-0000-0000-0000-000000000001', 'Paddle', 'Public Paddle', 'Joola'),
  ('a1000000-0000-0000-0000-000000000002',
   'a0000003-0000-0000-0000-000000000003', 'Paddle', 'Private Paddle', 'Selkirk');

select has_column('public', 'profiles', 'gear_visible', 'profiles carry a gear visibility switch');

select is(
  (select gear_visible from public.profiles
   where id = 'a0000001-0000-0000-0000-000000000001'),
  true,
  'lockers default to visible'
);

-- A public owner with a visible locker: anyone signed in can see it.
set local role authenticated;
set local request.jwt.claim.sub = 'a0000002-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000001-0000-0000-0000-000000000001'),
  1,
  'a visible locker is readable by another signed-in player'
);
reset role;

-- Owner hides the locker.
update public.profiles set gear_visible = false
where id = 'a0000001-0000-0000-0000-000000000001';

set local role authenticated;
set local request.jwt.claim.sub = 'a0000002-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000001-0000-0000-0000-000000000001'),
  0,
  'hiding the locker hides it from other players'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'a0000001-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000001-0000-0000-0000-000000000001'),
  1,
  'hiding the locker never hides it from its owner'
);
reset role;

update public.profiles set gear_visible = true
where id = 'a0000001-0000-0000-0000-000000000001';

-- A private account's locker follows the same rule as their sessions.
set local role authenticated;
set local request.jwt.claim.sub = 'a0000002-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000003-0000-0000-0000-000000000003'),
  0,
  'a private account''s gear is hidden from a non-follower'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'a0000004-0000-0000-0000-000000000004';
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000003-0000-0000-0000-000000000003'),
  1,
  'an accepted follower sees a private account''s gear'
);
reset role;

-- Blocking still wins over a visible locker. The block goes in as the blocker
-- themselves — `private.prepare_block` rejects anything else and fills the
-- denormalized username/display-name columns.
set local role authenticated;
set local request.jwt.claim.sub = 'a0000005-0000-0000-0000-000000000005';
insert into public.blocks (blocker_id, blocked_id) values
  ('a0000005-0000-0000-0000-000000000005', 'a0000001-0000-0000-0000-000000000001')
on conflict do nothing;
select is(
  (select count(*)::integer from public.gear
   where user_id = 'a0000001-0000-0000-0000-000000000001'),
  0,
  'a block hides gear even when the locker is visible'
);
reset role;

select ok(
  not has_table_privilege('anon', 'public.gear', 'SELECT'),
  'anonymous clients cannot read gear'
);

-- ---------------------------------------------------------------------------
-- Gear photos. `private.can_read_media` is what Storage consults before it will
-- sign a URL, so asserting it directly proves a photo can never be readable
-- when its gear row isn't — no Storage objects required.
-- ---------------------------------------------------------------------------

update public.gear
set photo_path = 'a0000001-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001.jpg'
where id = 'a1000000-0000-0000-0000-000000000001';

select ok(
  private.can_read_media(
    'a0000002-0000-0000-0000-000000000002',
    'gear-photos',
    'a0000001-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001.jpg'
  ),
  'a visible locker''s photo is readable by another player'
);

update public.profiles set gear_visible = false
where id = 'a0000001-0000-0000-0000-000000000001';

select ok(
  not private.can_read_media(
    'a0000002-0000-0000-0000-000000000002',
    'gear-photos',
    'a0000001-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001.jpg'
  ),
  'hiding the locker also hides its photos'
);

select ok(
  private.can_read_media(
    'a0000001-0000-0000-0000-000000000001',
    'gear-photos',
    'a0000001-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001.jpg'
  ),
  'the owner still reads their own hidden photo'
);

update public.profiles set gear_visible = true
where id = 'a0000001-0000-0000-0000-000000000001';

select ok(
  not private.can_read_media(
    'a0000005-0000-0000-0000-000000000005',
    'gear-photos',
    'a0000001-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001.jpg'
  ),
  'a block hides gear photos too'
);

-- The private owner's item, for the follower/non-follower split.
select ok(
  not private.can_read_media(
    'a0000002-0000-0000-0000-000000000002',
    'gear-photos',
    'a0000003-0000-0000-0000-000000000003/a1000000-0000-0000-0000-000000000002.jpg'
  ),
  'a private account''s gear photo is hidden from a non-follower'
);

select ok(
  private.can_read_media(
    'a0000004-0000-0000-0000-000000000004',
    'gear-photos',
    'a0000003-0000-0000-0000-000000000003/a1000000-0000-0000-0000-000000000002.jpg'
  ),
  'an accepted follower can read a private account''s gear photo'
);

-- A readable item must not be usable to pull a file out of someone else's
-- folder: the folder owner has to be the gear's owner.
select ok(
  not private.can_read_media(
    'a0000002-0000-0000-0000-000000000002',
    'gear-photos',
    'a0000002-0000-0000-0000-000000000002/a1000000-0000-0000-0000-000000000001.jpg'
  ),
  'a gear id cannot unlock an object in a different owner''s folder'
);

select ok(
  not private.can_read_media(
    'a0000002-0000-0000-0000-000000000002',
    'gear-photos',
    'a0000001-0000-0000-0000-000000000001/not-a-uuid.jpg'
  ),
  'a malformed gear-photo path is rejected'
);

select * from finish();
rollback;
