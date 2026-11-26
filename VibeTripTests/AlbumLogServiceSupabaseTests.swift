//
//  AlbumLogServiceSupabaseTests.swift
//  VibeTripTests
//
//  Created by CHOI on 11/26/26.
//

// 앨범 로그 피드·작성·수정·삭제의 Supabase 요청 구성과 응답 변환 검증
// - 실제 네트워크 대신 SupabaseStubURLProtocol이 요청 경로·메서드별 응답 반환

import XCTest
import Supabase
@testable import VibeTrip

final class AlbumLogServiceSupabaseTests: XCTestCase {

    // MARK: - Constants

    private enum Constants {
        static let memberId = "8f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f"
        static let albumId = 42
        static let albumLogId = 7
        static let pageLimit = 2
        static let cursor = 10
        static let logText = "여행 기록"
        static let storagePublicPrefix = "https://test.supabase.co/storage/v1/object/public"
    }

    private enum Path {
        static let albumLog = "/rest/v1/album_log"
        static let createAlbumLog = "/rest/v1/rpc/create_album_log"
        static let updateAlbumLog = "/rest/v1/rpc/update_album_log"
        static let logImagesObjectPrefix = "/storage/v1/object/log-images/"
        static let removeLogImages = "/storage/v1/object/log-images"
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

    // MARK: - fetchAlbumLogs

    // 조회 결과 -> 피드 아이템 변환 (사진 경로는 공개 URL, 작성 시각은 초 단위 UTC)
    func test_fetchAlbumLogs_mapsRowsToEntries() async throws {
        let json = """
        [
          {"id":9,"description":"오사카 첫날","created_at":"2026-11-25T03:12:45.123456+00:00",
           "album_log_image":[{"id":31,"image_path":"\(Constants.memberId)/a.jpg"},{"id":32,"image_path":"\(Constants.memberId)/b.jpg"}]},
          {"id":8,"description":"사진 없는 기록","created_at":"2026-11-25T12:00:00+09:00","album_log_image":[]}
        ]
        """
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let result = try await sut.fetchAlbumLogs(
            albumId: String(Constants.albumId), cursor: nil, limit: Constants.pageLimit
        )

        XCTAssertFalse(result.hasNext)
        XCTAssertEqual(result.content.map(\.id), [9, 8])

        let first = result.content[0]
        XCTAssertEqual(first.description, "오사카 첫날")
        XCTAssertEqual(first.postedAt, "2026-11-25T03:12:45Z")
        XCTAssertEqual(first.images.map(\.id), [31, 32])
        XCTAssertEqual(
            first.images.map(\.imageUrl.absoluteString),
            [
                "\(Constants.storagePublicPrefix)/log-images/\(Constants.memberId)/a.jpg",
                "\(Constants.storagePublicPrefix)/log-images/\(Constants.memberId)/b.jpg"
            ]
        )

        let second = result.content[1]
        XCTAssertEqual(second.postedAt, "2026-11-25T03:00:00Z")
        XCTAssertTrue(second.images.isEmpty)
    }

