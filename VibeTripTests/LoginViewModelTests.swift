//
//  LoginViewModelTests.swift
//  VibeTripTests
//
//  Created by CHOI on 3/19/26.
//


import XCTest
import CryptoKit
@testable import VibeTrip

// MARK: - Mock

final class MockKakaoAuthService: KakaoAuthServiceProtocol {
    var result: Result<(idToken: String, accessToken: String), Error> = .success((idToken: "mock-kakao-id-token", accessToken: "mock-kakao-token"))
    private(set) var receivedNonce: String?
    func login(nonce: String) async throws -> (idToken: String, accessToken: String) {
        receivedNonce = nonce
        return try result.get()
    }
}

final class MockAppleAuthService: AppleAuthServiceProtocol {
    var result: Result<(identityToken: String, fullName: String?), Error> = .success((identityToken: "mock-apple-id-token", fullName: "홍 길동"))
    private(set) var receivedNonce: String?
    func login(nonce: String) async throws -> (identityToken: String, fullName: String?) {
        receivedNonce = nonce
        return try result.get()
    }
}

// MARK: - Tests

@MainActor
final class LoginViewModelTests: XCTestCase {

    // ViewModel 생성 헬퍼
    func makeViewModel(
        kakaoResult: Result<(idToken: String, accessToken: String), Error> = .success((idToken: "mock-kakao-id-token", accessToken: "mock-kakao-token")),
        backendError: LoginError? = nil
    ) -> LoginViewModel {
        let kakao = MockKakaoAuthService()
        kakao.result = kakaoResult

        let session = MockSessionAuthService()
        session.simulatedError = backendError
        session.delay = 0   // 테스트에서 딜레이 제거

        return LoginViewModel(
            kakaoAuthService: kakao,
            sessionAuthService: session,
            fcmTokenProvider: { "test-fcm-token" }
        )
    }

    // Mock 호출 내역 검증용 생성 헬퍼
    func makeSUT(
        appleResult: Result<(identityToken: String, fullName: String?), Error> = .success((identityToken: "mock-apple-id-token", fullName: "홍 길동")),
        sessionError: LoginError? = nil
    ) -> (vm: LoginViewModel, kakao: MockKakaoAuthService, apple: MockAppleAuthService, session: MockSessionAuthService) {
        let kakao = MockKakaoAuthService()
        let apple = MockAppleAuthService()
        apple.result = appleResult

        let session = MockSessionAuthService()
        session.simulatedError = sessionError
        session.delay = 0

        let vm = LoginViewModel(
            kakaoAuthService: kakao,
            appleAuthService: apple,
            sessionAuthService: session,
            fcmTokenProvider: { "test-fcm-token" }
        )
        return (vm, kakao, apple, session)
    }

