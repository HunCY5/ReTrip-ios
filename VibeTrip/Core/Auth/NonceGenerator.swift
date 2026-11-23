//
//  NonceGenerator.swift
//  VibeTrip
//
//  Created by CHOI on 11/23/26.
//

// 소셜 로그인 ID 토큰 재사용 방지용 nonce 생성
// - hashed: 카카오/애플 로그인 요청에 전달 -> 발급된 ID 토큰에 포함됨
// - raw: Supabase 세션 발급 요청에 전달 -> Supabase가 해시 후 토큰 값과 일치하는지 검증

import Foundation
import CryptoKit

// 로그인 1회에 사용하는 nonce 쌍
struct LoginNonce: Equatable {
    let raw: String
    let hashed: String
}

enum NonceGenerator {

    // MARK: - Constants

    private static let nonceLength = 32
    private static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    // MARK: - Public

    // 로그인 요청마다 새로 생성
    static func make() -> LoginNonce {
        let raw = randomString(length: nonceLength)
        return LoginNonce(raw: raw, hashed: sha256(raw))
    }

    // MARK: - Private

    // 시스템 보안 난수 기반 문자열 생성
    private static func randomString(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in charset.randomElement(using: &generator) })
    }

    // SHA-256 해시 (16진수 소문자 문자열)
    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
