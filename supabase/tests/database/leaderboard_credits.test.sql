begin;

create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values
  ('80000001-0000-0000-0000-000000000001', 'board-author@example.test'),
  ('80000002-0000-0000-0000-000000000002', 'board-opponent@example.test'),
  ('80000003-0000-0000-0000-000000000003', 'board-partner@example.test')
on conflict (id) do nothing;

insert into public.profiles (
  id, username, display_name, onboarding_completed_at
) values
  ('80000001-0000-0000-0000-000000000001', 'board_author', 'Board Author', now()),
  ('80000002-0000-0000-0000-000000000002', 'board_opponent', 'Board Opponent', now()),
  ('80000003-0000-0000-0000-000000000003', 'board_partner', 'Board Partner', now())
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;

-- All three are mutual friends, so tagged matches earn automatic credits.
insert into public.follows (follower_id, followee_id, status) values
  ('80000001-0000-0000-0000-000000000001', '80000002-0000-0000-0000-000000000002', 'accepted'),
  ('80000002-0000-0000-0000-000000000002', '80000001-0000-0000-0000-000000000001', 'accepted'),
  ('80000001-0000-0000-0000-000000000001', '80000003-0000-0000-0000-000000000003', 'accepted'),
  ('80000003-0000-0000-0000-000000000003', '80000001-0000-0000-0000-000000000001', 'accepted'),
  ('80000002-0000-0000-0000-000000000002', '80000003-0000-0000-0000-000000000003', 'accepted'),
  ('80000003-0000-0000-0000-000000000003', '80000002-0000-0000-0000-000000000002', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

-- The author wins 11-6 with a partner against an opponent, and ties a second
-- match. Ties count for nobody.
insert into public.sessions (
  id, user_id, title, duration_minutes, posted, started_at, ended_at
) values (
  '90000000-0000-0000-0000-000000000001',
  '80000001-0000-0000-0000-000000000001',
  'Leaderboard fixture', 60, true,
  now() - interval '2 days', now() - interval '2 days' + interval '1 hour'
);

insert into public.session_activities (
  id, session_id, kind, position, team_score, opponent_score, won
) values
  ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', 'match', 0, 11, 6, true),
  ('91000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000001', 'match', 1, 9, 9, null);

insert into public.activity_participants (
  activity_id, session_id, profile_id, role
) values
  ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '80000003-0000-0000-0000-000000000003', 'partner'),
  ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '80000002-0000-0000-0000-000000000002', 'opponent'),
  ('91000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000001', '80000002-0000-0000-0000-000000000002', 'opponent');

-- A private session of the author's: counts for them, hidden from the crew.
insert into public.sessions (
  id, user_id, title, duration_minutes, posted, started_at, ended_at
) values (
  '90000000-0000-0000-0000-000000000002',
  '80000001-0000-0000-0000-000000000001',
  'Private loss', 45, false,
  now() - interval '1 day', now() - interval '1 day' + interval '45 minutes'
);

insert into public.session_activities (
  id, session_id, kind, position, team_score, opponent_score, won
) values
  ('91000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-000000000002', 'match', 0, 4, 11, false);

-- --------------------------------------------------------------------------
-- The credited players' perspectives
-- --------------------------------------------------------------------------

select is(
  (select count(*)::integer from public.sessions
   where user_id = '80000002-0000-0000-0000-000000000002'
     and reposted_from = '90000000-0000-0000-0000-000000000001'),
  1,
  'the tagged opponent is credited (fixture precondition)'
);

set local role authenticated;
set local request.jwt.claim.sub = '80000002-0000-0000-0000-000000000002';

select results_eq(
  $$select wins, losses, matches from public.crew_leaderboard('all')
    where user_id = '80000002-0000-0000-0000-000000000002'$$,
  $$values (0, 1, 1)$$,
  'a tagged opponent carries the loss, flipped from the author''s win'
);

select results_eq(
  $$select wins, losses, matches from public.crew_leaderboard('all')
    where user_id = '80000003-0000-0000-0000-000000000003'$$,
  $$values (1, 0, 1)$$,
  'a tagged partner carries the win unflipped'
);

select results_eq(
  $$select wins, losses, matches from public.crew_leaderboard('all')
    where user_id = '80000001-0000-0000-0000-000000000001'$$,
  $$values (1, 0, 1)$$,
  'the author''s private loss is hidden from the crew'
);

-- --------------------------------------------------------------------------
-- The author's own view
-- --------------------------------------------------------------------------

set local request.jwt.claim.sub = '80000001-0000-0000-0000-000000000001';

select results_eq(
  $$select wins, losses, matches from public.crew_leaderboard('all')
    where user_id = '80000001-0000-0000-0000-000000000001'$$,
  $$values (1, 1, 2)$$,
  'the author sees their own private loss in their own row'
);

select is(
  (select matches from public.crew_leaderboard('all')
   where user_id = '80000001-0000-0000-0000-000000000001'),
  2,
  'the tie counts for nobody'
);

-- --------------------------------------------------------------------------
-- Period filter and zero rows
-- --------------------------------------------------------------------------

select is(
  (select matches from public.crew_leaderboard('month')
   where user_id = '80000002-0000-0000-0000-000000000002'),
  (select case when date_trunc('month', now() - interval '2 days')
                 = date_trunc('month', now()) then 1 else 0 end)::int,
  'the month window applies to credited matches too'
);

insert into auth.users (id, email) values
  ('80000004-0000-0000-0000-000000000004', 'board-idle@example.test')
on conflict (id) do nothing;
insert into public.profiles (id, username, display_name, onboarding_completed_at)
values ('80000004-0000-0000-0000-000000000004', 'board_idle', 'Board Idle', now())
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;
insert into public.follows (follower_id, followee_id, status)
values ('80000001-0000-0000-0000-000000000001', '80000004-0000-0000-0000-000000000004', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

select results_eq(
  $$select wins, losses, matches from public.crew_leaderboard('all')
    where user_id = '80000004-0000-0000-0000-000000000004'$$,
  $$values (0, 0, 0)$$,
  'a crew member with no matches still appears, at 0-0'
);

reset role;
select * from finish();
rollback;
