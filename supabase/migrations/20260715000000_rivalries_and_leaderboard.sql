-- Rivalry notifications + crew leaderboard.
--
-- 1. When you log a match against another member, if that meeting hits a
--    head-to-head milestone (the rivalry ties, or the lead changes hands), the
--    opponent gets a "rivalry" notification. Push delivery is automatic — the
--    existing on_notification_dispatch_push trigger fires for every row.
-- 2. crew_leaderboard() ranks you and everyone you follow by match record.

-- --- Notifications: carry a ready-made phrase + allow the new type -----------

-- Rivalry messages need real numbers ("evened at 3-3"), which the generic
-- actor/type message can't express — store the phrase on the row.
alter table public.notifications add column if not exists detail text;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved', 'rivalry'));

-- --- Rivalry trigger ---------------------------------------------------------

-- Fires per opponent tagged in a match. Computes the head-to-head between the
-- session owner and that opponent (across all of the owner's matches), and
-- notifies the opponent when the meeting is a rivalry moment. Guests
-- (no profile_id) have no one to notify and are skipped.
create or replace function public.notify_on_rivalry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  owner        uuid;
  opp          uuid;
  this_won     boolean;
  wins         int;
  losses       int;
  prev_wins    int;
  prev_losses  int;
  total        int;
  owner_handle text;
  detail       text;
begin
  if new.role <> 'opponent' or new.profile_id is null then
    return new;
  end if;

  opp := new.profile_id;
  select user_id into owner from public.sessions where id = new.session_id;
  if owner is null or owner = opp then
    return new;
  end if;

  -- Only completed match activities count.
  select won into this_won from public.session_activities where id = new.activity_id;
  if this_won is null then
    return new;
  end if;

  -- Owner-perspective record vs this opponent, including the match just logged.
  select
    count(*) filter (where sa.won),
    count(*) filter (where not sa.won)
  into wins, losses
  from public.activity_participants ap
  join public.session_activities sa on sa.id = ap.activity_id
  join public.sessions s on s.id = sa.session_id
  where ap.role = 'opponent'
    and ap.profile_id = opp
    and s.user_id = owner
    and sa.kind = 'match'
    and sa.won is not null;

  total := wins + losses;
  if total < 2 then                       -- one game is not yet a rivalry
    return new;
  end if;

  prev_wins   := wins   - (case when this_won then 1 else 0 end);
  prev_losses := losses - (case when this_won then 0 else 1 end);

  select username into owner_handle from public.profiles where id = owner;

  -- Record is phrased from the recipient's (opponent's) point of view:
  -- their wins are the owner's losses, and vice-versa.
  if wins = losses and prev_wins <> prev_losses then
    detail := '@' || owner_handle || ' evened your rivalry at ' || wins || '–' || losses;
  elsif wins > losses and prev_wins <= prev_losses then
    detail := '@' || owner_handle || ' took the lead in your rivalry, ' || losses || '–' || wins;
  elsif losses > wins and prev_losses <= prev_wins then
    detail := 'You took the lead over @' || owner_handle || ', ' || losses || '–' || wins;
  else
    return new;                           -- no lead change, stay quiet
  end if;

  insert into public.notifications (user_id, actor_id, type, session_id, detail)
  values (opp, owner, 'rivalry', new.session_id, detail);
  return new;
end; $$;

drop trigger if exists on_rivalry_match on public.activity_participants;
create trigger on_rivalry_match after insert on public.activity_participants
  for each row execute function public.notify_on_rivalry();

-- --- Crew leaderboard --------------------------------------------------------

-- You plus everyone you follow (accepted), ranked by match record. SECURITY
-- DEFINER so it can read followees' aggregate records — consistent with the
-- app already showing a followed player's sessions.
create or replace function public.crew_leaderboard()
returns table (
  user_id         uuid,
  username        text,
  display_name    text,
  avatar_url      text,
  avatar_initials text,
  wins            int,
  losses          int,
  matches         int
)
language sql stable security definer set search_path = public as $$
  with crew as (
    select auth.uid() as id
    union
    select f.followee_id from public.follows f
    where f.follower_id = auth.uid() and f.status = 'accepted'
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    coalesce(count(*) filter (where sa.won is true), 0)::int  as wins,
    coalesce(count(*) filter (where sa.won is false), 0)::int as losses,
    coalesce(count(*) filter (where sa.won is not null), 0)::int as matches
  from crew c
  join public.profiles p on p.id = c.id
  left join public.sessions s on s.user_id = p.id
  left join public.session_activities sa on sa.session_id = s.id and sa.kind = 'match'
  group by p.id, p.username, p.display_name, p.avatar_url, p.avatar_initials;
$$;

revoke all on function public.crew_leaderboard() from public;
grant execute on function public.crew_leaderboard() to authenticated;