    // 변환한 작성 시각은 수정 화면의 기본 ISO8601 파싱으로 읽을 수 있어야 함
    func test_fetchAlbumLogs_postedAt_isParsableByDefaultISO8601Formatter() async throws {
        let json = """
        [{"id":1,"description":"","created_at":"2026-11-25T03:12:45.1+00:00","album_log_image":[]}]
        """
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let result = try await sut.fetchAlbumLogs(
            albumId: String(Constants.albumId), cursor: nil, limit: Constants.pageLimit
        )

        let postedAt = try XCTUnwrap(result.content.first?.postedAt)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: postedAt))
    }

    // limit보다 1개 더 조회되면 다음 페이지 있음 + limit 개수만 반환
    func test_fetchAlbumLogs_extraRow_setsHasNextAndTrims() async throws {
        let json = "[\(Self.logJSON(id: 9)),\(Self.logJSON(id: 8)),\(Self.logJSON(id: 7))]"
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(json, for: $0) }

        let result = try await sut.fetchAlbumLogs(
            albumId: String(Constants.albumId), cursor: nil, limit: Constants.pageLimit
        )

        XCTAssertTrue(result.hasNext)
        XCTAssertEqual(result.content.map(\.id), [9, 8])
    }

    // cursor -> 해당 앨범에서 id보다 작은 로그만, 최신순, 사진은 추가 순, limit + 1개 요청
    func test_fetchAlbumLogs_cursor_buildsQuery() async throws {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response("[]", for: $0) }

        _ = try await sut.fetchAlbumLogs(
            albumId: String(Constants.albumId), cursor: Constants.cursor, limit: Constants.pageLimit
        )

        let request = try XCTUnwrap(SupabaseStubURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, Path.albumLog)
        XCTAssertEqual(SupabaseStub.queryValue("album_id", in: request), "eq.\(Constants.albumId)")
        XCTAssertEqual(SupabaseStub.queryValue("id", in: request), "lt.\(Constants.cursor)")
        XCTAssertEqual(SupabaseStub.queryValue("order", in: request)?.hasPrefix("id.desc"), true)
        XCTAssertEqual(SupabaseStub.queryValue("album_log_image.order", in: request)?.hasPrefix("id.asc"), true)
        XCTAssertEqual(SupabaseStub.queryValue("limit", in: request), String(Constants.pageLimit + 1))
        XCTAssertEqual(SupabaseStub.queryValue("select", in: request)?.contains("album_log_image(id,image_path)"), true)
    }

    // 첫 페이지는 id 조건 없이 조회
    func test_fetchAlbumLogs_withoutCursor_hasNoIdFilter() async throws {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response("[]", for: $0) }

        let result = try await sut.fetchAlbumLogs(
            albumId: String(Constants.albumId), cursor: nil, limit: Constants.pageLimit
        )

        let request = try XCTUnwrap(SupabaseStubURLProtocol.capturedRequests.last)
        XCTAssertNil(SupabaseStub.queryValue("id", in: request))
        XCTAssertTrue(result.content.isEmpty)
        XCTAssertFalse(result.hasNext)
    }

    // 서버 오류 -> throw
    func test_fetchAlbumLogs_serverError_throws() async {
        SupabaseStubURLProtocol.handler = { SupabaseStub.response(Self.errorJSON, statusCode: 500, for: $0) }

        do {
            _ = try await sut.fetchAlbumLogs(
                albumId: String(Constants.albumId), cursor: nil, limit: Constants.pageLimit
            )
            XCTFail("에러가 throw되어야 합니다")
        } catch {}
    }

    // MARK: - saveLog

    // 사진을 본인 폴더에 순서대로 업로드한 뒤 같은 순서의 경로로 로그 작성 함수 호출
    func test_saveLog_withPhotos_uploadsInOrderAndCreatesLog() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("POST", Path.createAlbumLog):
                return SupabaseStub.response("\(Constants.albumLogId)", for: request)
            case ("POST", _) where path.hasPrefix(Path.logImagesObjectPrefix):
                return SupabaseStub.response(Self.uploadJSON, for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.saveLog(request: Self.makeSaveRequest(photoCount: 2))

        let requests = SupabaseStubURLProtocol.capturedRequests
        let uploadedPaths = Self.uploadedPaths(in: requests)
        XCTAssertEqual(uploadedPaths.count, 2)
        XCTAssertTrue(uploadedPaths.allSatisfy { $0.hasPrefix("\(Constants.memberId)/") && $0.hasSuffix(".jpg") })

        let rpc = try XCTUnwrap(requests.first { $0.url?.path == Path.createAlbumLog })
        XCTAssertEqual(requests.last, rpc)
        let body = try SupabaseStub.jsonBody(of: rpc)
        XCTAssertEqual(body["p_album_id"] as? Int, Constants.albumId)
        XCTAssertEqual(body["p_description"] as? String, Constants.logText)
        XCTAssertEqual(body["p_image_paths"] as? [String], uploadedPaths)
    }

    // 사진 없음 -> 업로드 없이 빈 경로 목록으로 로그 작성
    func test_saveLog_withoutPhotos_createsLogOnly() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            guard request.url?.path == Path.createAlbumLog else { throw URLError(.badServerResponse) }
            return SupabaseStub.response("\(Constants.albumLogId)", for: request)
        }

        try await sut.saveLog(request: Self.makeSaveRequest(photoCount: 0))

        let requests = SupabaseStubURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 1)
        let body = try SupabaseStub.jsonBody(of: try XCTUnwrap(requests.first))
        XCTAssertEqual(body["p_image_paths"] as? [String], [])
    }

    // 업로드 중간 실패 -> 이미 올린 사진 정리, 로그 작성 함수 호출 없이 throw
    func test_saveLog_uploadFailsMidway_removesUploadedPhotos() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("POST", _) where path.hasPrefix(Path.logImagesObjectPrefix):
                // 두 번째 업로드부터 실패
                let isFirstUpload = Self.uploadedPaths(in: SupabaseStubURLProtocol.capturedRequests).count == 1
                return isFirstUpload
                    ? SupabaseStub.response(Self.uploadJSON, for: request)
                    : SupabaseStub.response(Self.errorJSON, statusCode: 500, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        do {
            try await sut.saveLog(request: Self.makeSaveRequest(photoCount: 3))
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        let requests = SupabaseStubURLProtocol.capturedRequests
        let uploadedPaths = Self.uploadedPaths(in: requests)
        XCTAssertEqual(uploadedPaths.count, 2)
        let remove = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), [uploadedPaths[0]])
        XCTAssertFalse(requests.contains { $0.url?.path == Path.createAlbumLog })
    }

    // 로그 작성 실패 -> 올린 사진 모두 정리 후 throw
    func test_saveLog_createFails_removesUploadedPhotos() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("POST", Path.createAlbumLog):
                return SupabaseStub.response(Self.errorJSON, statusCode: 400, for: request)
            case ("POST", _) where path.hasPrefix(Path.logImagesObjectPrefix):
                return SupabaseStub.response(Self.uploadJSON, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        do {
            try await sut.saveLog(request: Self.makeSaveRequest(photoCount: 2))
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        let requests = SupabaseStubURLProtocol.capturedRequests
        let remove = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), Self.uploadedPaths(in: requests))
    }

    // MARK: - updateLog

    // 새 사진 업로드 -> 텍스트·사진 변경 함수 호출 -> 삭제된 기존 사진 파일 정리
    func test_updateLog_replacesPhotosAndRemovesDeletedFiles() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        let removedPaths = ["\(Constants.memberId)/old1.jpg", "\(Constants.memberId)/old2.jpg"]
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("POST", Path.updateAlbumLog):
                return SupabaseStub.response(#"["\#(removedPaths[0])","\#(removedPaths[1])"]"#, for: request)
            case ("POST", _) where path.hasPrefix(Path.logImagesObjectPrefix):
                return SupabaseStub.response(Self.uploadJSON, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.updateLog(request: Self.makeUpdateRequest(newPhotoCount: 1, removeImageIds: [3, 4]))

        let requests = SupabaseStubURLProtocol.capturedRequests
        let uploadedPaths = Self.uploadedPaths(in: requests)
        XCTAssertEqual(uploadedPaths.count, 1)

        let rpc = try XCTUnwrap(requests.first { $0.url?.path == Path.updateAlbumLog })
        let body = try SupabaseStub.jsonBody(of: rpc)
        XCTAssertEqual(body["p_album_log_id"] as? Int, Constants.albumLogId)
        XCTAssertEqual(body["p_description"] as? String, Constants.logText)
        XCTAssertEqual(body["p_remove_image_ids"] as? [Int], [3, 4])
        XCTAssertEqual(body["p_new_image_paths"] as? [String], uploadedPaths)

        let remove = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(requests.last, remove)
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), removedPaths)
    }

    // 사진 변경 없음 -> 업로드·파일 정리 없이 텍스트만 변경
    func test_updateLog_textOnly_skipsStorage() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            guard request.url?.path == Path.updateAlbumLog else { throw URLError(.badServerResponse) }
            return SupabaseStub.response("[]", for: request)
        }

        try await sut.updateLog(request: Self.makeUpdateRequest(newPhotoCount: 0, removeImageIds: []))

        let requests = SupabaseStubURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 1)
        let body = try SupabaseStub.jsonBody(of: try XCTUnwrap(requests.first))
        XCTAssertEqual(body["p_new_image_paths"] as? [String], [])
        XCTAssertEqual(body["p_remove_image_ids"] as? [Int], [])
    }

    // 로그 변경 실패(본인 로그 아님 등) -> 새로 올린 사진만 정리 후 throw
    func test_updateLog_updateFails_removesNewPhotosOnly() async throws {
        try await SupabaseStub.signIn(client, memberId: Constants.memberId)
        SupabaseStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("POST", Path.updateAlbumLog):
                return SupabaseStub.response(Self.errorJSON, statusCode: 400, for: request)
            case ("POST", _) where path.hasPrefix(Path.logImagesObjectPrefix):
                return SupabaseStub.response(Self.uploadJSON, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        do {
            try await sut.updateLog(request: Self.makeUpdateRequest(newPhotoCount: 2, removeImageIds: [3]))
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        let requests = SupabaseStubURLProtocol.capturedRequests
        let removals = requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(removals.count, 1)
        XCTAssertEqual(try SupabaseStub.removedPaths(of: try XCTUnwrap(removals.first)), Self.uploadedPaths(in: requests))
    }

    // MARK: - deleteAlbumLog

    // 사진 경로 조회 -> 로그 삭제 -> 사진 파일 정리 순서로 진행
    func test_deleteAlbumLog_deletesRowThenRemovesFiles() async throws {
        let imagePaths = ["\(Constants.memberId)/a.jpg", "\(Constants.memberId)/b.jpg"]
        let filesJSON = #"{"album_log_image":[{"image_path":"\#(imagePaths[0])"},{"image_path":"\#(imagePaths[1])"}]}"#
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.albumLog):
                return SupabaseStub.response(filesJSON, for: request)
            case ("DELETE", Path.albumLog):
                return SupabaseStub.response(#"{"id":\#(Constants.albumLogId)}"#, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response("[]", for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.deleteAlbumLog(albumId: String(Constants.albumId), albumLogId: Constants.albumLogId)

        let requests = SupabaseStubURLProtocol.capturedRequests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "DELETE", "DELETE"])

        let select = requests[0]
        XCTAssertEqual(SupabaseStub.queryValue("id", in: select), "eq.\(Constants.albumLogId)")
        XCTAssertEqual(SupabaseStub.queryValue("album_id", in: select), "eq.\(Constants.albumId)")

        let deleteRow = requests[1]
        XCTAssertEqual(deleteRow.url?.path, Path.albumLog)
        XCTAssertEqual(SupabaseStub.queryValue("id", in: deleteRow), "eq.\(Constants.albumLogId)")

        let remove = requests[2]
        XCTAssertEqual(remove.url?.path, Path.removeLogImages)
        XCTAssertEqual(try SupabaseStub.removedPaths(of: remove), imagePaths)
    }

    // 본인 로그가 아님(조회 0건) -> 삭제·파일 정리 없이 throw
    func test_deleteAlbumLog_notOwnLog_throwsWithoutDeleting() async throws {
        SupabaseStubURLProtocol.handler = { request in
            guard request.httpMethod == "GET" else { throw URLError(.badServerResponse) }
            return SupabaseStub.response(Self.notFoundJSON, statusCode: 406, for: request)
        }

        do {
            try await sut.deleteAlbumLog(albumId: String(Constants.albumId), albumLogId: Constants.albumLogId)
            XCTFail("에러가 throw되어야 합니다")
        } catch {}

        XCTAssertFalse(SupabaseStubURLProtocol.capturedRequests.contains { $0.httpMethod == "DELETE" })
    }

    // 사진 파일 정리 실패 -> 로그 삭제는 성공 처리
    func test_deleteAlbumLog_fileRemovalFails_stillSucceeds() async throws {
        let filesJSON = #"{"album_log_image":[{"image_path":"\#(Constants.memberId)/a.jpg"}]}"#
        SupabaseStubURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("GET", Path.albumLog):
                return SupabaseStub.response(filesJSON, for: request)
            case ("DELETE", Path.albumLog):
                return SupabaseStub.response(#"{"id":\#(Constants.albumLogId)}"#, for: request)
            case ("DELETE", Path.removeLogImages):
                return SupabaseStub.response(Self.errorJSON, statusCode: 500, for: request)
            default:
                throw URLError(.badServerResponse)
            }
        }

        try await sut.deleteAlbumLog(albumId: String(Constants.albumId), albumLogId: Constants.albumLogId)
    }

    // MARK: - Helpers

    private static let errorJSON = #"{"message":"server error"}"#
    private static let notFoundJSON =
        #"{"code":"PGRST116","message":"JSON object requested, multiple (or no) rows returned","details":null,"hint":null}"#
    private static let uploadJSON = #"{"Key":"log-images/uploaded.jpg","Id":"1"}"#

    private static func logJSON(id: Int) -> String {
        #"{"id":\#(id),"description":"기록\#(id)","created_at":"2026-11-25T03:12:45+00:00","album_log_image":[]}"#
    }

    private static func makeSaveRequest(photoCount: Int) -> AlbumLogRequest {
        AlbumLogRequest(
            albumId: String(Constants.albumId),
            logText: Constants.logText,
            photoDataList: (0..<photoCount).map { Data([UInt8($0)]) }
        )
    }

    private static func makeUpdateRequest(newPhotoCount: Int, removeImageIds: [Int64]) -> AlbumLogUpdateRequest {
        AlbumLogUpdateRequest(
            albumId: String(Constants.albumId),
            albumLogId: Constants.albumLogId,
            logText: Constants.logText,
            newPhotoDataList: (0..<newPhotoCount).map { Data([UInt8($0)]) },
            removeImageIds: removeImageIds
        )
    }

    // 로그 사진 업로드 요청의 저장 경로 목록 (요청 순서)
    private static func uploadedPaths(in requests: [URLRequest]) -> [String] {
        requests.compactMap { request in
            guard request.httpMethod == "POST",
                  let path = request.url?.path,
                  path.hasPrefix(Path.logImagesObjectPrefix) else { return nil }
            return String(path.dropFirst(Path.logImagesObjectPrefix.count))
        }
    }
}
