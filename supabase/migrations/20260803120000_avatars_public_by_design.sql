-- Avatars are public by design.
--
-- `20260714043658_user_control_and_safety.sql` set the avatars bucket private
-- and gated reads on `private.can_read_media` → `private.can_view_profile`,
-- i.e. "you may only load an avatar if you may see that person's profile".
-- The bucket was later flipped back to public via a dashboard edit that was
-- never captured in a migration, so that policy has been dead code ever since:
-- a public bucket serves `/object/public/...` without consulting RLS at all.
--
-- The product decision is that the public bucket is CORRECT. Profile pictures
-- are always visible, the way they are on Instagram — they are not gated by
-- blocks or by private-account status. This migration records that decision so
-- it stops looking like drift, and so a future reader doesn't "restore" the
-- private setting and break every avatar in the app.
--
-- Note the client depends on this: `MediaHydrator.publicAvatarURL(for:)` builds
-- avatar URLs synchronously from the object path with no signing round-trip, on
-- the feed's hottest path. Making this bucket private is a client change, not a
-- one-line migration.
--
-- Scope: this applies ONLY to avatars. `post-photos` and `gear-photos` remain
-- private and remain gated by `private.can_read_media`.

update storage.buckets set public = true where id = 'avatars';

-- Replace the read policy that implied an access check it never performed.
-- Reads through the public path bypass this policy entirely; keeping the
-- `can_view_profile` call here only misleads anyone auditing the schema.
drop policy if exists "avatars_read" on storage.objects;
create policy "avatars_read"
  on storage.objects for select to authenticated
  using (bucket_id = 'avatars');

comment on policy "avatars_read" on storage.objects is
  'Avatars are intentionally public (see 20260803120000). This policy is '
  'deliberately ungated: blocks and private-account status do not hide a '
  'profile picture. post-photos and gear-photos remain gated by '
  'private.can_read_media.';
