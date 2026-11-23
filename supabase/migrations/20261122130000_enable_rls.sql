-- 행 수준 보안(RLS): 로그인한 회원은 본인 데이터에만 접근
-- AI 결과 반영, 알림 생성, 회원 탈퇴는 Edge Function(service role)에서 처리하므로 앱 권한에서 제외

alter table public.member enable row level security;
alter table public.member_device enable row level security;
alter table public.album enable row level security;
alter table public.album_music enable row level security;
alter table public.album_log enable row level security;
alter table public.album_log_image enable row level security;
alter table public.alarm enable row level security;

-- 회원: 본인 프로필 조회·수정 (생성은 가입 트리거, 삭제는 탈퇴 처리)
create policy "member_select_own" on public.member
  for select to authenticated
  using (id = (select auth.uid()));

create policy "member_update_own" on public.member
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- 기기: 본인 기기 등록·갱신·해제
create policy "member_device_select_own" on public.member_device
  for select to authenticated
  using (member_id = (select auth.uid()));

create policy "member_device_insert_own" on public.member_device
  for insert to authenticated
  with check (member_id = (select auth.uid()));

create policy "member_device_update_own" on public.member_device
  for update to authenticated
  using (member_id = (select auth.uid()))
  with check (member_id = (select auth.uid()));

create policy "member_device_delete_own" on public.member_device
  for delete to authenticated
  using (member_id = (select auth.uid()));

-- 앨범: 본인 앨범 조회·생성·수정·삭제
create policy "album_select_own" on public.album
  for select to authenticated
  using (member_id = (select auth.uid()));

create policy "album_insert_own" on public.album
  for insert to authenticated
  with check (member_id = (select auth.uid()));

create policy "album_update_own" on public.album
  for update to authenticated
  using (member_id = (select auth.uid()))
  with check (member_id = (select auth.uid()));

create policy "album_delete_own" on public.album
  for delete to authenticated
  using (member_id = (select auth.uid()));

-- 앨범 음악: 본인 앨범 음악 조회만 허용 (생성·갱신은 음악 생성 처리에서만)
create policy "album_music_select_own" on public.album_music
  for select to authenticated
  using (member_id = (select auth.uid()));

-- 앨범 로그: 본인 앨범에만 기록 작성
create policy "album_log_select_own" on public.album_log
  for select to authenticated
  using (member_id = (select auth.uid()));

create policy "album_log_insert_own" on public.album_log
  for insert to authenticated
  with check (
    member_id = (select auth.uid())
    and exists (
      select 1 from public.album
      where album.id = album_log.album_id
        and album.member_id = (select auth.uid())
    )
  );

create policy "album_log_update_own" on public.album_log
  for update to authenticated
  using (member_id = (select auth.uid()))
  with check (
    member_id = (select auth.uid())
    and exists (
      select 1 from public.album
      where album.id = album_log.album_id
        and album.member_id = (select auth.uid())
    )
  );

create policy "album_log_delete_own" on public.album_log
  for delete to authenticated
  using (member_id = (select auth.uid()));

-- 앨범 로그 이미지: 본인 기록에만 이미지 추가 (수정 없이 삭제 후 추가)
create policy "album_log_image_select_own" on public.album_log_image
  for select to authenticated
  using (member_id = (select auth.uid()));

create policy "album_log_image_insert_own" on public.album_log_image
  for insert to authenticated
  with check (
    member_id = (select auth.uid())
    and exists (
      select 1 from public.album_log
      where album_log.id = album_log_image.album_log_id
        and album_log.member_id = (select auth.uid())
    )
  );

create policy "album_log_image_delete_own" on public.album_log_image
  for delete to authenticated
  using (member_id = (select auth.uid()));

-- 알림: 본인 알림 조회·삭제 (생성은 음악 생성 처리에서만)
create policy "alarm_select_own" on public.alarm
  for select to authenticated
  using (member_id = (select auth.uid()));

create policy "alarm_delete_own" on public.alarm
  for delete to authenticated
  using (member_id = (select auth.uid()));
