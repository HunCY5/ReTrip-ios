-- 마이페이지 프로필 조회 함수
-- 로그인한 회원의 프로필과 앨범 수·기록 수를 한 번의 요청으로 제공
-- security invoker: 호출한 회원의 권한(RLS)으로 실행되어 본인 데이터만 집계

create function public.get_my_profile()
returns json
language sql
stable
security invoker
set search_path = ''
as $$
  select json_build_object(
    'name', member.name,
    'email', member.email,
    'profile_image_url', member.profile_image_url,
    'album_count', (
      select count(*) from public.album
      where album.member_id = member.id
    ),
    'album_log_count', (
      select count(*) from public.album_log
      where album_log.member_id = member.id
    )
  )
  from public.member
  where member.id = (select auth.uid());
$$;

-- 로그인한 회원만 호출 가능
revoke execute on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;
