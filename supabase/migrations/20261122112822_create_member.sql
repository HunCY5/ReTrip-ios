-- 회원 및 기기 테이블, 가입 시 회원 자동 생성

-- 수정 시각 자동 갱신 (updated_at 컬럼을 가진 테이블 공통 사용)
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- 회원 프로필 (Supabase Auth 사용자와 1:1)
create table public.member (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '',
  email text,
  profile_image_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger member_set_updated_at
  before update on public.member
  for each row execute function public.set_updated_at();

-- 푸시 알림 수신 기기 (회원당 여러 기기, 기기별 FCM 토큰 1개)
create table public.member_device (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.member (id) on delete cascade,
  device_id text not null,
  fcm_token text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (member_id, device_id)
);

create trigger member_device_set_updated_at
  before update on public.member_device
  for each row execute function public.set_updated_at();

-- 가입 시 소셜 로그인 메타데이터로 회원 프로필 생성
-- 카카오: nickname / picture, 애플: full_name (최초 로그인 시에만 제공될 수 있음)
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.member (id, name, email, profile_image_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'nickname',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      ''
    ),
    new.email,
    coalesce(
      new.raw_user_meta_data ->> 'picture',
      new.raw_user_meta_data ->> 'avatar_url'
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
