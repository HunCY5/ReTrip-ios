//
//  AlbumServiceSupabaseTests.swift
//  VibeTripTests
//
//  Created by CHOI on 11/24/26.
//

// 앨범 목록·상세·수정·삭제의 Supabase 요청 구성과 응답 변환 검증
// - 실제 네트워크 대신 SupabaseStubURLProtocol이 요청 경로·메서드별 응답 반환

import XCTest
import Supabase
@testable import VibeTrip

final class AlbumServiceSupabaseTests: XCTestCase {

    // MARK: - Constants

    private enum Constants {
        static let memberId = "8f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f"
        static let pageLimit = 2
        static let cursor = 5
        static let albumId = 42
        static let storagePublicPrefix = "https://test.supabase.co/storage/v1/object/public"
    }

    private enum Path {
        static let albumCardView = "/rest/v1/album_card_view"
        static let album = "/rest/v1/album"
        static let coversObjectPrefix = "/storage/v1/object/covers/"
        static let removeCovers = "/storage/v1/object/covers"
        static let removeLogImages = "/storage/v1/object/log-images"
        static let removeMusic = "/storage/v1/object/music"
    }

    // MARK: - Properties

    private var client: SupabaseClient!
    private var sut: AlbumService!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        SupabaseStubURLProtocol.reset()
        client = SupabaseTestClient.make()
        sut = AlbumService(apiClient: MockAPIClient(), supabase: client)
    }

    override func tearDown() {
        SupabaseStubURLProtocol.reset()
        client = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - fetchAlbums

    // 조회 결과 -> 카드 변환 (빈 제목은 생성 중 nil, 파일 경로는 공개 URL)
    func test_fetchAlbums_mapsRowsToCards() async throws {
        let json = """
        [
          {"id":7,"title":"오사카의 밤","region":"일본 오사카","travel_start_date":"2026-01-12","travel_end_date":"2026-01-15",
           "cover_image_path":"\(Constants.memberId)/cover.jpg","log_image_count":4,
           "preview_log_image_paths":["\(Constants.memberId)/log1.jpg","\(Constants.memberId)/log2.jpg"]},
          {"id":6,"title":"","region":"부산","travel_start_date":"2026-02-01","travel_end_date":"2026-02-02",
           "cover_image_path":"\(Constants.memberId)/cover2.jpg","log_image_count":0,"preview_log_image_paths":[]}
        ]
        """
        SupabaseStubURLProtocol.handler = { request in
            SupabaseStub.response(json, headers: ["Content-Range": "0-1/2"], for: request)
        }

        let result = try await sut.fetchAlbums(cursor: nil, limit: Constants.pageLimit)

        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertFalse(result.hasNext)

        let first = result.content[0]
        XCTAssertEqual(first.id, 7)
        XCTAssertEqual(first.title, "오사카의 밤")
        XCTAssertEqual(first.location, "일본 오사카")
        XCTAssertEqual(first.startDate, "2026-01-12")
        XCTAssertEqual(first.endDate, "2026-01-15")
        XCTAssertEqual(first.coverImageUrl?.absoluteString, "\(Constants.storagePublicPrefix)/covers/\(Constants.memberId)/cover.jpg")
        XCTAssertEqual(first.logImageCount, 4)
        XCTAssertEqual(
            first.previewLogImages.map(\.imageUrl.absoluteString),
            [
                "\(Constants.storagePublicPrefix)/log-images/\(Constants.memberId)/log1.jpg",
                "\(Constants.storagePublicPrefix)/log-images/\(Constants.memberId)/log2.jpg"
            ]
        )
        XCTAssertNil(result.content[1].title)
    }

    // limit보다 1개 더 조회되면 다음 페이지 있음 + limit 개수만 반환
    func test_fetchAlbums_extraRow_setsHasNextAndTrims() async throws {
        let json = "[\(Self.cardJSON(id: 9)),\(Self.cardJSON(id: 8)),\(Self.cardJSON(id: 7))]"
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let result = try await sut.fetchAlbums(cursor: nil, limit: Constants.pageLimit)

        XCTAssertTrue(result.hasNext)
        XCTAssertEqual(result.content.map(\.id), [9, 8])
    }

    // cursor -> 해당 id보다 작은 앨범만, 최신순, limit + 1개 요청
    func test_fetchAlbums_cursor_buildsQuery() async throws {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response("[]", for: $0) }

        _ = try await sut.fetchAlbums(cursor: Constants.cursor, limit: Constants.pageLimit)

        let request = try XCTUnwrap(SupabaseStubURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.url?.path, Path.albumCardView)
        XCTAssertEqual(SupabaseStub.queryValue("id", in: request), "lt.\(Constants.cursor)")
        XCTAssertEqual(SupabaseStub.queryValue("order", in: request)?.hasPrefix("id.desc"), true)
        XCTAssertEqual(SupabaseStub.queryValue("limit", in: request), String(Constants.pageLimit + 1))
    }

    // 첫 페이지는 id 조건 없이 조회
    func test_fetchAlbums_withoutCursor_hasNoIdFilter() async throws {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response("[]", for: $0) }

        let result = try await sut.fetchAlbums(cursor: nil, limit: Constants.pageLimit)

        let request = try XCTUnwrap(SupabaseStubURLProtocol.capturedRequests.last)
        XCTAssertNil(SupabaseStub.queryValue("id", in: request))
        XCTAssertTrue(result.content.isEmpty)
        XCTAssertFalse(result.hasNext)
    }

    // 서버 오류 -> throw
    func test_fetchAlbums_serverError_throws() async {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(Self.errorJSON, statusCode: 500, for: $0) }

        do {
            _ = try await sut.fetchAlbums(cursor: nil, limit: Constants.pageLimit)
            XCTFail("에러가 throw되어야 합니다")
        } catch {}
    }

    // MARK: - fetchAlbum

    // 음악 생성 완료 -> 재생 URL 및 수정 화면 미리 채우기 값 제공
    func test_fetchAlbum_completedMusic_mapsDetail() async throws {
        let json = Self.detailJSON(music: """
        {"genre":"K_POP","with_lyrics":true,"vocal_gender":"F","status":"COMPLETED","music_path":"\(Constants.memberId)/song.mp3"}
        """)
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let detail = try await sut.fetchAlbum(albumId: Constants.albumId)

        let request = try XCTUnwrap(SupabaseStubURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.url?.path, Path.album)
        XCTAssertEqual(SupabaseStub.queryValue("id", in: request), "eq.\(Constants.albumId)")
        XCTAssertEqual(detail.title, "오사카의 밤")
        XCTAssertEqual(detail.region, "일본 오사카")
        XCTAssertEqual(detail.travelStartDate, "2026-01-12")
        XCTAssertEqual(detail.travelEndDate, "2026-01-15")
        XCTAssertEqual(detail.comment, "즐거운 여행")
        XCTAssertEqual(detail.coverImageUrl?.absoluteString, "\(Constants.storagePublicPrefix)/covers/\(Constants.memberId)/cover.jpg")
        XCTAssertEqual(detail.musicUrl?.absoluteString, "\(Constants.storagePublicPrefix)/music/\(Constants.memberId)/song.mp3")
        XCTAssertEqual(detail.genre, .kPop)
        XCTAssertEqual(detail.vocalGender, .female)
        XCTAssertTrue(detail.withLyrics)
    }

    // 음악 생성 중 -> 재생 URL 없음 (화면에서 생성 중으로 판단)
    func test_fetchAlbum_creatingMusic_hasNoMusicUrl() async throws {
        let json = Self.detailJSON(music: """
        {"genre":"LO_FI","with_lyrics":false,"vocal_gender":"N","status":"CREATING","music_path":null}
        """)
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let detail = try await sut.fetchAlbum(albumId: Constants.albumId)

        XCTAssertNil(detail.musicUrl)
        XCTAssertEqual(detail.genre, .loFi)
        XCTAssertNil(detail.vocalGender)
        XCTAssertFalse(detail.withLyrics)
    }

    // 가사 없는 재즈 -> 재즈 장르로 표시
    func test_fetchAlbum_jazzNoVocal_mapsToJazz() async throws {
        let json = Self.detailJSON(music: """
        {"genre":"JAZZ_NO_VOCAL","with_lyrics":false,"vocal_gender":"N","status":"COMPLETED","music_path":"\(Constants.memberId)/song.mp3"}
        """)
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let detail = try await sut.fetchAlbum(albumId: Constants.albumId)

        XCTAssertEqual(detail.genre, .jazz)
        XCTAssertNil(detail.vocalGender)
    }

    // 음악 정보 없음 -> 재생 URL·장르 없음
    func test_fetchAlbum_withoutMusic_hasNoMusicInfo() async throws {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(Self.detailJSON(music: "null"), for: $0) }

        let detail = try await sut.fetchAlbum(albumId: Constants.albumId)

        XCTAssertNil(detail.musicUrl)
        XCTAssertNil(detail.genre)
        XCTAssertFalse(detail.withLyrics)
    }

    // 조회 결과 없음(본인 앨범 아님 등) -> throw
    func test_fetchAlbum_notFound_throws() async {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(Self.notFoundJSON, statusCode: 406, for: $0) }

        do {
            _ = try await sut.fetchAlbum(albumId: Constants.albumId)
            XCTFail("에러가 throw되어야 합니다")
        } catch {}
    }

    // MARK: - updateAlbum

    // 사진 미변경 -> 앨범 정보만 수정, 저장소 요청 없음
    func test_updateAlbum_withoutPhoto_updatesFieldsOnly() async throws {
        SupabaseStubURLProtocol.handler = { request in
            if request.httpMethod == "PATCH" {
                return SupabaseStub.response(#"{"id":42}"#, for: request)
            }
            throw URLError(.badServerResponse)
        }

        try await sut.updateAlbum(albumId: String(Constants.albumId), request: Self.makeUpdateRequest(photoData: nil))

        let requests = SupabaseStubURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 1)
        let patch = try XCTUnwrap(requests.first)
        XCTAssertEqual(patch.url?.path, Path.album)
        XCTAssertEqual(SupabaseStub.queryValue("id", in: patch), "eq.\(Constants.albumId)")

        let body = try SupabaseStub.jsonBody(of: patch)
        XCTAssertEqual(body["title"] as? String, "오사카의 밤")
        XCTAssertEqual(body["region"] as? String, "일본 오사카")
        XCTAssertEqual(body["comment"] as? String, "즐거운 여행")
        XCTAssertNotNil(body["travel_start_date"] as? String)
        XCTAssertNotNil(body["travel_end_date"] as? String)
        XCTAssertNil(body["cover_image_path"])
    }

    // 사진 변경 -> 본인 폴더에 새 커버 업로드, 경로 변경 후 이전 커버 삭제
    func test_updateAlbum_withPhoto_replacesCover() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        let oldCoverPath = "\(Constants.memberId)/old.jpg"
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("GET", Path.album):
                return SupabaseStub.response(#"{"cover_image_path":"\#(oldCoverPath)"}"#, for: request)
            case ("POST", _) where path.hasPrefix(Path.coversObjectPrefix):
                return SupabaseStub.response(#"{"Key":"covers/new.jpg","Id":"1"}"#, for: request)
            case ("PATCH", Path.album):
                return SupabaseStub.response(#"{"id":42}"#, for: request)
            case ("DELETE", Path.removeCovers):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.updateAlbum(
            albumId: String(Constants.albumId),
            request: Self.makeUpdateRequest(photoData: Data([0x01, 0x02]))
        )

        let requests = SupabaseStubURLProtocol.capturedRequests
        let upload = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
        let uploadedPath = String(try XCTUnwrap(upload.url?.path.dropFirst(Path.coversObjectPrefix.count)))
        XCTAssertTrue(uploadedPath.hasPrefix("\(Constants.memberId)/"))
        XCTAssertTrue(uploadedPath.hasSuffix(".jpg"))

        let patch = try XCTUnwrap(requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(try SupabaseStub.jsonBody(of: patch)["cover_image_path"] as? String, uploadedPath)

        let remove = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), [oldCoverPath])
    }

    // 정보 변경 실패 -> 새로 올린 커버 정리 후 throw
    func test_updateAlbum_updateFails_removesUploadedCover() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("GET", Path.album):
                return SupabaseStub.response(#"{"cover_image_path":"old.jpg"}"#, for: request)
            case ("POST", _) where path.hasPrefix(Path.coversObjectPrefix):
                return SupabaseStub.response(#"{"Key":"covers/new.jpg","Id":"1"}"#, for: request)
            case ("PATCH", Path.album):
                return SupabaseStub.response(Self.errorJSON, statusCode: 500, for: request)
            case ("DELETE", Path.removeCovers):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        do {
            try await sut.updateAlbum(
                albumId: String(Constants.albumId),
                request: Self.makeUpdateRequest(photoData: Data([0x01]))
            )
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        let requests = SupabaseStubURLProtocol.capturedRequests
        let upload = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
        let uploadedPath = String(try XCTUnwrap(upload.url?.path.dropFirst(Path.coversObjectPrefix.count)))
        let remove = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), [uploadedPath])
    }

    // 음악 재생성 요청 -> 요청 없이 throw
    func test_updateAlbum_regenerateMusic_throwsWithoutRequest() async {
        do {
            try await sut.updateAlbum(
                albumId: String(Constants.albumId),
                request: Self.makeUpdateRequest(photoData: nil, regenerateMusic: true)
            )
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        XCTAssertTrue(SupabaseStubURLProtocol.capturedRequests.isEmpty)
    }

    // 본인 앨범이 아니어서 변경된 행이 없음 -> throw
    func test_updateAlbum_noRowUpdated_throws() async {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(Self.notFoundJSON, statusCode: 406, for: $0) }

        do {
            try await sut.updateAlbum(albumId: String(Constants.albumId), request: Self.makeUpdateRequest(photoData: nil))
            XCTFail("에러가 throw되어야 합니다")
        } catch {}
    }

    // MARK: - deleteAlbum

    // 앨범 삭제 후 커버·기록 이미지·음악 파일 정리
    func test_deleteAlbum_deletesRowAndRemovesFiles() async throws {
        let filesJSON = """
        {"cover_image_path":"\(Constants.memberId)/cover.jpg",
         "album_music":{"music_path":"\(Constants.memberId)/song.mp3"},
         "album_log":[
           {"album_log_image":[{"image_path":"\(Constants.memberId)/log1.jpg"},{"image_path":"\(Constants.memberId)/log2.jpg"}]},
           {"album_log_image":[{"image_path":"\(Constants.memberId)/log3.jpg"}]}
         ]}
        """
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.album):
                return SupabaseStub.response(filesJSON, for: request)
            case ("DELETE", Path.album):
                return SupabaseStub.response(#"{"id":42}"#, for: request)
            case ("DELETE", _):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.deleteAlbum(albumId: String(Constants.albumId))

        let requests = SupabaseStubURLProtocol.capturedRequests
        let deleteRow = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" && $0.url?.path == Path.album })
        XCTAssertEqual(SupabaseStub.queryValue("id", in: deleteRow), "eq.\(Constants.albumId)")

        let removals = try Dictionary(
            uniqueKeysWithValues: requests
                .filter { $0.httpMethod == "DELETE" && $0.url?.path != Path.album }
                .map { (try XCTUnwrap($0.url?.path), try SupabaseStub.removedPaths(of: $0)) }
        )
        XCTAssertEqual(removals[Path.removeCovers], ["\(Constants.memberId)/cover.jpg"])
        XCTAssertEqual(removals[Path.removeLogImages], [
            "\(Constants.memberId)/log1.jpg", "\(Constants.memberId)/log2.jpg", "\(Constants.memberId)/log3.jpg"
        ])
        XCTAssertEqual(removals[Path.removeMusic], ["\(Constants.memberId)/song.mp3"])
    }

    // 기록 이미지·음악이 없으면 커버만 정리
    func test_deleteAlbum_withoutLogsAndMusic_removesCoverOnly() async throws {
        let filesJSON = #"{"cover_image_path":"cover.jpg","album_music":null,"album_log":[]}"#
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.album):
                return SupabaseStub.response(filesJSON, for: request)
            case ("DELETE", _):
                return SupabaseStub.response(request.url?.path == Path.album ? #"{"id":42}"# : "[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.deleteAlbum(albumId: String(Constants.albumId))

        let storagePaths = SupabaseStubURLProtocol.capturedRequests
            .filter { $0.httpMethod == "DELETE" && $0.url?.path != Path.album }
            .compactMap { $0.url?.path }
        XCTAssertEqual(storagePaths, [Path.removeCovers])
    }

    // 앨범 삭제 실패 -> throw, 파일 정리 안 함
    func test_deleteAlbum_deleteFails_throwsWithoutRemovingFiles() async throws {
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.album):
                return SupabaseStub.response(#"{"cover_image_path":"cover.jpg","album_music":null,"album_log":[]}"#, for: request)
            default:
                return SupabaseStub.response(Self.errorJSON, statusCode: 500, for: request)
            }
        }

        do {
            try await sut.deleteAlbum(albumId: String(Constants.albumId))
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        let storageRequests = SupabaseStubURLProtocol.capturedRequests.filter {
            $0.url?.path.hasPrefix("/storage") == true
        }
        XCTAssertTrue(storageRequests.isEmpty)
    }

    // 파일 정리 실패 -> 앨범 삭제는 성공 처리
    func test_deleteAlbum_fileRemovalFails_stillSucceeds() async throws {
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.album):
                return SupabaseStub.response(#"{"cover_image_path":"cover.jpg","album_music":null,"album_log":[]}"#, for: request)
            case ("DELETE", Path.album):
                return SupabaseStub.response(#"{"id":42}"#, for: request)
            default:
                return SupabaseStub.response(Self.errorJSON, statusCode: 500, for: request)
            }
        }

        try await sut.deleteAlbum(albumId: String(Constants.albumId))
    }

    // MARK: - Helpers

    private static let errorJSON = #"{"message":"server error"}"#
    private static let notFoundJSON =
        #"{"code":"PGRST116","message":"JSON object requested, multiple (or no) rows returned","details":null,"hint":null}"#

    private static func cardJSON(id: Int) -> String {
        """
        {"id":\(id),"title":"앨범\(id)","region":"서울","travel_start_date":"2026-01-01","travel_end_date":"2026-01-02",
         "cover_image_path":"cover\(id).jpg","log_image_count":0,"preview_log_image_paths":[]}
        """
    }

    private static func detailJSON(music: String) -> String {
        """
        {"title":"오사카의 밤","cover_image_path":"\(Constants.memberId)/cover.jpg","region":"일본 오사카",
         "travel_start_date":"2026-01-12","travel_end_date":"2026-01-15","comment":"즐거운 여행","album_music":\(music)}
        """
    }

    private static func makeUpdateRequest(photoData: Data?, regenerateMusic: Bool = false) -> AlbumUpdateRequest {
        AlbumUpdateRequest(
            photoData: photoData,
            title: "오사카의 밤",
            location: "일본 오사카",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 86400),
            lyricsOption: .include,
            vocalGender: .female,
            genre: .kPop,
            regenerateMusic: regenerateMusic,
            comment: "즐거운 여행"
        )
    }
}
