-- 메인 화면 앨범 카드 조회 뷰
-- 앨범마다 로그 이미지 수와 최신 미리보기 이미지를 한 번의 조회로 함께 제공
-- security_invoker: 조회하는 회원의 권한(RLS)으로 실행되어 본인 앨범만 노출

create view public.album_card_view
with (security_invoker = true)
as
select
  album.id,
  album.member_id,
  album.title,
  album.region,
  album.travel_start_date,
  album.travel_end_date,
  album.cover_image_path,
  album.created_at,
  image_stats.log_image_count,
  coalesce(preview.image_paths, '{}') as preview_log_image_paths
from public.album
-- 앨범 전체 로그 이미지 수 (+N 배지)
left join lateral (
  select count(*)::integer as log_image_count
  from public.album_log_image
  join public.album_log on album_log.id = album_log_image.album_log_id
  where album_log.album_id = album.id
) as image_stats on true
-- 최근 추가된 로그 이미지 최대 3장 (카드 미리보기)
left join lateral (
  select array_agg(recent.image_path order by recent.id desc) as image_paths
  from (
    select album_log_image.id, album_log_image.image_path
    from public.album_log_image
    join public.album_log on album_log.id = album_log_image.album_log_id
    where album_log.album_id = album.id
    order by album_log_image.id desc
    limit 3
  ) as recent
) as preview on true;
