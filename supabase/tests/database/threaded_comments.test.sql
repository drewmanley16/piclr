begin;

create extension if not exists pgtap with schema extensions;
select plan(31);

insert into auth.users (id, email) values
  ('71000001-0000-0000-0000-000000000001', 'thread-owner@example.test'),
  ('71000002-0000-0000-0000-000000000002', 'thread-commenter@example.test'),
  ('71000003-0000-0000-0000-000000000003', 'thread-replier@example.test')
on conflict (id) do nothing;

insert into public.profiles (
  id, username, display_name, onboarding_completed_at
) values
  ('71000001-0000-0000-0000-000000000001', 'thread_owner', 'Thread Owner', now()),
  ('71000002-0000-0000-0000-000000000002', 'thread_commenter', 'Thread Commenter', now()),
  ('71000003-0000-0000-0000-000000000003', 'thread_replier', 'Thread Replier', now())
on conflict (id) do update set onboarding_completed_at = excluded.onboarding_completed_at;

insert into public.follows (follower_id, followee_id, status) values
  (
    '71000002-0000-0000-0000-000000000002',
    '71000001-0000-0000-0000-000000000001',
    'accepted'
  ),
  (
    '71000003-0000-0000-0000-000000000003',
    '71000001-0000-0000-0000-000000000001',
    'accepted'
  )
on conflict (follower_id, followee_id) do update set status = excluded.status;

insert into public.sessions (
  id, user_id, title, duration_minutes, posted, started_at, ended_at
) values
  (
    '72000000-0000-0000-0000-000000000001',
    '71000001-0000-0000-0000-000000000001',
    'Thread fixture', 60, true, now() - interval '1 hour', now()
  ),
  (
    '72000000-0000-0000-0000-000000000002',
    '71000001-0000-0000-0000-000000000001',
    'Other thread fixture', 45, true, now() - interval '1 hour', now()
  );

select has_column('public', 'comments', 'parent_id', 'comments have a parent reference');
select has_column('public', 'comments', 'deleted_at', 'comments support deletion placeholders');
select has_table('public', 'comment_likes', 'comment likes table exists');

