-- Guest browsing: a signed-out visitor can preview the app before creating an
-- account. Rather than opening RLS on sessions/profiles/likes/comments to the
-- `anon` role (five+ policies to independently get right, easy to leak a
-- private account's activity through a join), expose one narrow,
-- SECURITY DEFINER RPC that hand-picks a deliberately trimmed payload: public
-- posted sessions from non-private, active users, with counts but no comment
-- content and no other participants' names/identities.

create or replace function public.public_feed_preview(
  p_limit int default 12,
  p_before timestamptz default null
)
returns table (
  id uuid,
  created_at timestamptz,
  title text,
  location text,
  duration_minutes int,
  author_id uuid,
  author_username text,
  author_display_name text,
  author_avatar_url text,
  author_avatar_initials text,
  like_count bigint,
  comment_count bigint,
  matches jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    s.id,
    s.created_at,
    s.title,
    s.location,
    s.duration_minutes,
    p.id,
    p.username,
    p.display_name,
    p.avatar_url,
    p.avatar_initials,
    (select count(*) from public.likes l where l.session_id = s.id),
    (select count(*) from public.comments c where c.session_id = s.id),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'team_score', sa.team_score,
          'opponent_score', sa.opponent_score,
          'won', sa.won
        )
        order by sa.position
      )
      from public.session_activities sa
      where sa.session_id = s.id and sa.kind = 'match'
    ), '[]'::jsonb)
  from public.sessions s
  join public.profiles p on p.id = s.user_id
  where s.posted = true
    and p.is_private = false
    and private.is_active_user(p.id)
    and (p_before is null or s.created_at < p_before)
  order by s.created_at desc
  limit least(greatest(p_limit, 1), 20);
$$;

revoke all on function public.public_feed_preview(int, timestamptz) from public;
grant execute on function public.public_feed_preview(int, timestamptz) to anon, authenticated;
