//
//  SupabaseStub.swift
//  VibeTrip
//
//  Created by CHOI on 11/26/26.
//

// Supabase 스텁 테스트 공용 도우미
// - SupabaseStubURLProtocol이 반환할 응답 생성
// - 가로챈 요청의 쿼리·본문·삭제 대상 경로 확인
// - 업로드 경로 생성 등에 필요한 테스트 로그인 세션 등록

import XCTest
import Supabase
@testable import VibeTrip

// MARK: - SupabaseStub

enum SupabaseStub {

    // MARK: - Constants

    private enum Constants {
        static let userPath = "/auth/v1/user"
        static let sessionLifetime: TimeInterval = 3600
        static let refreshToken = "refresh-token"
        static let bodyReadBufferSize = 1024
    }

    // MARK: - Response

    // JSON 응답 생성 (추가 헤더 지정 가능, 예: 전체 개수용 Content-Range)
    static func response(
        _ json: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"].merging(headers) { $1 }
        )!
        return (response, Data(json.utf8))
    }

    // MARK: - Request

    static func queryValue(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    // URLProtocol로 전달된 요청 본문 (httpBody 또는 스트림)
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Constants.bodyReadBufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: Constants.bodyReadBufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(body(of: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // 저장소 파일 삭제 요청의 대상 경로 목록
    static func removedPaths(of request: URLRequest) throws -> [String] {
        try XCTUnwrap(jsonBody(of: request)["prefixes"] as? [String])
    }

    // MARK: - Session

    // 로그인 세션 등록 (사용자 조회 요청에 테스트 회원 반환)
    // - 등록 후 응답 핸들러와 요청 기록을 초기화해 테스트 대상 요청만 남김
    static func signIn(_ client: SupabaseClient, memberId: String) async throws {
        SupabaseStubURLProtocol.handler = { request in
            guard request.url?.path == Constants.userPath else { throw URLError(.badServerResponse) }
            let json = """
            {"id":"\(memberId)","aud":"authenticated","app_metadata":{},"user_metadata":{},
             "created_at":"2026-11-24T00:00:00Z","updated_at":"2026-11-24T00:00:00Z"}
            """
            return response(json, for: request)
        }
        _ = try await client.auth.setSession(
            accessToken: makeAccessToken(memberId: memberId),
            refreshToken: Constants.refreshToken
        )
        SupabaseStubURLProtocol.reset()
    }

    // MARK: - Private

    // 만료되지 않은 테스트용 액세스 토큰 (서명 검증 없음)
    private static func makeAccessToken(memberId: String) -> String {
        let exp = Int(Date().addingTimeInterval(Constants.sessionLifetime).timeIntervalSince1970)
        let header = base64URL(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64URL(#"{"sub":"\#(memberId)","exp":\#(exp)}"#)
        return "\(header).\(payload).signature"
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
