-- @mentions in comments.
--
-- Mentions live inline in the comment body as `@username` tokens (Instagram
-- model — no join table; the body is the source of truth). This trigger parses
-- them on insert, resolves each handle to a profile, and notifies the mentioned
-- user. The comment author is never notified of their own mention, and the
-- session author is skipped because they already get a 'comment' notification.

-- 1. Allow the new notification type (preserve every existing one).
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('like', 'comment', 'follow', 'tag', 'repost_approved',
                  'invite_received', 'invite_response', 'invite_cancelled',
                  'rivalry', 'streak', 'mention'));

-- 2. Parse @handles and notify each mentioned profile.
create or replace function public.notify_on_comment_mentions()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  session_author uuid;
  handle text;
  mentioned uuid;
begin
  select user_id into session_author from public.sessions where id = new.session_id;
  for handle in
    select distinct lower(m[1])
    from regexp_matches(new.body, '@([a-z0-9_.]+)', 'gi') as m
  loop
    select id into mentioned from public.profiles where lower(username) = handle;
    if mentioned is not null
       and mentioned <> new.user_id                         -- not the author
       and mentioned is distinct from session_author then   -- author already gets 'comment'
      insert into public.notifications (user_id, actor_id, type, session_id, comment_id)
      values (mentioned, new.user_id, 'mention', new.session_id, new.id);
    end if;
  end loop;
  return new;
end; $$;

drop trigger if exists on_comment_mentions on public.comments;
create trigger on_comment_mentions after insert on public.comments
  for each row execute function public.notify_on_comment_mentions();
