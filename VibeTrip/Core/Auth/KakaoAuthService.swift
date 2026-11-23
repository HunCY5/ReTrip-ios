//
//  KakaoAuthService.swift
//  VibeTrip
//
//  Created by CHOI on 3/15/26.
//

// 카카오 SDK 호출 서비스 구현체
// 기기에 카카오톡 설치O :앱 로그인, 미설치: 웹 로그인
// 로그인 성공 시: OpenID Connect idToken + accessToken 반환
// 사용자가 취소 시: LoginError.cancelled throw

import Foundation
import KakaoSDKCommon
import KakaoSDKAuth
import KakaoSDKUser

final class KakaoAuthService: KakaoAuthServiceProtocol {

    // SDK 콜백(성공/취소/실패) 대기한다 -> 네트워크 타임아웃은 백엔드 통신 구간에서 담당
    func login(nonce: String) async throws -> (idToken: String, accessToken: String) {
        try await withCheckedThrowingContinuation { continuation in
            // 카카오톡 앱 설치 여부에 따라 분기
            if UserApi.isKakaoTalkLoginAvailable() {
                // 앱 로그인
                UserApi.shared.loginWithKakaoTalk(nonce: nonce) { oauthToken, error in
                    continuation.resume(with: self.handle(oauthToken: oauthToken, error: error))
                }
            } else {
                // 웹 로그인
                UserApi.shared.loginWithKakaoAccount(nonce: nonce) { oauthToken, error in
                    continuation.resume(with: self.handle(oauthToken: oauthToken, error: error))
                }
            }
        }
    }
    
    // MARK: - 콜백 결과 변환 함수
    
    private func handle(oauthToken: OAuthToken?, error: Error?) -> Result<(idToken: String, accessToken: String), Error> {
        if let error = error {
            // 사용자가 취소
            if let sdkError = error as? SdkError,
               sdkError.isClientFailed,
               sdkError.getClientError().reason == .Cancelled {
                return .failure(LoginError.cancelled)
            }
            return .failure(LoginError.providerError)
        }
        
        // idToken 누락: 카카오 앱 설정에서 OpenID Connect 비활성 상태
        guard let accessToken = oauthToken?.accessToken,
              let idToken = oauthToken?.idToken else {
            return .failure(LoginError.providerError)
        }
        
        return .success((idToken: idToken, accessToken: accessToken))
    }
}
