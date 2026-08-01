-- Phase 2 of removing practice logging. Phase 1 (app) stopped writing practice
-- and stopped reading `focus`; this drops the data and the columns behind it.
--
-- DESTRUCTIVE AND IRREVERSIBLE. Do not apply until the phase-1 client has been
-- adopted: builds that still name `focus` in their `repost_source` select will
-- 400 on every feed read once `sessions.focus` is gone.
--
-- `session_activities.kind` deliberately survives (narrowed to 'match'). The
-- iOS model decodes it as a non-optional String, so dropping the column would
-- break decoding for phase-1 clients.

-- 1. Pre-flight visibility. These land in the `supabase db push` output so the
--    blast radius is on the record next to the run that caused it.
do $$
declare
  practice_activities   bigint;
  practice_participants bigint;
  doomed_sessions       bigint;
  doomed_engagement     bigint;
begin
  select count(*) into practice_activities
  from public.session_activities
  where kind = 'practice';

  -- Expected to be zero: practice never had partners or opponents. A non-zero
  -- count means `cleanup_repost_after_tag_change` will fire during the purge.
  select count(*) into practice_participants
  from public.activity_participants ap
  join public.session_activities sa on sa.id = ap.activity_id
  where sa.kind = 'practice';

  select count(*) into doomed_sessions
  from public.sessions s
  where s.reposted_from is null
    and exists (
      select 1 from public.session_activities sa
      where sa.session_id = s.id and sa.kind = 'practice'
    )
    and not exists (
      select 1 from public.session_activities sa
      where sa.session_id = s.id and sa.kind <> 'practice'
    );

  select count(*) into doomed_engagement
  from public.sessions s
  where s.reposted_from is null
    and exists (
      select 1 from public.session_activities sa
      where sa.session_id = s.id and sa.kind = 'practice'
    )
    and not exists (
      select 1 from public.session_activities sa
      where sa.session_id = s.id and sa.kind <> 'practice'
    )
    and (
      exists (select 1 from public.likes l where l.session_id = s.id)
      or exists (select 1 from public.comments c where c.session_id = s.id)
    );

  raise notice 'practice activities to delete: %', practice_activities;
  raise notice 'practice activities carrying participants (expected 0): %', practice_participants;
  raise notice 'practice-only sessions to delete: %', doomed_sessions;
  raise notice 'of those, sessions carrying likes or comments: %', doomed_engagement;
end $$;

-- 2. Purge.
--
-- Sessions first, so the cascade takes their activities, participants, likes,
-- comments, and notifications with them. The `reposted_from is null` guard is
-- load-bearing: repost and private-credit wrappers hold no activities of their
-- own (they resolve through their source), so without it every repost in the
-- database matches "has no non-practice activity" and gets deleted.
--
-- Scoped to sessions that had a practice activity, so pre-existing empty rows
-- are left alone rather than swept up by a migration that wasn't about them.
delete from public.sessions s
where s.reposted_from is null
  and exists (
    select 1 from public.session_activities sa
    where sa.session_id = s.id and sa.kind = 'practice'
  )
  and not exists (
    select 1 from public.session_activities sa
    where sa.session_id = s.id and sa.kind <> 'practice'
  );

-- Then the practice rows left inside sessions that also held matches.
delete from public.session_activities
where kind = 'practice';

-- 3. Restamp `streak_week`.
--
-- Deleting practice-only sessions can shorten a weekly streak, and the badge is
-- frozen at post time by `stamp_session_streak` (AFTER INSERT only), so nothing
-- self-heals. `user_weekly_streak` can't be reused here: it returns the user's
-- *current* streak and would write today's number onto historical posts. This
-- recomputes each post's streak as of its own week, reproducing the trigger's
-- rules -- only the first session of a week is badged, and only at length >= 2.
--
-- Like the trigger, this counts every session row: unposted sessions and repost
-- wrappers included, matching `user_weekly_streak`.
with weeks as (
  select user_id,
         date_trunc('week', coalesce(started_at, created_at))::date as wk
  from public.sessions
  group by 1, 2
),
islands as (
  -- Consecutive weeks share a constant (wk - n*7); that constant is the run id.
  select user_id, wk,
         wk - (row_number() over (partition by user_id order by wk))::int * 7 as grp
  from weeks
),
run_len as (
  -- Position within the run == the streak length as of that week.
  select user_id, wk,
         (row_number() over (partition by user_id, grp order by wk))::int as len
  from islands
),
first_of_week as (
  select distinct on (user_id, date_trunc('week', coalesce(started_at, created_at))::date)
         id,
         user_id,
         date_trunc('week', coalesce(started_at, created_at))::date as wk
  from public.sessions
  order by user_id,
           date_trunc('week', coalesce(started_at, created_at))::date,
           coalesce(started_at, created_at),
           id
),
restamped as (
  select s.id,
         case when f.id is not null and r.len >= 2 then r.len end as streak_week
  from public.sessions s
  left join first_of_week f on f.id = s.id
  left join run_len r on r.user_id = s.user_id and r.wk = f.wk
)
update public.sessions s
set streak_week = restamped.streak_week
from restamped
where restamped.id = s.id
  and s.streak_week is distinct from restamped.streak_week;