set local role authenticated;
set local request.jwt.claim.sub = '71000002-0000-0000-0000-000000000002';
select lives_ok(
  $$insert into public.comments (id, user_id, session_id, body)
    values (
      '73000000-0000-0000-0000-000000000001',
      '71000002-0000-0000-0000-000000000002',
      '72000000-0000-0000-0000-000000000001',
      'Great session'
    )$$,
  'an authenticated viewer can add a top-level comment'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '71000003-0000-0000-0000-000000000003';
select lives_ok(
  $$insert into public.comments (id, user_id, session_id, parent_id, body)
    values (
      '73000000-0000-0000-0000-000000000002',
      '71000003-0000-0000-0000-000000000003',
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000001',
      '@thread_commenter absolutely'
    )$$,
  'a reply can target a top-level comment in the same session'
);

select throws_ok(
  $$insert into public.comments (user_id, session_id, parent_id, body)
    values (
      '71000003-0000-0000-0000-000000000003',
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000002',
      'Nested reply'
    )$$,
  'P0001',
  'Replies may only target top-level comments',
  'replies cannot nest below another reply'
);

select throws_ok(
  $$insert into public.comments (user_id, session_id, parent_id, body)
    values (
      '71000003-0000-0000-0000-000000000003',
      '72000000-0000-0000-0000-000000000002',
      '73000000-0000-0000-0000-000000000001',
      'Cross-session reply'
    )$$,
  'P0001',
  'Reply must belong to the same session',
  'a reply cannot cross session boundaries'
);
reset role;

select is(
  (select count(*)::integer from public.notifications
   where user_id = '71000001-0000-0000-0000-000000000001'
     and actor_id = '71000003-0000-0000-0000-000000000003'
     and type = 'comment'
     and comment_id = '73000000-0000-0000-0000-000000000002'),
  1,
  'the session owner receives one notification for a reply'
);

select is(
  (select count(*)::integer from public.notifications
   where user_id = '71000002-0000-0000-0000-000000000002'
     and actor_id = '71000003-0000-0000-0000-000000000003'
     and type = 'comment_reply'
     and comment_id = '73000000-0000-0000-0000-000000000002'),
  1,
  'the parent author receives one reply notification'
);

select is(
  (select count(*)::integer from public.notifications
   where actor_id = '71000003-0000-0000-0000-000000000003'
     and comment_id = '73000000-0000-0000-0000-000000000002'
     and type = 'mention'),
  0,
  'a reply mention is deduplicated against reply and session notifications'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000001-0000-0000-0000-000000000001';
select lives_ok(
  $$insert into public.comment_likes (comment_id, user_id)
    values (
      '73000000-0000-0000-0000-000000000001',
      '71000001-0000-0000-0000-000000000001'
    )$$,
  'a viewer can like a visible comment'
);
reset role;

select is(
  (select session_id from public.comment_likes
   where comment_id = '73000000-0000-0000-0000-000000000001'
     and user_id = '71000001-0000-0000-0000-000000000001'),
  '72000000-0000-0000-0000-000000000001'::uuid,
  'the like trigger derives the session id from its comment'
);

select is(
  (select count(*)::integer from public.notifications
   where user_id = '71000002-0000-0000-0000-000000000002'
     and actor_id = '71000001-0000-0000-0000-000000000001'
     and type = 'comment_like'
     and comment_id = '73000000-0000-0000-0000-000000000001'),
  1,
  'liking a comment notifies its author'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000001-0000-0000-0000-000000000001';
select throws_ok(
  $$insert into public.comment_likes (comment_id, user_id)
    values (
      '73000000-0000-0000-0000-000000000001',
      '71000001-0000-0000-0000-000000000001'
    )$$,
  '23505',
  null,
  'a user cannot like the same comment twice'
);

select throws_ok(
  $$insert into public.comment_likes (comment_id, user_id)
    values (
      '73000000-0000-0000-0000-000000000002',
      '71000002-0000-0000-0000-000000000002'
    )$$,
  '42501',
  'new row violates row-level security policy for table "comment_likes"',
  'a user cannot create a like for another account'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '71000002-0000-0000-0000-000000000002';
select lives_ok(
  $$insert into public.comment_likes (comment_id, user_id)
    values (
      '73000000-0000-0000-0000-000000000001',
      '71000002-0000-0000-0000-000000000002'
    )$$,
  'an author may like their own comment without a notification'
);
reset role;

select is(
  (select count(*)::integer from public.notifications
   where user_id = '71000002-0000-0000-0000-000000000002'
     and actor_id = '71000002-0000-0000-0000-000000000002'
     and type = 'comment_like'),
  0,
  'self-likes do not create notifications'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000002-0000-0000-0000-000000000002';
select lives_ok(
  $$delete from public.comments
    where id = '73000000-0000-0000-0000-000000000001'$$,
  'deleting a parent with replies succeeds'
);
reset role;

select is(
  (select count(*)::integer from public.comments
   where id = '73000000-0000-0000-0000-000000000001'
     and deleted_at is not null
     and body = ''),
  1,
  'a deleted parent is retained as a content-cleared placeholder'
);

select is(
  (select count(*)::integer from public.comments
   where id = '73000000-0000-0000-0000-000000000002'
     and parent_id = '73000000-0000-0000-0000-000000000001'),
  1,
  'replies remain attached to a deleted parent'
);

select is(
  (select count(*)::integer from public.comment_likes
   where comment_id = '73000000-0000-0000-0000-000000000001'),
  0,
  'soft deletion removes the parent comment likes'
);

select is(
  (select count(*)::integer from public.notifications
   where comment_id = '73000000-0000-0000-0000-000000000001'),
  0,
  'soft deletion removes notifications targeting the parent'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000003-0000-0000-0000-000000000003';
select throws_ok(
  $$insert into public.comments (user_id, session_id, parent_id, body)
    values (
      '71000003-0000-0000-0000-000000000003',
      '72000000-0000-0000-0000-000000000001',
      '73000000-0000-0000-0000-000000000001',
      'Too late'
    )$$,
  'P0001',
  'Cannot reply to a deleted comment',
  'new replies cannot target a deleted placeholder'
);

select lives_ok(
  $$delete from public.comments
    where id = '73000000-0000-0000-0000-000000000002'$$,
  'a reply can be hard deleted normally'
);
reset role;

select is(
  (select count(*)::integer from public.comments
   where id = '73000000-0000-0000-0000-000000000002'),
  0,
  'a deleted reply is removed rather than rendered as a placeholder'
);

-- A placeholder that still anchors replies must survive; once the last reply is
-- deleted it should be reaped. Built on the second fixture session so none of the
-- assertions above are disturbed.
set local role authenticated;
set local request.jwt.claim.sub = '71000002-0000-0000-0000-000000000002';
insert into public.comments (id, user_id, session_id, body) values
  (
    '73000000-0000-0000-0000-000000000003',
    '71000002-0000-0000-0000-000000000002',
    '72000000-0000-0000-0000-000000000002',
    'Second thread root'
  );
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '71000003-0000-0000-0000-000000000003';
insert into public.comments (id, user_id, session_id, parent_id, body) values
  (
    '73000000-0000-0000-0000-000000000004',
    '71000003-0000-0000-0000-000000000003',
    '72000000-0000-0000-0000-000000000002',
    '73000000-0000-0000-0000-000000000003',
    'First reply'
  ),
  (
    '73000000-0000-0000-0000-000000000005',
    '71000003-0000-0000-0000-000000000003',
    '72000000-0000-0000-0000-000000000002',
    '73000000-0000-0000-0000-000000000003',
    'Second reply'
  );
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '71000002-0000-0000-0000-000000000002';
delete from public.comments where id = '73000000-0000-0000-0000-000000000003';
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '71000003-0000-0000-0000-000000000003';
delete from public.comments where id = '73000000-0000-0000-0000-000000000004';
reset role;

select is(
  (select count(*)::integer from public.comments
   where id = '73000000-0000-0000-0000-000000000003'),
  1,
  'a placeholder survives while any reply remains'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000003-0000-0000-0000-000000000003';
delete from public.comments where id = '73000000-0000-0000-0000-000000000005';
reset role;

select is(
  (select count(*)::integer from public.comments
   where id = '73000000-0000-0000-0000-000000000003'),
  0,
  'the placeholder is reaped once its last reply is deleted'
);

set local role authenticated;
set local request.jwt.claim.sub = '71000001-0000-0000-0000-000000000001';
select lives_ok(
  $$delete from public.sessions
    where id = '72000000-0000-0000-0000-000000000001'$$,
  'deleting the session hard-cascades through retained placeholders'
);
reset role;

select is(
  (select count(*)::integer from public.comments
   where session_id = '72000000-0000-0000-0000-000000000001'),
  0,
  'session deletion leaves no comment placeholders behind'
);

select ok(
  not has_table_privilege('anon', 'public.comment_likes', 'SELECT'),
  'anonymous clients cannot read comment likes'
);

select ok(
  has_column_privilege('authenticated', 'public.comment_likes', 'comment_id', 'INSERT')
    and has_column_privilege('authenticated', 'public.comment_likes', 'user_id', 'INSERT')
    and not has_column_privilege('authenticated', 'public.comment_likes', 'session_id', 'INSERT'),
  'authenticated inserts cannot spoof the denormalized session id'
);

select * from finish();
rollback;
