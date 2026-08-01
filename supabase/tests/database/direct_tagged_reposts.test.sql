begin;

create extension if not exists pgtap with schema extensions;
select plan(44);

insert into auth.users (id, email) values
  ('10000001-0000-0000-0000-000000000001', 'repost-author@example.test'),
  ('10000002-0000-0000-0000-000000000002', 'repost-player@example.test'),
  ('10000003-0000-0000-0000-000000000003', 'repost-third@example.test'),
  ('10000004-0000-0000-0000-000000000004', 'repost-untagged@example.test')
on conflict (id) do nothing;

insert into public.profiles (
  id, username, display_name, onboarding_completed_at
) values
  ('10000001-0000-0000-0000-000000000001', 'repost_author', 'Repost Author', now()),
  ('10000002-0000-0000-0000-000000000002', 'repost_player', 'Repost Player', now()),
  ('10000003-0000-0000-0000-000000000003', 'repost_third', 'Repost Third', now()),
  ('10000004-0000-0000-0000-000000000004', 'repost_untagged', 'Repost Untagged', now())
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;

insert into public.follows (follower_id, followee_id, status) values
  ('10000001-0000-0000-0000-000000000001', '10000002-0000-0000-0000-000000000002', 'accepted'),
  ('10000002-0000-0000-0000-000000000002', '10000001-0000-0000-0000-000000000001', 'accepted'),
  ('10000001-0000-0000-0000-000000000001', '10000003-0000-0000-0000-000000000003', 'accepted'),
  ('10000003-0000-0000-0000-000000000003', '10000001-0000-0000-0000-000000000001', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

insert into public.sessions (
  id, user_id, title, duration_minutes, posted, started_at, ended_at
) values (
  '20000000-0000-0000-0000-000000000001',
  '10000001-0000-0000-0000-000000000001',
  'Perspective fixture',
  60,
  true,
  '2026-07-17 12:00:00+00',
  '2026-07-17 13:00:00+00'
);

insert into public.session_activities (
  id, session_id, kind, position, team_score, opponent_score, won
) values
  -- Reposting player is the author's partner: a win for both players.
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'match', 0, 11, 7, true),
  -- Reposting player is the author's opponent: initially a win for the player.
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'match', 1, 5, 11, false),
  -- Ties remain neutral for every perspective.
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'match', 2, 9, 9, null),
  -- The reposting player did not play this match.
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', 'match', 3, 11, 4, true);

insert into public.activity_participants (
  activity_id, session_id, profile_id, role
) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000002-0000-0000-0000-000000000002', 'partner'),
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000003-0000-0000-0000-000000000003', 'opponent'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', '10000002-0000-0000-0000-000000000002', 'opponent'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', '10000003-0000-0000-0000-000000000003', 'partner'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', '10000002-0000-0000-0000-000000000002', 'opponent'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', '10000003-0000-0000-0000-000000000003', 'partner'),
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', '10000003-0000-0000-0000-000000000003', 'opponent'),
  -- Tagged, but not a mutual friend of the author: no automatic credit.
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', '10000004-0000-0000-0000-000000000004', 'partner');

delete from public.notifications
where session_id = '20000000-0000-0000-0000-000000000001';

select is(
  (select posted from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  false,
  'a tagged mutual friend is credited privately without taking action'
);

select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000004-0000-0000-0000-000000000004'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'a tagged non-mutual player is not credited automatically'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  1,
  'the credited player can read their private workout credit'
);

set local request.jwt.claim.sub = '10000004-0000-0000-0000-000000000004';
select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'another player cannot read the private workout credit'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'a tagged player can repost immediately'
);
reset role;

select is(
  (select count(*)::integer
   from public.notifications n
   join public.sessions wrapper on wrapper.id = n.session_id
   where wrapper.user_id = '10000002-0000-0000-0000-000000000002'
     and wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'
     and n.type = 'repost'
     and n.actor_id = '10000002-0000-0000-0000-000000000002'
     and n.user_id = '10000001-0000-0000-0000-000000000001'),
  1,
  'the author is notified when the tagged player publishes a repost'
);

