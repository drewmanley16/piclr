-- Atomic full-session create, mirroring public.update_own_session.
--
-- The client used to write a session with four sequential round trips: insert
-- the session unposted, insert each activity, insert its participants, then
-- flip `posted`. Any failure part-way left an orphaned `posted = false` session
-- with a partial activity list — visible in the owner's Workout tab, with no
-- rollback and no retry. If only the final flip failed, the session was
-- stranded private forever.
--
-- This does the same work in one transaction, and picks up the two validations
-- the update path already had but the create path never did: at least one
-- activity, and tagged players must be real onboarded profiles.

create or replace function public.create_own_session(payload jsonb)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  new_session_id uuid := coalesce(nullif(payload->>'id', '')::uuid, gen_random_uuid());
  activity jsonb;
  participant jsonb;
  current_activity_id uuid;
  current_participant_profile_id uuid;
  first_focus text;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(payload->'activities') is distinct from 'array'
     or jsonb_array_length(payload->'activities') = 0 then
    raise exception 'A session must contain at least one activity';
  end if;

  select nullif(item->>'focus', '') into first_focus
  from jsonb_array_elements(payload->'activities') item
  where item->>'kind' = 'practice' and nullif(item->>'focus', '') is not null
  order by coalesce((item->>'position')::integer, 0)
  limit 1;

  -- Insert unposted, then flip `posted` as the last statement. This ordering is
  -- load-bearing: repost_internal.sync_credits_after_session_change is an
  -- `after insert or update of posted` trigger, so inserting with posted = true
  -- would fire it before any activity_participants rows exist and silently
  -- create no workout credits for tagged friends.
  insert into public.sessions (
    id, user_id, title, location, duration_minutes, focus, takeaway, posted,
    started_at, ended_at, photo_path,
    average_heart_rate_bpm, maximum_heart_rate_bpm, active_calories_kcal
  ) values (
    new_session_id,
    caller_id,
    nullif(btrim(payload->>'title'), ''),
    nullif(btrim(payload->>'location'), ''),
    greatest(1, coalesce((payload->>'duration_minutes')::integer, 1)),
    first_focus,
    nullif(btrim(payload->>'takeaway'), ''),
    false,
    (payload->>'started_at')::timestamptz,
    (payload->>'ended_at')::timestamptz,
    nullif(payload->>'photo_path', ''),
    nullif(payload->>'average_heart_rate_bpm', '')::smallint,
    nullif(payload->>'maximum_heart_rate_bpm', '')::smallint,
    nullif(payload->>'active_calories_kcal', '')::integer
  );

  for activity in select value from jsonb_array_elements(payload->'activities')
  loop
    current_activity_id := coalesce(nullif(activity->>'id', '')::uuid, gen_random_uuid());

    insert into public.session_activities (
      id, session_id, kind, position, focus, reps, notes,
      team_score, opponent_score, won
    ) values (
      current_activity_id,
      new_session_id,
      activity->>'kind',
      coalesce((activity->>'position')::integer, 0),
      nullif(activity->>'focus', ''),
      nullif(activity->>'reps', ''),
      nullif(activity->>'notes', ''),
      nullif(activity->>'team_score', '')::integer,
      nullif(activity->>'opponent_score', '')::integer,
      nullif(activity->>'won', '')::boolean
    );

    for participant in
      select value from jsonb_array_elements(coalesce(activity->'participants', '[]'::jsonb))
    loop
      current_participant_profile_id := nullif(participant->>'profile_id', '')::uuid;

      if current_participant_profile_id is not null and not exists (
        select 1 from public.profiles p
        where p.id = current_participant_profile_id and p.onboarding_completed_at is not null
      ) then
        raise exception 'Tagged player not found';
      end if;

      insert into public.activity_participants (
        id, activity_id, session_id, profile_id, guest_name, role
      ) values (
        coalesce(nullif(participant->>'id', '')::uuid, gen_random_uuid()),
        current_activity_id,
        new_session_id,
        current_participant_profile_id,
        case
          when current_participant_profile_id is null
          then nullif(btrim(participant->>'guest_name'), '')
        end,
        participant->>'role'
      );
    end loop;
  end loop;

  update public.sessions
  set posted = coalesce((payload->>'posted')::boolean, true)
  where id = new_session_id and user_id = caller_id;

  return new_session_id;
end;
$$;

revoke all on function public.create_own_session(jsonb) from public, anon;
grant execute on function public.create_own_session(jsonb) to authenticated;
