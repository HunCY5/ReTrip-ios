//
//  NonceGeneratorTests.swift
//  VibeTripTests
//
//  Created by CHOI on 11/23/26.
//

import XCTest
import CryptoKit
@testable import VibeTrip

final class NonceGeneratorTests: XCTestCase {

    private enum Constants {
        static let rawLength = 32
        static let sha256HexLength = 64
        static let uniquenessSampleCount = 100
    }

    // 원본 nonce: 지정 길이
    func test_make_rawHasExpectedLength() {
        let nonce = NonceGenerator.make()

        XCTAssertEqual(nonce.raw.count, Constants.rawLength)
    }

    // 해시 nonce: 원본의 SHA-256 16진수 소문자 문자열 (Supabase 검증 방식과 일치)
    func test_make_hashedIsSHA256OfRaw() {
        let nonce = NonceGenerator.make()

        let expected = SHA256.hash(data: Data(nonce.raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(nonce.hashed, expected)
        XCTAssertEqual(nonce.hashed.count, Constants.sha256HexLength)
    }

    // 생성할 때마다 다른 값 (로그인 요청 재사용 방지)
    func test_make_generatesUniqueValues() {
        let raws = Set((0..<Constants.uniquenessSampleCount).map { _ in NonceGenerator.make().raw })

        XCTAssertEqual(raws.count, Constants.uniquenessSampleCount)
    }
}
