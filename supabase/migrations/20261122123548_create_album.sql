-- 앨범 및 앨범 음악 테이블

-- 음악 장르 (가사 포함 9종 + 가사 미포함 9종, 앱과 동일한 값 사용)
create type public.genre_type as enum (
  'POP', 'K_POP', 'J_POP', 'ACOUSTIC', 'BALLAD', 'INDIE', 'ROCK', 'JAZZ', 'R_AND_B',
  'LO_FI', 'AMBIENT', 'CINEMATIC', 'NEW_AGE', 'JAZZ_NO_VOCAL', 'BOSSA_NOVA',
  'TROPICAL_HOUSE', 'DEEP_HOUSE', 'CHILLOUT'
);

-- 보컬 성별 (M: 남성, F: 여성, N: 보컬 없음)
create type public.vocal_gender as enum ('M', 'F', 'N');

-- 음악 생성 진행 상태
create type public.music_status as enum ('CREATING', 'COMPLETED', 'FAILED');

-- 앨범 (여행 1건 = 앨범 1개)
create table public.album (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.member (id) on delete cascade,
  -- AI 이미지 분석 후 채워지므로 생성 직후에는 비어 있음
  title text check (char_length(title) <= 15),
  cover_image_path text not null,
  region text not null check (char_length(btrim(region)) between 1 and 25),
  comment text check (char_length(comment) <= 500),
  travel_start_date date not null,
  travel_end_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint album_travel_date_check check (travel_start_date <= travel_end_date)
);

-- 회원별 최신순 목록 조회 및 커서 페이지네이션
create index album_member_id_id_idx on public.album (member_id, id desc);

create trigger album_set_updated_at
  before update on public.album
  for each row execute function public.set_updated_at();

-- 앨범 음악 (앨범당 1곡, 재생성 시 기존 행을 교체)
create table public.album_music (
  id bigint generated always as identity primary key,
  album_id bigint not null unique references public.album (id) on delete cascade,
  member_id uuid not null references public.member (id) on delete cascade,
  genre public.genre_type not null,
  with_lyrics boolean not null,
  vocal_gender public.vocal_gender not null default 'N',
  status public.music_status not null default 'CREATING',
  -- Suno 생성 요청 식별자 (완료 콜백 매칭용)
  task_id text unique,
  music_path text,
  lyrics text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 가사 포함 장르일 때만 가사 생성
  constraint album_music_genre_lyrics_check check (
    with_lyrics = (genre in ('POP', 'K_POP', 'J_POP', 'ACOUSTIC', 'BALLAD', 'INDIE', 'ROCK', 'JAZZ', 'R_AND_B'))
  ),
  -- 가사 포함이면 보컬 성별 필수, 미포함이면 보컬 없음
  constraint album_music_vocal_check check (
    (with_lyrics and vocal_gender <> 'N') or (not with_lyrics and vocal_gender = 'N')
  )
);

create index album_music_member_id_idx on public.album_music (member_id);

create trigger album_music_set_updated_at
  before update on public.album_music
  for each row execute function public.set_updated_at();
