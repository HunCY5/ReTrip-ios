//
//  AuthServiceProtocol.swift
//  VibeTrip
//
//  Created by CHOI on 3/15/26.
//


// 소셜 로그인 및 세션 인증 기능 인터페이스 정의

import Foundation

// MARK: - 소셜 로그인 프로토콜

// 카카오 로그인 인터페이스
protocol KakaoAuthServiceProtocol {
    /// 카카오 로그인 실행(OpenID Connect): idToken + accessToken 반환
    /// nonce: 해시된 nonce -> 발급되는 idToken에 포함
    /// 사용자 취소 시: LoginError.cancelled throw
    func login(nonce: String) async throws -> (idToken: String, accessToken: String)
}

// 애플 로그인 인터페이스
protocol AppleAuthServiceProtocol {
    /// 애플 로그인 실행: identityToken + fullName 반환
    /// nonce: 해시된 nonce -> 발급되는 identityToken에 포함
    /// 사용자 취소 시: LoginError.cancelled throw
    func login(nonce: String) async throws -> (identityToken: String, fullName: String?)
}

// MARK: - 세션 인증 프로토콜

// 소셜 로그인 ID 토큰으로 Supabase 세션 발급 인터페이스
protocol SessionAuthServiceProtocol {
    /// 세션 발급 후 푸시 수신 기기 등록
    /// deviceId: 기기 고유 식별자
    /// fcmToken: FCM 푸시 토큰 (빈 값이면 기기 등록 생략)
    func signIn(with credential: SocialLoginCredential, deviceId: String, fcmToken: String) async throws

    /// 기기에 저장된 로그인 세션 존재 여부 (만료된 세션은 SDK가 사용 시점에 갱신)
    var hasStoredSession: Bool { get }

    /// 세션 종료 이벤트 스트림 (로그아웃, 세션 갱신 실패 등)
    func sessionEndedEvents() -> AsyncStream<Void>

    /// 로그아웃: 현재 기기의 푸시 수신 등록 해제 후 세션 종료
    func signOut(deviceId: String) async
}

// 세션 발급에 필요한 소셜 로그인 결과
struct SocialLoginCredential: Equatable {
    let provider: LoginProvider
    /// 카카오(OIDC) or 애플에서 발급된 ID 토큰
    let idToken: String
    /// (카카오) ID 토큰의 at_hash 검증용 액세스 토큰
    let accessToken: String?
    /// 로그인 요청 시 해시해서 전달한 nonce 원본
    let nonce: String
    /// (애플) 최초 로그인 시에만 제공되는 이름
    let fullName: String?
}

// MARK: - 로그인 제공자 타입

enum LoginProvider: String {
    case kakao = "kakao"
    case apple = "apple"
}
