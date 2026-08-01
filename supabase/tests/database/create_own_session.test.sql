begin;

create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, email) values
  ('40000001-0000-0000-0000-000000000001', 'create-owner@example.test'),
  ('40000002-0000-0000-0000-000000000002', 'create-friend@example.test'),
  ('40000003-0000-0000-0000-000000000003', 'create-pending@example.test')
on conflict (id) do nothing;

-- The pending user has never finished onboarding: tagging them must be refused.
insert into public.profiles (
  id, username, display_name, onboarding_completed_at
) values
  ('40000001-0000-0000-0000-000000000001', 'create_owner', 'Create Owner', now()),
  ('40000002-0000-0000-0000-000000000002', 'create_friend', 'Create Friend', now()),
  ('40000003-0000-0000-0000-000000000003', 'create_pending', 'Create Pending', null)
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;

insert into public.follows (follower_id, followee_id, status) values
  ('40000001-0000-0000-0000-000000000001', '40000002-0000-0000-0000-000000000002', 'accepted'),
  ('40000002-0000-0000-0000-000000000002', '40000001-0000-0000-0000-000000000001', 'accepted')
on conflict (follower_id, followee_id) do update set status = excluded.status;

set local role authenticated;
set local request.jwt.claim.sub = '40000001-0000-0000-0000-000000000001';

-- --------------------------------------------------------------------------
-- Validation
-- --------------------------------------------------------------------------

select throws_ok(
  $$select public.create_own_session(jsonb_build_object(
      'id', '50000000-0000-0000-0000-000000000001',
      'title', 'No activities',
      'duration_minutes', 30,
      'posted', true,
      'activities', '[]'::jsonb
  ))$$,
  'A session must contain at least one activity',
  'a session with no activities is rejected'
);

select is(
  (select count(*)::integer from public.sessions
   where id = '50000000-0000-0000-0000-000000000001'),
  0,
  'the rejected session leaves no row behind'
);

select throws_ok(
  $$select public.create_own_session(jsonb_build_object(
      'id', '50000000-0000-0000-0000-000000000002',
      'title', 'Bad tag',
      'duration_minutes', 30,
      'posted', true,
      'activities', jsonb_build_array(jsonb_build_object(
        'id', '60000000-0000-0000-0000-000000000002',
        'kind', 'match', 'position', 0,
        'team_score', 11, 'opponent_score', 9, 'won', true,
        'participants', jsonb_build_array(jsonb_build_object(
          'id', '70000000-0000-0000-0000-000000000002',
          'profile_id', '40000003-0000-0000-0000-000000000003',
          'role', 'opponent'
        ))
      ))
  ))$$,
  'Tagged player not found',
  'tagging a profile that has not finished onboarding is rejected'
);

-- The activity is written before the participant that fails, so this also
-- proves the whole call is one transaction rather than a partial write.
select is(
  (select count(*)::integer from public.sessions
   where id = '50000000-0000-0000-0000-000000000002'),
  0,
  'a failed participant rolls back the session and its activities'
);

select is(
  (select count(*)::integer from public.session_activities
   where id = '60000000-0000-0000-0000-000000000002'),
  0,
  'no orphaned activity survives the rollback'
);

-- --------------------------------------------------------------------------
-- Happy path
-- --------------------------------------------------------------------------

select lives_ok(
  $$select public.create_own_session(jsonb_build_object(
      'id', '50000000-0000-0000-0000-000000000003',
      'title', 'Evening Session',
      'location', '  Capital City Pickleball  ',
      'takeaway', 'Third-shot drops landed',
      'duration_minutes', 75,
      'posted', true,
      'started_at', '2026-07-20 18:00:00+00',
      'ended_at', '2026-07-20 19:15:00+00',
      'average_heart_rate_bpm', 132,
      'active_calories_kcal', 410,
      'activities', jsonb_build_array(
        jsonb_build_object(
          'id', '60000000-0000-0000-0000-000000000003',
          'kind', 'match', 'position', 0,
          'team_score', 11, 'opponent_score', 9, 'won', true,
          'participants', '[]'::jsonb
        ),
        jsonb_build_object(
          'id', '60000000-0000-0000-0000-000000000004',
          'kind', 'match', 'position', 1,
          'team_score', 11, 'opponent_score', 6, 'won', true,
          'participants', jsonb_build_array(
            jsonb_build_object(
              'id', '70000000-0000-0000-0000-000000000003',
              'profile_id', '40000002-0000-0000-0000-000000000002',
              'role', 'opponent'
            ),
            jsonb_build_object(
              'id', '70000000-0000-0000-0000-000000000004',
              'guest_name', '  Sam  ',
              'role', 'partner'
            )
          )
        )
      )
  ))$$,
  'a full session writes in one call'
);

