begin;

create extension if not exists pgtap with schema extensions;
select plan(21);

insert into auth.users (id, email) values
  ('40000001-0000-0000-0000-000000000001', 'squad-owner@example.test'),
  ('40000002-0000-0000-0000-000000000002', 'squad-member@example.test'),
  ('40000003-0000-0000-0000-000000000003', 'squad-outsider@example.test')
on conflict (id) do nothing;

insert into public.profiles (
  id, username, display_name, onboarding_completed_at
) values
  ('40000001-0000-0000-0000-000000000001', 'squad_owner', 'Squad Owner', now()),
  ('40000002-0000-0000-0000-000000000002', 'squad_member', 'Squad Member', now()),
  ('40000003-0000-0000-0000-000000000003', 'squad_outsider', 'Squad Outsider', now())
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;

-- Owner creates a squad; owner row is seated atomically.
set local role authenticated;
set local request.jwt.claim.sub = '40000001-0000-0000-0000-000000000001';
select lives_ok(
  $$select public.create_squad('Baseline Bashers')$$,
  'the caller can create a squad'
);
reset role;

select is(
  (select count(*)::integer from public.squads where name = 'Baseline Bashers'),
  1,
  'the squad row was created'
);
select is(
  (select role from public.squad_members
   where squad_id = (select id from public.squads where name = 'Baseline Bashers')
     and user_id = '40000001-0000-0000-0000-000000000001'),
  'owner',
  'the creator is seated as owner'
);

-- Outsider cannot read the roster before joining.
set local role authenticated;
set local request.jwt.claim.sub = '40000003-0000-0000-0000-000000000003';
select is(
  (select count(*)::integer from public.squad_members
   where squad_id = (select id from public.squads where name = 'Baseline Bashers')),
  0,
  'a non-member cannot read the squad roster'
);
select is(
  (select count(*)::integer from public.squads where name = 'Baseline Bashers'),
  0,
  'a non-member cannot read the squad row itself'
);
reset role;

-- A non-owner cannot insert a member row directly (bypassing the RPCs).
set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select throws_ok(
  $$insert into public.squad_members (squad_id, user_id, role, invited_by)
    values (
      (select id from public.squads where name = 'Baseline Bashers'),
      '40000002-0000-0000-0000-000000000002', 'member',
      '40000002-0000-0000-0000-000000000002'
    )$$,
  '42501',
  null,
  'a non-owner cannot self-insert into squad_members directly'
);
reset role;

-- Redeem the join code as a self-join path.
set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.redeem_squad_code(
      (select join_code from public.squads where name = 'Baseline Bashers')
    )$$,
  'a user can redeem a valid join code to self-join'
);
reset role;

select is(
  (select role from public.squad_members
   where squad_id = (select id from public.squads where name = 'Baseline Bashers')
     and user_id = '40000002-0000-0000-0000-000000000002'),
  'member',
  'code redemption seats the caller as a member'
);

set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.redeem_squad_code('NOTREAL')$$,
  'P0001',
  'invalid_code',
  'redeeming a bogus code raises invalid_code'
);
reset role;

-- Now that they're a member, the roster and squad row are readable.
set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.squad_members
   where squad_id = (select id from public.squads where name = 'Baseline Bashers')),
  2,
  'a member can read the full roster'
);
reset role;

-- invite_to_squad is owner-only.
set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.invite_to_squad(
      (select id from public.squads where name = 'Baseline Bashers'),
      '40000003-0000-0000-0000-000000000003'
    )$$,
  'P0001',
  'not_owner',
  'a non-owner cannot directly invite a member'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '40000001-0000-0000-0000-000000000001';
select lives_ok(
  $$select public.invite_to_squad(
      (select id from public.squads where name = 'Baseline Bashers'),
      '40000003-0000-0000-0000-000000000003'
    )$$,
  'the owner can directly invite an existing user'
);
reset role;

select is(
  (select count(*)::integer
   from public.notifications
   where user_id = '40000003-0000-0000-0000-000000000003'
     and type = 'squad_invite'),
  1,
  'a direct invite fires a squad_invite notification'
);
select is(
  (select count(*)::integer
   from public.notifications
   where user_id = '40000001-0000-0000-0000-000000000001'
     and type = 'squad_invite'),
  0,
  'the owner is not notified for their own bootstrap membership'
);

-- squad_leaderboard is member-scoped and rejects non-members.
set local role authenticated;
set local request.jwt.claim.sub = '40000003-0000-0000-0000-000000000003';
select is(
  (select count(*)::integer from public.squad_leaderboard(
    (select id from public.squads where name = 'Baseline Bashers')
  )),
  3,
  'a member sees every squad member on the leaderboard'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '40000002-0000-0000-0000-000000000002';
select lives_ok(
  $$delete from public.squad_members
    where squad_id = (select id from public.squads where name = 'Baseline Bashers')
      and user_id = '40000002-0000-0000-0000-000000000002'$$,
  'a member can remove their own row to leave the squad'
);
reset role;

select is(
  (select count(*)::integer from public.squad_members
   where squad_id = (select id from public.squads where name = 'Baseline Bashers')
     and user_id = '40000002-0000-0000-0000-000000000002'),
  0,
  'leaving removes the membership row'
);

-- Owner can remove another member; a member cannot remove others.
set local role authenticated;
set local request.jwt.claim.sub = '40000003-0000-0000-0000-000000000003';
select throws_ok(
  $$delete from public.squad_members
    where squad_id = (select id from public.squads where name = 'Baseline Bashers')
      and user_id = '40000001-0000-0000-0000-000000000001'$$,
  '42501',
  null,
  'a member cannot remove another member (including the owner)'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '40000001-0000-0000-0000-000000000001';
select lives_ok(
  $$delete from public.squad_members
    where squad_id = (select id from public.squads where name = 'Baseline Bashers')
      and user_id = '40000003-0000-0000-0000-000000000003'$$,
  'the owner can remove another member'
);
reset role;

select ok(
  has_function_privilege('authenticated', 'public.create_squad(text)', 'EXECUTE'),
  'authenticated clients can execute create_squad'
);
select ok(
  has_function_privilege('authenticated', 'public.redeem_squad_code(text)', 'EXECUTE'),
  'authenticated clients can execute redeem_squad_code'
);

select * from finish();
rollback;