    // 원본 nonce -> 소셜 로그인에 전달되는 해시값 계산 (SHA-256 16진수)
    func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // 로그인 Task 시작/종료를 기다리는 대기 헬퍼
    func waitForTask(_ vm: LoginViewModel) async {
        // Task가 아직 시작 전일 수 있어 한 번 양보
        await Task.yield()

        // isLoading=true 전환 대기 (최대 1초)
        for _ in 0..<100 where !vm.isLoading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Task 종료 대기 (최대 3초)
        for _ in 0..<300 where vm.isLoading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 테스트 케이스

    // 카카오 로그인 성공:  isLoggedIn == true, errorState == nil
    func test_success_isLoggedIn() async {
        let vm = makeViewModel()
        vm.loginWithKakao()
        await waitForTask(vm)

        XCTAssertTrue(vm.isLoggedIn)
        XCTAssertNil(vm.errorState)
        XCTAssertFalse(vm.isLoading)
    }

    // 카카오 취소: errorState == nil, isLoggedIn == false
    func test_cancelled_noErrorUI() async {
        let vm = makeViewModel(kakaoResult: .failure(LoginError.cancelled))
        vm.loginWithKakao()
        await waitForTask(vm)

        XCTAssertNil(vm.errorState)
        XCTAssertFalse(vm.isLoggedIn)
    }

    // 카카오 공급자 오류(toast)
    func test_providerError_showsToast() async {
        let vm = makeViewModel(kakaoResult: .failure(LoginError.providerError))
        vm.loginWithKakao()
        await waitForTask(vm)

        if case .toast(let msg) = vm.errorState {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("toast가 표시되어야 합니다. 실제: \(String(describing: vm.errorState))")
        }
    }

    // 백엔드 네트워크 오류(toast)
    func test_networkError_showsToast() async {
        let vm = makeViewModel(backendError: .networkError)
        vm.loginWithKakao()
        await waitForTask(vm)

        if case .toast(let msg) = vm.errorState {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("toast가 표시되어야 합니다. 실제: \(String(describing: vm.errorState))")
        }
    }

    // 백엔드 타임아웃 (PopUp)
    func test_timeout_showsRetryPopup() async {
        let vm = makeViewModel(backendError: .timeout)
        vm.loginWithKakao()
        await waitForTask(vm)

        if case .retryPopup(let msg) = vm.errorState {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("retryPopup이 표시되어야 합니다. 실제: \(String(describing: vm.errorState))")
        }
    }

    // MARK: - Supabase 세션 발급 요청 검증

    // 카카오: idToken·accessToken과 nonce 원본으로 세션 발급, 카카오에는 해시된 nonce 전달
    func test_kakao_sendsCredentialWithMatchingNonce() async {
        let sut = makeSUT()
        sut.vm.loginWithKakao()
        await waitForTask(sut.vm)

        guard let credential = sut.session.lastCredential else {
            return XCTFail("세션 발급 요청이 호출되어야 합니다.")
        }
        XCTAssertEqual(credential.provider, .kakao)
        XCTAssertEqual(credential.idToken, "mock-kakao-id-token")
        XCTAssertEqual(credential.accessToken, "mock-kakao-token")
        XCTAssertNil(credential.fullName)
        XCTAssertEqual(sut.kakao.receivedNonce, sha256(credential.nonce))
    }

    // 카카오 취소: 세션 발급 요청 X
    func test_kakaoCancelled_doesNotRequestSession() async {
        let sut = makeSUT()
        sut.kakao.result = .failure(LoginError.cancelled)
        sut.vm.loginWithKakao()
        await waitForTask(sut.vm)

        XCTAssertNil(sut.session.lastCredential)
        XCTAssertFalse(sut.vm.isLoggedIn)
    }

    // MARK: - 애플 로그인

    // 애플 로그인 성공: isLoggedIn == true, errorState == nil
    func test_apple_success_isLoggedIn() async {
        let sut = makeSUT()
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        XCTAssertTrue(sut.vm.isLoggedIn)
        XCTAssertNil(sut.vm.errorState)
    }

    // 애플: identityToken·이름과 nonce 원본으로 세션 발급, 애플에는 해시된 nonce 전달
    func test_apple_sendsCredentialWithFullNameAndMatchingNonce() async {
        let sut = makeSUT()
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        guard let credential = sut.session.lastCredential else {
            return XCTFail("세션 발급 요청이 호출되어야 합니다.")
        }
        XCTAssertEqual(credential.provider, .apple)
        XCTAssertEqual(credential.idToken, "mock-apple-id-token")
        XCTAssertNil(credential.accessToken)
        XCTAssertEqual(credential.fullName, "홍 길동")
        XCTAssertEqual(sut.apple.receivedNonce, sha256(credential.nonce))
    }

    // 애플 재로그인(이름 미제공): 이름 없이 세션 발급
    func test_apple_withoutFullName_sendsNilName() async {
        let sut = makeSUT(appleResult: .success((identityToken: "mock-apple-id-token", fullName: nil)))
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        XCTAssertNotNil(sut.session.lastCredential)
        XCTAssertNil(sut.session.lastCredential?.fullName)
    }

    // 애플 취소: errorState == nil, 세션 발급 요청 X
    func test_apple_cancelled_noErrorUI() async {
        let sut = makeSUT(appleResult: .failure(LoginError.cancelled))
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        XCTAssertNil(sut.vm.errorState)
        XCTAssertNil(sut.session.lastCredential)
        XCTAssertFalse(sut.vm.isLoggedIn)
    }

    // 애플 세션 발급 네트워크 오류(toast)
    func test_apple_sessionNetworkError_showsToast() async {
        let sut = makeSUT(sessionError: .networkError)
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        if case .toast(let msg) = sut.vm.errorState {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("toast가 표시되어야 합니다. 실제: \(String(describing: sut.vm.errorState))")
        }
        XCTAssertFalse(sut.vm.isLoggedIn)
    }

    // 애플 실패 후 재시도: 마지막 로그인 제공자(애플)로 다시 요청
    func test_retryLogin_afterApple_retriesApple() async {
        let sut = makeSUT(sessionError: .timeout)
        sut.vm.loginWithApple()
        await waitForTask(sut.vm)

        sut.session.simulatedError = nil
        sut.vm.retryLogin()
        await waitForTask(sut.vm)

        XCTAssertEqual(sut.session.lastCredential?.provider, .apple)
        XCTAssertTrue(sut.vm.isLoggedIn)
    }
}
