-- 생성된 음악 파일 정리 정책
-- 앨범 삭제 시 본인 폴더의 음악 파일을 앱에서 함께 삭제 (업로드는 음악 생성 처리에서만 수행)
-- Storage 파일 삭제는 조회·삭제 권한이 모두 필요

create policy "music_select_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'music'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "music_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'music'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