select is(
  (select posted from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  true,
  'direct reposting promotes the private credit to a public repost'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.unrepost_session(
      (select id from public.sessions
       where user_id = '10000002-0000-0000-0000-000000000002'
         and reposted_from = '20000000-0000-0000-0000-000000000001')
    )$$,
  'a player can remove their public repost without deleting the workout credit'
);
reset role;

select is(
  (select posted from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  false,
  'removing a repost keeps the wrapper private'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'the private credit can be reposted again without approval'
);
reset role;

select is(
  (select count(*)::integer
   from public.notifications n
   join public.sessions wrapper on wrapper.id = n.session_id
   where wrapper.user_id = '10000002-0000-0000-0000-000000000002'
     and wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'
     and n.type = 'repost'),
  2,
  'republishing after an unrepost notifies the author again'
);

select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  1,
  'one repost wrapper is created'
);

select is(
  (select count(*)::integer
   from public.session_activities sa
   join public.sessions wrapper on wrapper.id = sa.session_id
   where wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'a repost wrapper contains no copied activities'
);

select is(
  (select count(*)::integer from public.session_activities
   where session_id = '20000000-0000-0000-0000-000000000001'),
  4,
  'the canonical source retains every post activity'
);

select is(
  (select source.title
   from public.sessions wrapper
   join public.sessions source on source.id = wrapper.reposted_from
   where wrapper.user_id = '10000002-0000-0000-0000-000000000002'),
  'Perspective fixture',
  'the wrapper resolves to the complete original post'
);

select is(
  (select count(*)::integer
   from public.notifications n
   join public.sessions wrapper on wrapper.id = n.session_id
   where wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'
     and n.type in ('tag', 'rivalry')),
  0,
  'wrapper creation emits no tag or rivalry notifications'
);

select is(
  (select count(*)::integer
   from public.notifications n
   join public.sessions wrapper on wrapper.id = n.session_id
   where wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'
     and n.type = 'repost_approved'),
  0,
  'direct reposts emit no approval notification'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select is(
  (select wins from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  2,
  'leaderboard counts both player-perspective wins'
);
select is(
  (select losses from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  0,
  'leaderboard does not reverse the opponent result incorrectly'
);
select is(
  (select matches from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  2,
  'leaderboard excludes ties and matches the player did not play'
);
reset role;

-- A source edit is reflected dynamically without rebuilding the repost.
update public.session_activities
set team_score = 11, opponent_score = 4, won = true
where id = '30000000-0000-0000-0000-000000000002';

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select is(
  (select wins from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  1,
  'source edits immediately update projected wins'
);
select is(
  (select losses from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  1,
  'source edits immediately update projected losses'
);
select is(
  (select matches from public.crew_leaderboard()
   where user_id = '10000002-0000-0000-0000-000000000002'),
  2,
  'source edits do not change the relevant match count'
);

select lives_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'a duplicate tap is idempotent'
);
reset role;

select is(
  (select count(*)::integer
   from public.notifications n
   join public.sessions wrapper on wrapper.id = n.session_id
   where wrapper.user_id = '10000002-0000-0000-0000-000000000002'
     and wrapper.reposted_from = '20000000-0000-0000-0000-000000000001'
     and n.type = 'repost'),
  2,
  'a duplicate tap does not create a second notification'
);

select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  1,
  'a duplicate tap does not create a second wrapper'
);

-- Wrapper content cannot be edited through authenticated RLS.
set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
update public.sessions
set title = 'Tampered repost'
where user_id = '10000002-0000-0000-0000-000000000002'
  and reposted_from = '20000000-0000-0000-0000-000000000001';
reset role;
select is(
  (select title from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  'Perspective fixture',
  'repost wrapper metadata is immutable'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select throws_ok(
  $$insert into public.session_activities (session_id, kind, position)
    select id, 'match', 99 from public.sessions
    where user_id = '10000002-0000-0000-0000-000000000002'
      and reposted_from = '20000000-0000-0000-0000-000000000001'$$,
  '42501',
  'new row violates row-level security policy for table "session_activities"',
  'authenticated clients cannot add activities to a wrapper'
);

set local request.jwt.claim.sub = '10000004-0000-0000-0000-000000000004';
select throws_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'P0001',
  'Only mutual friends can repost without approval',
  'a tagged non-mutual player cannot repost directly'
);

set local request.jwt.claim.sub = '10000003-0000-0000-0000-000000000003';
select throws_ok(
  $$select public.repost_session(
      (select id from public.sessions
       where user_id = '10000002-0000-0000-0000-000000000002'
         and reposted_from = '20000000-0000-0000-0000-000000000001')
    )$$,
  'P0001',
  'Reposted sessions cannot be reposted again',
  'a repost wrapper cannot be reposted again'
);
reset role;

select ok(
  not has_table_privilege('authenticated', 'public.repost_requests', 'INSERT'),
  'authenticated clients cannot create approval requests'
);
select ok(
  to_regprocedure('public.approve_repost(uuid)') is null,
  'the approval RPC is retired'
);
select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'repost_session'),
  false,
  'the exposed repost RPC is security invoker'
);
select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'crew_leaderboard'),
  false,
  'the exposed leaderboard RPC is security invoker'
);
select ok(
  has_function_privilege('authenticated', 'public.repost_session(uuid)', 'EXECUTE'),
  'authenticated clients can execute the direct repost RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.crew_leaderboard()', 'EXECUTE'),
  'authenticated clients can execute the projected leaderboard RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.repost_source(public.sessions)', 'EXECUTE'),
  'authenticated reads can embed the canonical repost source'
);

-- Blocking the original author removes the relationship wrapper.
set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select lives_ok(
  $$insert into public.blocks (blocker_id, blocked_id)
    values ('10000002-0000-0000-0000-000000000002',
            '10000001-0000-0000-0000-000000000001')$$,
  'blocking the original author succeeds'
);
reset role;
select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'blocking removes the repost wrapper'
);

delete from public.blocks
where blocker_id = '10000002-0000-0000-0000-000000000002'
  and blocked_id = '10000001-0000-0000-0000-000000000001';

insert into public.follows (follower_id, followee_id, status) values
  ('10000001-0000-0000-0000-000000000001', '10000002-0000-0000-0000-000000000002', 'accepted'),
  ('10000002-0000-0000-0000-000000000002', '10000001-0000-0000-0000-000000000001', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

set local role authenticated;
set local request.jwt.claim.sub = '10000002-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'the tagged player can repost again after reconnecting as mutual friends'
);
select is(
  public.remove_self_from_session('20000000-0000-0000-0000-000000000001'),
  3,
  'self-removal deletes every one of the player tags'
);
reset role;
select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000002-0000-0000-0000-000000000002'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'removing the final tag removes the repost wrapper'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000003-0000-0000-0000-000000000003';
select lives_ok(
  $$select public.repost_session('20000000-0000-0000-0000-000000000001')$$,
  'another tagged player can create a wrapper'
);
reset role;

delete from public.sessions
where id = '20000000-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.sessions
   where user_id = '10000003-0000-0000-0000-000000000003'
     and reposted_from = '20000000-0000-0000-0000-000000000001'),
  0,
  'deleting the canonical source cascades to its repost wrappers'
);

select * from finish();
rollback;
