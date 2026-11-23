//
//  UserServiceTests.swift
//  VibeTrip
//
//  Created by CHOI on 4/3/26.
//

import XCTest
@testable import VibeTrip

final class UserServiceTests: XCTestCase {

    private var mockAPIClient: MockAPIClient!
    private var sut: UserService!

    override func setUp() {
        super.setUp()
        SupabaseStubURLProtocol.reset()
        mockAPIClient = MockAPIClient()
        sut = UserService(apiClient: mockAPIClient, supabase: SupabaseTestClient.make())
    }

    override func tearDown() {
        SupabaseStubURLProtocol.reset()
        mockAPIClient = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - fetchProfile

    // get_my_profile 응답 예시
    private let profileJSON = """
    {"name":"여행자","email":"traveler@example.com","profile_image_url":"https://example.com/profile.jpg","album_count":3,"album_log_count":12}
    """

    // 정상 응답 시 UserProfile로 변환
    func test_fetchProfile_success() async throws {
        SupabaseStubURLProtocol.handler = { [profileJSON] in SupabaseTestClient.jsonResponse(profileJSON, for: $0) }

        let result = try await sut.fetchProfile()

        XCTAssertEqual(result.nickname, "여행자")
        XCTAssertEqual(result.email, "traveler@example.com")
        XCTAssertEqual(result.profileImageUrl, "https://example.com/profile.jpg")
        XCTAssertEqual(result.albumCount, 3)
        XCTAssertEqual(result.albumLogCount, 12)
    }

    // 이메일·프로필 이미지가 없는 회원
    func test_fetchProfile_nullableFields() async throws {
        let json = """
        {"name":"여행자","email":null,"profile_image_url":null,"album_count":0,"album_log_count":0}
        """
        SupabaseStubURLProtocol.handler = { SupabaseTestClient.jsonResponse(json, for: $0) }

        let result = try await sut.fetchProfile()

        XCTAssertNil(result.email)
        XCTAssertNil(result.profileImageUrl)
        XCTAssertEqual(result.albumCount, 0)
        XCTAssertEqual(result.albumLogCount, 0)
    }

    // 이름 미제공(빈 문자열·공백) 회원은 닉네임 "-" 표시
    func test_fetchProfile_emptyName_showsPlaceholder() async throws {
        for name in ["", "   "] {
            let json = """
            {"name":"\(name)","email":null,"profile_image_url":null,"album_count":0,"album_log_count":0}
            """
            SupabaseStubURLProtocol.handler = { SupabaseTestClient.jsonResponse(json, for: $0) }

            let result = try await sut.fetchProfile()

            XCTAssertEqual(result.nickname, "-")
        }
    }

    // 네트워크 에러 시 throw 확인
    func test_fetchProfile_networkError() async {
        SupabaseStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await sut.fetchProfile()
            XCTFail("에러가 발생해야 합니다")
        } catch {
            // 에러 종류와 무관하게 ViewModel에서 토스트 처리
        }
    }

    // 회원 정보가 없어 null 응답 시 throw 확인
    func test_fetchProfile_nullResponse_throws() async {
        SupabaseStubURLProtocol.handler = { SupabaseTestClient.jsonResponse("null", for: $0) }

        do {
            _ = try await sut.fetchProfile()
            XCTFail("에러가 발생해야 합니다")
        } catch {}
    }

    // get_my_profile DB 함수를 POST로 호출하는지 확인
    func test_fetchProfile_callsProfileFunction() async throws {
        SupabaseStubURLProtocol.handler = { [profileJSON] in SupabaseTestClient.jsonResponse(profileJSON, for: $0) }

        _ = try await sut.fetchProfile()

        XCTAssertEqual(SupabaseStubURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(SupabaseStubURLProtocol.capturedRequests.first?.url?.path, "/rest/v1/rpc/get_my_profile")
        XCTAssertEqual(SupabaseStubURLProtocol.capturedRequests.first?.httpMethod, "POST")
    }

    // MARK: - deleteAccount

    // 정상 응답 시 에러 없이 완료
    func test_deleteAccount_success() async {
        do {
            try await sut.deleteAccount()
        } catch {
            XCTFail("에러가 발생하면 안 됩니다: \(error)")
        }
    }

    // 네트워크 에러 시 throw 확인
    func test_deleteAccount_networkError() async {
        mockAPIClient.performResult = .failure(APIClientError.networkError(URLError(.notConnectedToInternet)))

        do {
            try await sut.deleteAccount()
            XCTFail("에러가 발생해야 합니다")
        } catch let error as APIClientError {
            guard case .networkError = error else {
                XCTFail("networkError여야 합니다")
                return
            }
        } catch {
            XCTFail("예상치 못한 에러: \(error)")
        }
    }

    // 올바른 엔드포인트(path, method) 호출 확인
    func test_deleteAccount_callsCorrectEndpoint() async throws {
        try await sut.deleteAccount()

        XCTAssertEqual(mockAPIClient.capturedEndpoints.last?.path, "/api/v1/members/me/withdraw")
        XCTAssertEqual(mockAPIClient.capturedEndpoints.last?.method, .delete)
    }
}
