-- Let a user read their own post-photo objects unconditionally.
--
-- `post_photos_read` authorizes by resolving the object name back to a session
-- (`private.can_read_media` → `can_view_session` + an existence check on
-- `public.sessions`). That is right for *other people's* photos, but it makes a
-- user's access to their own upload depend on a session row that may not exist
-- yet: `uploadPostPhoto` deliberately runs before `create_own_session` so a
-- failed upload leaves no orphaned session behind.
--
-- On its own that ordering was harmless, because an INSERT only evaluates the
-- INSERT policy. But the upload passes `upsert: true`, which makes PostgREST
-- issue `INSERT ... ON CONFLICT DO UPDATE` — and that form additionally
-- requires the SELECT policy to pass on the target row. With no session row to
-- authorize against, `can_read_media` returned false and the whole statement
-- failed with "new row violates row-level security policy", surfacing in the
-- app as a 403 that aborted the post.
--
-- Reading back an object you uploaded, in your own uid-scoped folder, needs no
-- session lookup to justify it — ownership is established by the path prefix,
-- which is exactly what the INSERT/UPDATE/DELETE policies already rely on. So
-- allow it directly and leave the session-based rule to cover everyone else.
--
-- Scoped to post-photos on purpose: avatars and gear-photos upload without
-- upsert, so they only ever run a plain INSERT and are unaffected.

drop policy if exists "post_photos_read" on storage.objects;
create policy "post_photos_read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'post-photos'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or private.can_read_media((select auth.uid()), bucket_id, name)
    )
  );