select results_eq(
  $$select title, location, takeaway, duration_minutes, posted,
           average_heart_rate_bpm, active_calories_kcal
    from public.sessions where id = '50000000-0000-0000-0000-000000000003'$$,
  $$values ('Evening Session', 'Capital City Pickleball', 'Third-shot drops landed',
            75, true, 132::smallint, 410)$$,
  'session columns are trimmed'
);

select is(
  (select count(*)::integer from public.session_activities
   where session_id = '50000000-0000-0000-0000-000000000003'),
  2,
  'both activities are written'
);

select results_eq(
  $$select role, profile_id, guest_name
    from public.activity_participants
    where session_id = '50000000-0000-0000-0000-000000000003'
    order by role$$,
  $$values ('opponent', '40000002-0000-0000-0000-000000000002'::uuid, null::text),
           ('partner', null::uuid, 'Sam')$$,
  'members are tagged by profile, guests by trimmed name'
);

-- Ordering check: the credit trigger is `after insert or update of posted`, so
-- it only creates credits if `posted` flips after the participants are written.
select is(
  (select count(*)::integer from public.sessions
   where user_id = '40000002-0000-0000-0000-000000000002'
     and reposted_from = '50000000-0000-0000-0000-000000000003'),
  1,
  'a tagged mutual friend is credited, proving posted flips last'
);

-- Repeating the same client-generated id models a lost HTTP response followed
-- by a retry. It must resolve to the committed write rather than duplicating it.
select lives_ok(
  $$select public.create_own_session(jsonb_build_object(
      'id', '50000000-0000-0000-0000-000000000003',
      'duration_minutes', 75,
      'posted', true,
      'activities', jsonb_build_array(jsonb_build_object(
        'id', '60000000-0000-0000-0000-000000000003',
        'kind', 'match', 'position', 0
      ))
  ))$$,
  'retrying a committed client id succeeds'
);

select results_eq(
  $$select
      (select count(*)::int from public.sessions
       where id = '50000000-0000-0000-0000-000000000003'),
      (select count(*)::int from public.session_activities
       where session_id = '50000000-0000-0000-0000-000000000003')$$,
  $$values (1, 2)$$,
  'an idempotent retry creates neither a duplicate session nor duplicate activities'
);

-- --------------------------------------------------------------------------
-- Private sessions
-- --------------------------------------------------------------------------

select lives_ok(
  $$select public.create_own_session(jsonb_build_object(
      'id', '50000000-0000-0000-0000-000000000004',
      'duration_minutes', 20,
      'posted', false,
      'activities', jsonb_build_array(jsonb_build_object(
        'id', '60000000-0000-0000-0000-000000000005',
        'kind', 'match', 'position', 0,
        'team_score', 9, 'opponent_score', 11, 'won', false,
        'participants', jsonb_build_array(jsonb_build_object(
          'id', '70000000-0000-0000-0000-000000000005',
          'profile_id', '40000002-0000-0000-0000-000000000002',
          'role', 'opponent'
        ))
      ))
  ))$$,
  'an unposted session is accepted'
);

select is(
  (select posted from public.sessions
   where id = '50000000-0000-0000-0000-000000000004'),
  false,
  'posted = false is honoured rather than defaulting to public'
);

select is(
  (select count(*)::integer from public.sessions
   where user_id = '40000002-0000-0000-0000-000000000002'
     and reposted_from = '50000000-0000-0000-0000-000000000004'),
  0,
  'a private session credits nobody'
);

reset role;
select * from finish();
rollback;
