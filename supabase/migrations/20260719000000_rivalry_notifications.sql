-- Rivalry re-engagement push: when someone logs a match they WON against a
-- member opponent, ping that opponent ("@x just logged a win against you —
-- settle the score?"). This is the single strongest re-engagement hook — it
-- pulls the loser back to log a rematch.
--
-- Everything downstream already exists: the 'rivalry' notification type is in
-- the type constraint (streak_reminders migration), the on_notification_dispatch_push
-- trigger delivers any new row, send-push formats 'rivalry' from `detail`, and the
-- client renders it (flame icon) and routes a tap to the session. The only missing
-- piece was that nothing inserted the row — that's what this migration adds.
--
-- Timing note: activity_participants are always inserted AFTER their parent
-- session_activities row (the FK requires it), so `kind`/`won` are already
-- populated when these AFTER-INSERT triggers run.

-- 1. Insert one 'rivalry' notification per member opponent who lost a decided match.
--    Guards: linked member (not a guest), role = opponent, a match with a decisive
--    win by the logger, not the logger themselves, and idempotent per session so
--    editing/re-saving a session doesn't re-ping.
create or replace function public.notify_on_rivalry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_author uuid;
  v_kind   text;
  v_won    boolean;
  v_handle text;
begin
  -- Only member opponents can receive this (guests have no account to notify).
  if new.profile_id is null or new.role <> 'opponent' then
    return new;
  end if;

  select a.kind, a.won into v_kind, v_won
  from public.session_activities a
  where a.id = new.activity_id;

  -- Only decided matches the logger's team won → this opponent lost.
  if v_kind is distinct from 'match' or v_won is not true then
    return new;
  end if;

  select user_id into v_author from public.sessions where id = new.session_id;
  if v_author is null or v_author = new.profile_id then
    return new;
  end if;

  -- Idempotent: at most one rivalry ping per opponent per session, so editing a
  -- session (which re-inserts participants) doesn't fire a duplicate.
  if exists (
    select 1 from public.notifications n
    where n.user_id = new.profile_id
      and n.type = 'rivalry'
      and n.session_id = new.session_id
  ) then
    return new;
  end if;

  select username into v_handle from public.profiles where id = v_author;

  insert into public.notifications (user_id, actor_id, type, session_id, detail)
  values (
    new.profile_id,
    v_author,
    'rivalry',
    new.session_id,
    '@' || coalesce(v_handle, 'someone') || ' just logged a win against you — settle the score?'
  );

  return new;
end; $$;

drop trigger if exists on_rivalry_created on public.activity_participants;
create trigger on_rivalry_created after insert on public.activity_participants
  for each row execute function public.notify_on_rivalry();

-- 2. Suppress the generic "tagged you" notification for the exact participants the
--    rivalry trigger handles, so a beaten opponent gets ONE ping (the spicy one),
--    not two. Partners, practices, ties, and matches the logger lost still get the
--    normal 'tag'. (Redefines notify_on_tag from the notifications migration with
--    this one added guard.)
create or replace function public.notify_on_tag()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_author uuid;
  v_kind   text;
  v_won    boolean;
begin
  if new.profile_id is null then
    return new;
  end if;

  -- Skip when notify_on_rivalry will cover this participant (member opponent who
  -- lost a decided match) to avoid a double notification for one event.
  select a.kind, a.won into v_kind, v_won
  from public.session_activities a
  where a.id = new.activity_id;
  if new.role = 'opponent' and v_kind = 'match' and v_won is true then
    return new;
  end if;

  select user_id into v_author from public.sessions where id = new.session_id;
  if v_author is not null and v_author <> new.profile_id then
    insert into public.notifications (user_id, actor_id, type, session_id)
    values (new.profile_id, v_author, 'tag', new.session_id);
  end if;
  return new;
end; $$;
