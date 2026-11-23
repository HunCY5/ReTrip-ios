-- Storage 버킷 및 업로드 정책
-- 경로 규칙: {회원 id}/{파일명}, 파일명은 UUID로 생성해 공개 URL을 추측할 수 없도록 함

-- 공개 버킷: 앱에서 공개 URL로 바로 표시·재생 (용량 단위: byte)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  -- 앨범 커버 이미지 (10MB)
  ('covers', 'covers', true, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  -- 앨범 로그 이미지 (10MB)
  ('log-images', 'log-images', true, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  -- 생성된 음악 (30MB, 음악 생성 처리에서만 업로드)
  ('music', 'music', true, 31457280, array['audio/mpeg', 'audio/mp4', 'audio/wav']);

-- 커버·로그 이미지: 본인 폴더에만 업로드·교체·삭제
create policy "image_select_own" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('covers', 'log-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "image_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('covers', 'log-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "image_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id in ('covers', 'log-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id in ('covers', 'log-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "image_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('covers', 'log-images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