-- 4. Stop the remaining writers from touching focus/reps before the columns go.

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

  insert into public.sessions (
    id, user_id, title, location, duration_minutes, takeaway, posted,
    started_at, ended_at, photo_path,
    average_heart_rate_bpm, maximum_heart_rate_bpm, active_calories_kcal
  ) values (
    new_session_id,
    caller_id,
    nullif(btrim(payload->>'title'), ''),
    nullif(btrim(payload->>'location'), ''),
    greatest(1, coalesce((payload->>'duration_minutes')::integer, 1)),
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

    if (current_match_format = 'singles' and (partner_count > 0 or opponent_count > 1))
       or (current_match_format = 'doubles' and (partner_count > 1 or opponent_count > 2)) then
      raise exception 'Player count exceeds the % roster limit', current_match_format;
    end if;

    -- `kind` is still passed through rather than forced to 'match', so a
    -- pre-phase-1 client sending 'practice' is rejected by the check constraint
    -- instead of having its practice entry silently recorded as a match.
    insert into public.session_activities (
      id, session_id, kind, position, notes,
      team_score, opponent_score, match_format, won
    ) values (
      current_activity_id,
      new_session_id,
      coalesce(nullif(activity->>'kind', ''), 'match'),
      coalesce((activity->>'position')::integer, 0),
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

  update public.sessions
  set title = nullif(btrim(payload->>'title'), ''),
      location = nullif(btrim(payload->>'location'), ''),
      duration_minutes = greatest(1, (payload->>'duration_minutes')::integer),
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

    if (current_match_format = 'singles' and (partner_count > 0 or opponent_count > 1))
       or (current_match_format = 'doubles' and (partner_count > 1 or opponent_count > 2)) then
      raise exception 'Player count exceeds the % roster limit', current_match_format;
    end if;

    insert into public.session_activities (
      id, session_id, kind, position, notes,
      team_score, opponent_score, match_format, won
    ) values (
      current_activity_id,
      target_session_id,
      coalesce(nullif(activity->>'kind', ''), 'match'),
      coalesce((activity->>'position')::integer, 0),
      nullif(activity->>'notes', ''),
      nullif(activity->>'team_score', '')::integer,
      nullif(activity->>'opponent_score', '')::integer,
      current_match_format,
      nullif(activity->>'won', '')::boolean
    )
    on conflict (id) do update set
      kind = excluded.kind,
      position = excluded.position,
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

-- The private workout credit copies the source session's columns; `focus` is
-- no longer one of them.
create or replace function repost_internal.ensure_private_workout_credit(
  source_session_id uuid,
  target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  source_session public.sessions;
  credit_id uuid := gen_random_uuid();
begin
  select s.* into source_session
  from public.sessions s
  where s.id = source_session_id
  for share;

  if source_session.id is null
     or source_session.reposted_from is not null
     or not source_session.posted
     or source_session.user_id = target_user_id
     or not private.is_mutual_follow(source_session.user_id, target_user_id)
     or private.is_blocked_between(source_session.user_id, target_user_id)
     or not exists (
       select 1
       from public.activity_participants ap
       join public.session_activities sa on sa.id = ap.activity_id
       where ap.session_id = source_session_id
         and ap.profile_id = target_user_id
         and sa.kind = 'match'
     ) then
    return null;
  end if;

  insert into public.sessions (
    id, user_id, title, location, duration_minutes, takeaway, posted,
    started_at, ended_at, reposted_from, created_at
  ) values (
    credit_id, target_user_id, source_session.title, source_session.location,
    source_session.duration_minutes, source_session.takeaway,
    false, source_session.started_at, source_session.ended_at,
    source_session.id, source_session.created_at
  )
  on conflict (user_id, reposted_from) where reposted_from is not null
  do nothing
  returning id into credit_id;

  if credit_id is null then
    select s.id into credit_id
    from public.sessions s
    where s.user_id = target_user_id
      and s.reposted_from = source_session_id;
  end if;

  return credit_id;
end;
$$;
revoke all on function repost_internal.ensure_private_workout_credit(uuid, uuid)
  from public, anon, authenticated;

-- 5. Drop the practice-only columns. Safe for phase-1 clients: `focus` and
--    `reps` are absent from both the iOS models and their CodingKeys, and
--    `focus` is no longer named in the `repost_source` select string.
alter table public.session_activities drop column if exists focus;
alter table public.session_activities drop column if exists reps;
alter table public.sessions           drop column if exists focus;

-- 6. Narrow `kind` so practice can never be written again. No NOT VALID needed:
--    step 2 already removed every row that would fail validation.
alter table public.session_activities
  drop constraint if exists session_activities_kind_check;
alter table public.session_activities
  add constraint session_activities_kind_check check (kind in ('match'));

comment on column public.session_activities.kind is
  'Always ''match''. Retained because the iOS model decodes it as non-optional.';

comment on column public.session_activities.match_format is
  'Explicit match format: singles or doubles.';
