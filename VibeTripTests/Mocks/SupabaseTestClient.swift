//
//  SupabaseTestClient.swift
//  VibeTrip
//
//  Created by CHOI on 11/23/26.
//

// 테스트용 Supabase 클라이언트
// - 실제 네트워크 대신 SupabaseStubURLProtocol이 응답을 반환
// - 로그인 세션은 메모리에만 저장해 앱의 Keychain 세션과 분리

import Foundation
import Supabase
@testable import VibeTrip

// MARK: - SupabaseStubURLProtocol

// 요청을 가로채 미리 지정한 응답을 반환하는 URLProtocol
final class SupabaseStubURLProtocol: URLProtocol {

    // 요청별 응답 생성 핸들러 (테스트마다 지정)
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    // 가로챈 요청 기록 (호출 검증용)
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - InMemoryAuthStorage

// 메모리 기반 세션 저장소
final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func store(key: String, value: Data) throws {
        lock.withLock { storage[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { storage[key] }
    }

    func remove(key: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}

// MARK: - SupabaseTestClient

enum SupabaseTestClient {

    private static let baseURL = URL(string: "https://test.supabase.co")!
    private static let testKey = "test-publishable-key"

    // 응답 스텁이 적용된 클라이언트 생성
    static func make() -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseStubURLProtocol.self]

        return SupabaseClient(
            supabaseURL: baseURL,
            supabaseKey: testKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(storage: InMemoryAuthStorage(), autoRefreshToken: false),
                global: SupabaseClientOptions.GlobalOptions(session: URLSession(configuration: configuration))
            )
        )
    }

    // JSON 응답 생성 헬퍼
    static func jsonResponse(_ json: String, statusCode: Int = 200, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? baseURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}
