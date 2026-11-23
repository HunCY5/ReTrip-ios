//
//  LoginViewModel.swift
//  VibeTrip
//
//  Created by CHOI on 3/15/26.
//

// 로그인 화면 비즈니스 로직 담당
// 플로우: 소셜 로그인 -> Supabase 세션 발급 -> 결과 처리

import Foundation
import UIKit
import Combine
import FirebaseMessaging

@MainActor
final class LoginViewModel: ObservableObject {
    
    // MARK: - Published
    
    // 로그인 진행 여부: 버튼 비활성화 + 스피너 표시
    @Published var isLoading: Bool = false
    
    // 에러 발생 시 표시할 UI 결정
    @Published var errorState: LoginErrorState? = nil {   /// nil: 에러 UI X
        didSet {
            if case .toast = errorState {
                scheduleToastDismissal()
            }
        }
    }

    // 로그인 성공 시 true -> fullScreenCover 전환 트리거
    @Published var isLoggedIn: Bool = false

    // MARK: - Private

    private var toastTask: Task<Void, Never>?
    private var lastLoginProvider: LoginProvider?

    // MARK: - Dependencies
    
    private let kakaoAuthService: KakaoAuthServiceProtocol
    private let appleAuthService: AppleAuthServiceProtocol
    private let sessionAuthService: SessionAuthServiceProtocol
    private let fcmTokenProvider: () async -> String

    // MARK: - Init

    init(
        kakaoAuthService: KakaoAuthServiceProtocol? = nil,
        appleAuthService: AppleAuthServiceProtocol? = nil,
        sessionAuthService: SessionAuthServiceProtocol? = nil,
        fcmTokenProvider: (() async -> String)? = nil
    ) {
        self.kakaoAuthService = kakaoAuthService ?? KakaoAuthService()
        self.appleAuthService = appleAuthService ?? AppleAuthService()
        self.sessionAuthService = sessionAuthService ?? SupabaseAuthService()
        self.fcmTokenProvider = fcmTokenProvider ?? {
            (try? await Messaging.messaging().token()) ?? ""
        }
    }
    
    // MARK: - 카카오 로그인
    
    func loginWithKakao() {
        guard !isLoading else { return }
        lastLoginProvider = .kakao
        Task { await performKakaoLogin() }
    }

    // MARK: - 애플 로그인

    // AppleAuthService를 통한 애플 로그인
    func loginWithApple() {
        guard !isLoading else { return }
        lastLoginProvider = .apple
        Task { await performAppleLogin() }
    }

    // 재시도
    func retryLogin() {
        switch lastLoginProvider {
        case .kakao: loginWithKakao()
        case .apple: loginWithApple()
        case nil: break
        }
    }

    // MARK: - 토스트 자동 닫힘

    private func scheduleToastDismissal() {
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            if case .toast = errorState {
                errorState = nil
            }
        }
    }

    // MARK: - 로그인 플로우

    private func performKakaoLogin() async {
        isLoading = true
        errorState = nil
        defer { isLoading = false }

        do {
            /// 카카오 idToken 획득 (해시된 nonce 포함)
            let nonce = NonceGenerator.make()
            let (idToken, accessToken) = try await kakaoAuthService.login(nonce: nonce.hashed)
            #if DEBUG
            print("카카오 idToken: \(idToken)")
            #endif
            try await performSessionAuth(
                credential: SocialLoginCredential(
                    provider: .kakao,
                    idToken: idToken,
                    accessToken: accessToken,
                    nonce: nonce.raw,
                    fullName: nil
                )
            )
        } catch let loginError as LoginError {
            if case .cancelled = loginError { return }
            errorState = loginError.errorState
        } catch {
            errorState = LoginError.providerError.errorState
        }
    }

    private func performAppleLogin() async {
        isLoading = true
        errorState = nil
        defer { isLoading = false }

        do {
            let nonce = NonceGenerator.make()
            let (identityToken, fullName) = try await appleAuthService.login(nonce: nonce.hashed)
            #if DEBUG
            print("애플 identityToken: \(identityToken)")
            print("애플 fullName: \(fullName ?? "null")")
            #endif
            try await performSessionAuth(
                credential: SocialLoginCredential(
                    provider: .apple,
                    idToken: identityToken,
                    accessToken: nil,
                    nonce: nonce.raw,
                    fullName: fullName
                )
            )
        } catch let loginError as LoginError {
            /// 취소: 에러 UI 없이 그대로 로그인 화면 유지
            if case .cancelled = loginError { return }
            errorState = loginError.errorState
        } catch {
            errorState = LoginError.providerError.errorState
        }
    }

    // FCM 토큰 획득, 실패 시 빈 문자열 반환
    private func fetchFCMToken() async -> String {
        await fcmTokenProvider()
    }

    // 카카오&애플 공통 Supabase 세션 발급 + 기기 등록
    private func performSessionAuth(credential: SocialLoginCredential) async throws {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let fcmToken = await fetchFCMToken()
        #if DEBUG
        print("deviceId: \(deviceId)")
        print("fcmToken: \(fcmToken)")
        print("Supabase 세션 요청. provider: \(credential.provider.rawValue)")
        #endif

        try await sessionAuthService.signIn(with: credential, deviceId: deviceId, fcmToken: fcmToken)
        isLoggedIn = true
    }
}
