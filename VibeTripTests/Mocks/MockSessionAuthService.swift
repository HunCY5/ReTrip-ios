//
//  MockSessionAuthService.swift
//  VibeTrip
//
//  Created by CHOI on 11/23/26.
//

// 테스트용 Supabase 세션 발급 Mock

import Foundation
@testable import VibeTrip

#if DEBUG
final class MockSessionAuthService: SessionAuthServiceProtocol {

    // nil: 성공
    // .networkError: 네트워크 에러 (토스트)
    // .timeout: 타임아웃 에러 (팝업)
    var simulatedError: LoginError? = nil

    // 네트워크 딜레이 시뮬 (기본 1초)
    var delay: UInt64 = 1_000_000_000

    // 마지막 세션 발급 요청 정보 (호출 검증용)
    private(set) var lastCredential: SocialLoginCredential?

    func signIn(with credential: SocialLoginCredential, deviceId: String, fcmToken: String) async throws {
        try await Task.sleep(nanoseconds: delay)
        lastCredential = credential

        if let error = simulatedError {
            throw error
        }
    }
}
#endif
