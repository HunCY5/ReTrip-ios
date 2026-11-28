//
//  AlbumServiceTests.swift
//  VibeTrip
//
//  Created by CHOI on 3/31/26.
//

import XCTest
import Combine
@testable import VibeTrip

// MARK: - MockAPIClient

// 테스트용 Mock -> APIClientProtocol 대체
// requestResult: request() 호출 시 반환할 성공 or 실패 결과 주입
// uploadResult:  upload()  호출 시 반환할 성공 or 실패 결과 주입
final class MockAPIClient: APIClientProtocol {

    // request 호출 시 반환할 결과 -> Any로 보관 후 T로 캐스팅
    var requestResult: Result<Any, Error> = .failure(APIClientError.decodingFailed)

    // upload 호출 시 반환할 결과
    var uploadResult: Result<AlbumCreateResponse, Error> = .success(AlbumCreateResponse(albumId: 0))

    // 호출 횟수 및 마지막으로 전달된 endpoint 기록
    private(set) var requestCallCount = 0
    private(set) var uploadCallCount = 0
    private(set) var capturedEndpoints: [APIEndpoint] = []
    private(set) var capturedUploadFormData: MultipartFormData?

    var sessionExpiredPublisher: AnyPublisher<Void, Never> {
        PassthroughSubject<Void, Never>().eraseToAnyPublisher()
    }

    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        requestCallCount += 1
        capturedEndpoints.append(endpoint)
        switch requestResult {
        case .success(let value):
            guard let typed = value as? T else {
                throw APIClientError.decodingFailed
            }
            return typed
        case .failure(let error):
            throw error
        }
    }

    func upload<T: Decodable>(_ endpoint: APIEndpoint, formData: MultipartFormData) async throws -> T {
        uploadCallCount += 1
        capturedUploadFormData = formData
        switch uploadResult {
        case .success(let response):
            guard let typed = response as? T else {
                throw APIClientError.decodingFailed
            }
            return typed
        case .failure(let error):
            throw error
        }
    }

    // perform 호출 시 반환할 결과
    var performResult: Result<Void, Error> = .success(())
    private(set) var performCallCount = 0

    func perform(_ endpoint: APIEndpoint) async throws {
        performCallCount += 1
        capturedEndpoints.append(endpoint)
        if case .failure(let error) = performResult { throw error }
    }

    // performUpload 호출 시 반환할 결과
    var performUploadResult: Result<Void, Error> = .success(())
    private(set) var performUploadCallCount = 0
    private(set) var capturedFormData: MultipartFormData?

    func performUpload(_ endpoint: APIEndpoint, formData: MultipartFormData) async throws {
        performUploadCallCount += 1
        capturedEndpoints.append(endpoint)
        capturedFormData = formData
        if case .failure(let error) = performUploadResult { throw error }
    }
}

// MARK: - AlbumServiceTests

final class AlbumServiceTests: XCTestCase {

    var mockAPIClient: MockAPIClient!
    var sut: AlbumService!

    override func setUp() {
        super.setUp()
        mockAPIClient = MockAPIClient()
        sut = AlbumService(apiClient: mockAPIClient, supabase: SupabaseTestClient.make())
    }

    override func tearDown() {
        mockAPIClient = nil
        sut = nil
        super.tearDown()
    }

