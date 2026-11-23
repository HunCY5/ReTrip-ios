//
//  MyPageViewModelTests.swift
//  VibeTrip
//
//  Created by CHOI on 4/3/26.
//

import XCTest
@testable import VibeTrip

@MainActor
final class MyPageViewModelTests: XCTestCase {

    private var mockUserService: MockUserService!
    private var mockKeychainService: MockKeychainService!
    private var mockSessionAuthService: MockSessionAuthService!
    private var sut: MyPageViewModel!

    override func setUp() {
        super.setUp()
        mockUserService = MockUserService()
        mockKeychainService = MockKeychainService()
        mockSessionAuthService = MockSessionAuthService()
        sut = MyPageViewModel(
            userService: mockUserService,
            keychainService: mockKeychainService,
            sessionAuthService: mockSessionAuthService
        )
    }

    override func tearDown() {
        mockUserService = nil
        mockKeychainService = nil
        mockSessionAuthService = nil
        sut = nil
        super.tearDown()
    }

    // 프로필 조회 성공 시 userProfile, albumCount, logCount 정상 설정
    func test_loadProfile_success() async {
        await sut.loadProfile()

        XCTAssertNotNil(sut.userProfile)
        XCTAssertEqual(sut.userProfile?.nickname, UserProfile.mock.nickname)
        XCTAssertEqual(sut.userProfile?.email, UserProfile.mock.email)
        XCTAssertEqual(sut.albumCount, UserProfile.mock.albumCount)
        XCTAssertEqual(sut.logCount, UserProfile.mock.albumLogCount)
        XCTAssertNil(sut.toastMessage)
    }

    // 프로필 조회 실패 시 토스트 메시지 표시
    func test_loadProfile_failure_showsToast() async {
        mockUserService.stubbedError = APIClientError.networkError(URLError(.notConnectedToInternet))

        await sut.loadProfile()

        XCTAssertNil(sut.userProfile)
        XCTAssertEqual(sut.toastMessage, "프로필을 불러오지 못했어요.")
    }

    // 프로필 조회 중 isLoading 상태 전환
    func test_loadProfile_togglesIsLoading() async {
        XCTAssertFalse(sut.isLoading)

        await sut.loadProfile()

        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - 로그아웃

    // 로그아웃 Task 종료 대기 헬퍼 (최대 1초)
    private func waitForLogout(_ appState: AppState) async {
        for _ in 0..<100 where appState.isLoggedIn != false {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // 로그아웃: 현재 기기 기준 세션 종료 요청 후 로그인 화면 전환 및 완료 토스트
    func test_logout_signsOutAndShowsLoginScreen() async {
        let appState = AppState(sessionAuthService: MockSessionAuthService())
        appState.isLoggedIn = true

        sut.logout(appState: appState)
        await waitForLogout(appState)

        XCTAssertEqual(mockSessionAuthService.signedOutDeviceId, UIDevice.current.identifierForVendor?.uuidString ?? "")
        XCTAssertEqual(appState.isLoggedIn, false)
        XCTAssertEqual(appState.toastPayload?.message, "로그아웃이 완료되었습니다")
        XCTAssertFalse(sut.isLoading)
    }

    // 로그아웃: 기존 서버 토큰도 함께 제거
    func test_logout_clearsLegacyKeychainTokens() async {
        let appState = AppState(sessionAuthService: MockSessionAuthService())
        appState.isLoggedIn = true

        sut.logout(appState: appState)
        await waitForLogout(appState)

        XCTAssertNil(mockKeychainService.accessToken)
        XCTAssertNil(mockKeychainService.refreshToken)
    }
}
