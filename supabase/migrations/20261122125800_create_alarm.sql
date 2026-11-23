-- 알림 테이블

-- 알림 종류 (앨범 음악 생성 진행 상황)
create type public.alarm_type as enum ('CREATING', 'COMPLETED', 'FAILED');

-- 알림 내역 (푸시 발송과 함께 저장, 알림 목록 화면에서 조회)
create table public.alarm (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.member (id) on delete cascade,
  title text not null,
  description text not null,
  alarm_type public.alarm_type not null,
  -- 앨범이 삭제되어도 알림 내역은 유지
  album_id bigint references public.album (id) on delete set null,
  created_at timestamptz not null default now()
);

-- 회원별 최신순 알림 목록 조회
create index alarm_member_id_id_idx on public.alarm (member_id, id desc);
create index alarm_album_id_idx on public.alarm (album_id);
