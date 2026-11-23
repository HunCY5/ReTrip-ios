-- 앨범 로그(여행 기록) 및 로그 이미지 테이블

-- 앨범 로그 (앨범 하나에 여러 개의 기록)
create table public.album_log (
  id bigint generated always as identity primary key,
  album_id bigint not null references public.album (id) on delete cascade,
  member_id uuid not null references public.member (id) on delete cascade,
  description text not null default '' check (char_length(description) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 앨범별 최신순 목록 조회 및 커서 페이지네이션
create index album_log_album_id_id_idx on public.album_log (album_id, id desc);
create index album_log_member_id_idx on public.album_log (member_id);

create trigger album_log_set_updated_at
  before update on public.album_log
  for each row execute function public.set_updated_at();

-- 앨범 로그 이미지 (로그당 최대 5장)
create table public.album_log_image (
  id bigint generated always as identity primary key,
  album_log_id bigint not null references public.album_log (id) on delete cascade,
  member_id uuid not null references public.member (id) on delete cascade,
  image_path text not null,
  created_at timestamptz not null default now()
);

create index album_log_image_album_log_id_idx on public.album_log_image (album_log_id, id);
create index album_log_image_member_id_idx on public.album_log_image (member_id);

-- 로그당 이미지 개수 제한
create function public.check_album_log_image_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_image_count constant integer := 5;
  current_count integer;
begin
  -- 같은 로그에 동시에 추가될 때 개수 검사가 어긋나지 않도록 로그 행 잠금
  perform 1 from public.album_log where id = new.album_log_id for update;

  select count(*) into current_count
  from public.album_log_image
  where album_log_id = new.album_log_id;

  if current_count >= max_image_count then
    raise exception 'album log image limit exceeded (max %)', max_image_count
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger album_log_image_limit
  before insert on public.album_log_image
  for each row execute function public.check_album_log_image_limit();
