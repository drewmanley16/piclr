-- comment_likes.session_id is denormalized for efficient filtering, but its
-- foreign key to sessions creates a second sessions-to-comments relationship
-- through comment_likes. PostgREST then cannot resolve existing comments
-- embeds such as comments(count) and returns PGRST201 for every session query.
--
-- Keep the column and its primary-key membership. Referential cleanup remains
-- guaranteed by sessions -> comments -> comment_likes ON DELETE CASCADE.
alter table public.comment_likes
  drop constraint if exists comment_likes_session_id_fkey;

-- Make the corrected relationship graph visible to the Data API immediately.
notify pgrst, 'reload schema';
