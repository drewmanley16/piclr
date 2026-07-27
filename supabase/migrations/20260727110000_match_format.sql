-- Persist an explicit format rather than inferring singles/doubles from tags:
-- players are optional while logging, so participant counts are ambiguous.

alter table public.session_activities
  add column if not exists match_format text not null default 'doubles';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.session_activities'::regclass
      and conname = 'session_activities_match_format_check'
  ) then
    alter table public.session_activities
      add constraint session_activities_match_format_check
      check (match_format in ('singles', 'doubles'));
  end if;
end $$;

comment on column public.session_activities.match_format is
  'Explicit match format. Practices retain the doubles default but ignore it.';

-- Keep create atomic while accepting old clients that do not send the field:
-- their activities retain the historical doubles default.
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
  current_match_format text;
  partner_count integer;
  opponent_count integer;
  first_focus text;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(payload->'activities') is distinct from 'array'
     or jsonb_array_length(payload->'activities') = 0 then
    raise exception 'A session must contain at least one activity';
  end if;

  if exists (
    select 1 from public.sessions s
    where s.id = new_session_id and s.user_id = caller_id
  ) then
    return new_session_id;
  end if;

  select nullif(item->>'focus', '') into first_focus
  from jsonb_array_elements(payload->'activities') item
  where item->>'kind' = 'practice' and nullif(item->>'focus', '') is not null
  order by coalesce((item->>'position')::integer, 0)
  limit 1;

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
    current_match_format := coalesce(nullif(activity->>'match_format', ''), 'doubles');

    select
      count(*) filter (where item->>'role' = 'partner'),
      count(*) filter (where item->>'role' = 'opponent')
    into partner_count, opponent_count
    from jsonb_array_elements(coalesce(activity->'participants', '[]'::jsonb)) item;

    if activity->>'kind' = 'match' and (
      (current_match_format = 'singles' and (partner_count > 0 or opponent_count > 1))
      or (current_match_format = 'doubles' and (partner_count > 1 or opponent_count > 2))
    ) then
      raise exception 'Player count exceeds the % roster limit', current_match_format;
    end if;

    insert into public.session_activities (
      id, session_id, kind, position, focus, reps, notes,
      team_score, opponent_score, match_format, won
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
      current_match_format,
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

create or replace function public.update_own_session(
  target_session_id uuid,
  payload jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  activity jsonb;
  participant jsonb;
  current_activity_id uuid;
  current_participant_id uuid;
  current_participant_profile_id uuid;
  current_match_format text;
  partner_count integer;
  opponent_count integer;
  participant_ids uuid[];
  activity_ids uuid[] := array[]::uuid[];
  affected integer;
  first_focus text;
begin
  if caller_id is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(payload->'activities') is distinct from 'array'
     or jsonb_array_length(payload->'activities') = 0 then
    raise exception 'A session must contain at least one activity';
  end if;

  perform 1 from public.sessions s
  where s.id = target_session_id and s.user_id = caller_id
  for update;
  if not found then raise exception 'Session not found'; end if;

  select nullif(item->>'focus', '') into first_focus
  from jsonb_array_elements(payload->'activities') item
  where item->>'kind' = 'practice' and nullif(item->>'focus', '') is not null
  order by coalesce((item->>'position')::integer, 0)
  limit 1;

  update public.sessions
  set title = nullif(btrim(payload->>'title'), ''),
      location = nullif(btrim(payload->>'location'), ''),
      duration_minutes = greatest(1, (payload->>'duration_minutes')::integer),
      focus = first_focus,
      takeaway = nullif(btrim(payload->>'takeaway'), ''),
      posted = coalesce((payload->>'posted')::boolean, posted),
      started_at = (payload->>'started_at')::timestamptz,
      ended_at = (payload->>'ended_at')::timestamptz,
      photo_path = case
        when payload ? 'photo_path' then nullif(payload->>'photo_path', '')
        else photo_path
      end
  where id = target_session_id and user_id = caller_id;

  for activity in select value from jsonb_array_elements(payload->'activities')
  loop
    current_activity_id := (activity->>'id')::uuid;
    current_match_format := coalesce(nullif(activity->>'match_format', ''), 'doubles');
    activity_ids := array_append(activity_ids, current_activity_id);

    select
      count(*) filter (where item->>'role' = 'partner'),
      count(*) filter (where item->>'role' = 'opponent')
    into partner_count, opponent_count
    from jsonb_array_elements(coalesce(activity->'participants', '[]'::jsonb)) item;

    if activity->>'kind' = 'match' and (
      (current_match_format = 'singles' and (partner_count > 0 or opponent_count > 1))
      or (current_match_format = 'doubles' and (partner_count > 1 or opponent_count > 2))
    ) then
      raise exception 'Player count exceeds the % roster limit', current_match_format;
    end if;

    insert into public.session_activities (
      id, session_id, kind, position, focus, reps, notes,
      team_score, opponent_score, match_format, won
    ) values (
      current_activity_id,
      target_session_id,
      activity->>'kind',
      coalesce((activity->>'position')::integer, 0),
      nullif(activity->>'focus', ''),
      nullif(activity->>'reps', ''),
      nullif(activity->>'notes', ''),
      nullif(activity->>'team_score', '')::integer,
      nullif(activity->>'opponent_score', '')::integer,
      current_match_format,
      nullif(activity->>'won', '')::boolean
    )
    on conflict (id) do update set
      kind = excluded.kind,
      position = excluded.position,
      focus = excluded.focus,
      reps = excluded.reps,
      notes = excluded.notes,
      team_score = excluded.team_score,
      opponent_score = excluded.opponent_score,
      match_format = excluded.match_format,
      won = excluded.won
    where public.session_activities.session_id = target_session_id;
    get diagnostics affected = row_count;
    if affected <> 1 then raise exception 'Invalid activity identifier'; end if;

    participant_ids := array[]::uuid[];
    for participant in
      select value from jsonb_array_elements(coalesce(activity->'participants', '[]'::jsonb))
    loop
      current_participant_id := (participant->>'id')::uuid;
      current_participant_profile_id := nullif(participant->>'profile_id', '')::uuid;
      participant_ids := array_append(participant_ids, current_participant_id);

      if current_participant_profile_id is not null and not exists (
        select 1 from public.profiles p
        where p.id = current_participant_profile_id and p.onboarding_completed_at is not null
      ) then
        raise exception 'Tagged player not found';
      end if;

      insert into public.activity_participants (
        id, activity_id, session_id, profile_id, guest_name, role
      ) values (
        current_participant_id,
        current_activity_id,
        target_session_id,
        current_participant_profile_id,
        case when current_participant_profile_id is null then nullif(btrim(participant->>'guest_name'), '') end,
        participant->>'role'
      )
      on conflict (id) do update set
        activity_id = excluded.activity_id,
        profile_id = excluded.profile_id,
        guest_name = excluded.guest_name,
        role = excluded.role
      where public.activity_participants.session_id = target_session_id;
      get diagnostics affected = row_count;
      if affected <> 1 then raise exception 'Invalid participant identifier'; end if;
    end loop;

    delete from public.activity_participants ap
    where ap.session_id = target_session_id
      and ap.activity_id = current_activity_id
      and not (ap.id = any(participant_ids));
  end loop;

  delete from public.session_activities a
  where a.session_id = target_session_id
    and not (a.id = any(activity_ids));
end;
$$;

revoke all on function public.update_own_session(uuid, jsonb) from public, anon;
grant execute on function public.update_own_session(uuid, jsonb) to authenticated;
