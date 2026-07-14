-- Optional photo on a session post. Public-read bucket; each user writes only
-- under a folder named after their (lowercase) uid — matches auth.uid()::text.

alter table public.sessions add column if not exists photo_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-photos', 'post-photos', true, 10485760, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "post_photos_read" on storage.objects;
create policy "post_photos_read" on storage.objects for select
  using (bucket_id = 'post-photos');

drop policy if exists "post_photos_insert_own" on storage.objects;
create policy "post_photos_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "post_photos_update_own" on storage.objects;
create policy "post_photos_update_own" on storage.objects for update to authenticated
  using (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "post_photos_delete_own" on storage.objects;
create policy "post_photos_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);