    // 테스트용 AlbumCreateRequest 기본값
    private func makeRequest() -> AlbumCreateRequest {
        AlbumCreateRequest(
            photoData: Data([0x00, 0x01]),
            location: "서울",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 86400),
            lyricsOption: .include,
            vocalGender: .female,
            genre: .kPop,
            comment: "테스트 코멘트"
        )
    }

    private struct CapturedGenreBody: Decodable {
        let genre: String
    }

    private func decodeRequestPart<T: Decodable>(_ type: T.Type, from formData: MultipartFormData?) throws -> T {
        guard let part = formData?.parts.first(where: { $0.name == "request" }) else {
            XCTFail("request 파트를 찾을 수 없습니다")
            throw APIClientError.decodingFailed
        }
        return try JSONDecoder().decode(T.self, from: part.data)
    }

    // MARK: - 성공

    // 정상 응답 -> albumId를 포함한 AlbumCreateResponse 반환
    func test_createAlbum_success_returnsAlbumId() async throws {
        mockAPIClient.uploadResult = .success(AlbumCreateResponse(albumId: 42))

        let response = try await sut.createAlbum(request: makeRequest())

        XCTAssertEqual(response.albumId, 42)
        XCTAssertEqual(mockAPIClient.uploadCallCount, 1)
    }

    // MARK: - 서버 에러

    // 서버가 에러 응답 반환 -> APIClientError.serverError throw
    func test_createAlbum_serverError_throwsServerError() async throws {
        mockAPIClient.uploadResult = .failure(APIClientError.serverError(.e400))

        do {
            _ = try await sut.createAlbum(request: makeRequest())
            XCTFail("서버 에러가 throw되어야 합니다")
        } catch APIClientError.serverError(let code) {
            XCTAssertEqual(code, .e400)
        } catch {
            XCTFail("예상치 못한 에러: \(error)")
        }
    }

    // MARK: - 네트워크 에러

    // 네트워크 연결 불가 -> APIClientError.networkError throw
    func test_createAlbum_networkError_throwsNetworkError() async throws {
        let urlError = URLError(.notConnectedToInternet)
        mockAPIClient.uploadResult = .failure(APIClientError.networkError(urlError))

        do {
            _ = try await sut.createAlbum(request: makeRequest())
            XCTFail("네트워크 에러가 throw되어야 합니다")
        } catch APIClientError.networkError(let error) {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("예상치 못한 에러: \(error)")
        }
    }

    // MARK: - 날짜 포맷

    // "yyyy-MM-dd" 형식으로 서버에 전달되는지 검증
    func test_createAlbum_dateFormatting_doesNotThrow() async throws {
        mockAPIClient.uploadResult = .success(AlbumCreateResponse(albumId: 1))

        // 특정 날짜로 요청 생성 (날짜 포맷 오류 시 throw)
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2025; components.month = 12; components.day = 31
        let date = calendar.date(from: components)!

        let request = AlbumCreateRequest(
            photoData: Data([0x00]),
            location: "제주",
            startDate: date,
            endDate: date,
            lyricsOption: .exclude,
            vocalGender: nil,
            genre: .jazz,
            comment: ""
        )

        let response = try await sut.createAlbum(request: request)
        XCTAssertEqual(response.albumId, 1)
    }

    // Jazz + 가사 미포함 요청 시 genre는 JAZZ_NO_VOCAL로 전송
    func test_createAlbum_excludeLyricsJazz_sendsJazzNoVocalGenre() async throws {
        mockAPIClient.uploadResult = .success(AlbumCreateResponse(albumId: 1))
        let request = AlbumCreateRequest(
            photoData: Data([0x00]),
            location: "제주",
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 86400),
            lyricsOption: .exclude,
            vocalGender: nil,
            genre: .jazz,
            comment: ""
        )

        _ = try await sut.createAlbum(request: request)
        let body = try decodeRequestPart(CapturedGenreBody.self, from: mockAPIClient.capturedUploadFormData)
        XCTAssertEqual(body.genre, "JAZZ_NO_VOCAL")
    }

    // MARK: - vocalGender 없음

    // vocalGender nil -> 서버에 "N"으로 전달
    func test_createAlbum_nilVocalGender_doesNotThrow() async throws {
        mockAPIClient.uploadResult = .success(AlbumCreateResponse(albumId: 7))

        let request = AlbumCreateRequest(
            photoData: Data([0x00]),
            location: "부산",
            startDate: Date(),
            endDate: Date(),
            lyricsOption: .exclude,
            vocalGender: nil,   // 정상: "N"으로 변환
            genre: .pop,
            comment: ""
        )

        let response = try await sut.createAlbum(request: request)
        XCTAssertEqual(response.albumId, 7)
        XCTAssertEqual(mockAPIClient.uploadCallCount, 1)
    }
}
