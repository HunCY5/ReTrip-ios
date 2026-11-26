-- 앨범 로그 작성·수정 함수
-- 로그 텍스트와 사진 행을 한 번의 요청(하나의 트랜잭션)으로 반영해 로그와 사진이 어긋나지 않도록 함
-- security invoker: 호출한 회원의 권한(RLS)으로 실행되어 본인 앨범·로그에만 반영

-- 로그 작성: 로그 행 + 사진 행(전달한 경로 순서대로) 추가 후 새 로그 id 반환
create function public.create_album_log(
  p_album_id bigint,
  p_description text,
  p_image_paths text[]
)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  new_album_log_id bigint;
begin
  insert into public.album_log (album_id, member_id, description)
  values (p_album_id, (select auth.uid()), p_description)
  returning id into new_album_log_id;

  insert into public.album_log_image (album_log_id, member_id, image_path)
  select new_album_log_id, (select auth.uid()), image.path
  from unnest(coalesce(p_image_paths, '{}'::text[])) with ordinality as image (path, position)
  order by image.position;

  return new_album_log_id;
end;
$$;

-- 로그 수정: 텍스트 변경 + 사진 삭제 + 새 사진 추가 후 삭제된 사진 경로 반환
-- - 본인 로그가 아니면(RLS로 변경 0건) 예외 발생
-- - 사진 개수 제한(로그당 5장)에 걸리지 않도록 삭제를 먼저 처리
-- - 반환한 경로의 파일은 앱에서 저장소에서 정리
create function public.update_album_log(
  p_album_log_id bigint,
  p_description text,
  p_remove_image_ids bigint[],
  p_new_image_paths text[]
)
returns text[]
language plpgsql
security invoker
set search_path = ''
as $$
declare
  removed_image_paths text[];
begin
  update public.album_log
  set description = p_description
  where id = p_album_log_id;

  if not found then
    raise exception 'album log not found (id %)', p_album_log_id
      using errcode = 'no_data_found';
  end if;

  with removed as (
    delete from public.album_log_image
    where album_log_id = p_album_log_id
      and id = any(coalesce(p_remove_image_ids, '{}'::bigint[]))
    returning image_path
  )
  select coalesce(array_agg(removed.image_path), '{}'::text[])
  into removed_image_paths
  from removed;

  insert into public.album_log_image (album_log_id, member_id, image_path)
  select p_album_log_id, (select auth.uid()), image.path
  from unnest(coalesce(p_new_image_paths, '{}'::text[])) with ordinality as image (path, position)
  order by image.position;

  return removed_image_paths;
end;
$$;

-- 로그인한 회원만 호출 가능
revoke execute on function public.create_album_log(bigint, text, text[]) from public, anon;
grant execute on function public.create_album_log(bigint, text, text[]) to authenticated;

revoke execute on function public.update_album_log(bigint, text, bigint[], text[]) from public, anon;
grant execute on function public.update_album_log(bigint, text, bigint[], text[]) to authenticated;
