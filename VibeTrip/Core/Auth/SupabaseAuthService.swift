//
//  SupabaseAuthService.swift
//  VibeTrip
//
//  Created by CHOI on 11/23/26.
//

// Supabase Auth 세션 발급 서비스 구현체
// 1. 카카오/애플 ID 토큰 + nonce로 Supabase 세션 발급 (세션 저장·갱신은 SDK 담당)
//    - SDK의 ID 토큰 로그인이 카카오를 지원하지 않아 카카오는 Auth API를 직접 호출 후 세션을 SDK에 등록
// 2. 애플 최초 로그인 시 전달된 이름을 회원 프로필에 저장
// 3. 현재 기기와 FCM 토큰을 푸시 수신 기기로 등록
// 회원 프로필 생성은 가입 시 DB 트리거가 처리

import Foundation
import Supabase

final class SupabaseAuthService: SessionAuthServiceProtocol {

    // MARK: - Constants

    private enum Table {
        static let member = "member"
        static let memberDevice = "member_device"
    }

    // member_device 중복 판단 기준 (회원 + 기기)
    private static let deviceConflictColumns = "member_id,device_id"

    // ID 토큰으로 세션을 발급하는 Auth API 경로
    private static let idTokenGrantPath = "/auth/v1/token?grant_type=id_token"
    private static let successStatusCodes = 200..<300

    // MARK: - Dependencies

    private let client: SupabaseClient
    private let urlSession: URLSession

    // MARK: - Init

    init(
        client: SupabaseClient = SupabaseClientProvider.shared,
        urlSession: URLSession = .shared
    ) {
        self.client = client
        self.urlSession = urlSession
    }

    // MARK: - SessionAuthServiceProtocol

    func signIn(with credential: SocialLoginCredential, deviceId: String, fcmToken: String) async throws {
        let session: Session
        do {
            session = try await issueSession(for: credential)
        } catch {
            throw Self.loginError(from: error)
        }

        // 세션 발급 이후 작업은 실패해도 로그인은 유지 (다음 로그인 시 다시 반영)
        let memberId = session.user.id
        await saveNameIfNeeded(credential.fullName, memberId: memberId)
        await registerDevice(memberId: memberId, deviceId: deviceId, fcmToken: fcmToken)
    }

    var hasStoredSession: Bool {
        client.auth.currentSession != nil
    }

    func sessionEndedEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { [client] in
                for await (event, _) in client.auth.authStateChanges where event == .signedOut {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signOut(deviceId: String) async {
        // 로그아웃한 기기로 푸시가 가지 않도록 등록 해제 (세션이 살아 있을 때만 본인 데이터 삭제 가능)
        if let memberId = client.auth.currentSession?.user.id, !deviceId.isEmpty {
            do {
                try await client.from(Table.memberDevice)
                    .delete()
                    .eq("member_id", value: memberId)
                    .eq("device_id", value: deviceId)
                    .execute()
            } catch {
                #if DEBUG
                print("기기 등록 해제 실패: \(error)")
                #endif
            }
        }

        // 서버 세션 종료 실패(네트워크 등) 시에도 기기에 저장된 세션은 제거
        do {
            try await client.auth.signOut()
        } catch {
            try? await client.auth.signOut(scope: .local)
        }
    }

    // MARK: - Private

    // 제공자별 세션 발급
    private func issueSession(for credential: SocialLoginCredential) async throws -> Session {
        switch credential.provider {
        case .apple:
            return try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: credential.idToken,
                    nonce: credential.nonce
                )
            )
        case .kakao:
            return try await signInWithKakaoIdToken(credential)
        }
    }

    // 카카오 ID 토큰으로 Auth API 직접 호출 -> 발급된 토큰을 SDK 세션으로 등록
    private func signInWithKakaoIdToken(_ credential: SocialLoginCredential) async throws -> Session {
        guard let url = URL(string: AppConfig.supabaseURL + Self.idTokenGrantPath) else {
            throw LoginError.providerError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            IdTokenGrantRequest(
                provider: credential.provider.rawValue,
                idToken: credential.idToken,
                accessToken: credential.accessToken,
                nonce: credential.nonce
            )
        )

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              Self.successStatusCodes.contains(httpResponse.statusCode) else {
            #if DEBUG
            print("카카오 세션 발급 거절: \(String(data: data, encoding: .utf8) ?? "")")
            #endif
            throw LoginError.providerError
        }

        let tokens = try JSONDecoder().decode(IdTokenGrantResponse.self, from: data)
        return try await client.auth.setSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }

    // 애플 최초 로그인 이름 저장 (ID 토큰에는 이름이 없어 가입 트리거로 채울 수 없음)
    private func saveNameIfNeeded(_ fullName: String?, memberId: UUID) async {
        guard let fullName, !fullName.isEmpty else { return }
        do {
            try await client.from(Table.member)
                .update(MemberNameUpdate(name: fullName))
                .eq("id", value: memberId)
                .execute()
        } catch {
            #if DEBUG
            print("회원 이름 저장 실패: \(error)")
            #endif
        }
    }

    // 푸시 수신 기기 등록 (같은 기기는 FCM 토큰만 갱신)
    private func registerDevice(memberId: UUID, deviceId: String, fcmToken: String) async {
        guard !deviceId.isEmpty, !fcmToken.isEmpty else { return }
        do {
            try await client.from(Table.memberDevice)
                .upsert(
                    MemberDeviceUpsert(memberId: memberId, deviceId: deviceId, fcmToken: fcmToken),
                    onConflict: Self.deviceConflictColumns,
                    returning: .minimal
                )
                .execute()
        } catch {
            #if DEBUG
            print("기기 등록 실패: \(error)")
            #endif
        }
    }

    // Supabase/네트워크 에러 -> 로그인 화면 에러 타입 변환
    private static func loginError(from error: Error) -> LoginError {
        if let loginError = error as? LoginError {
            return loginError
        }
        guard let urlError = error as? URLError else {
            #if DEBUG
            print("Supabase 세션 발급 실패: \(error)")
            #endif
            return .providerError
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        default:
            return .networkError
        }
    }
}

// MARK: - Request / Response Body

// ID 토큰 세션 발급 요청
private struct IdTokenGrantRequest: Encodable {
    let provider: String
    let idToken: String
    let accessToken: String?
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case accessToken = "access_token"
        case nonce
    }
}

// ID 토큰 세션 발급 응답 (SDK 세션 등록에 필요한 토큰만 사용)
private struct IdTokenGrantResponse: Decodable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// 회원 이름 수정
private struct MemberNameUpdate: Encodable {
    let name: String
}

// 푸시 수신 기기 등록
private struct MemberDeviceUpsert: Encodable {
    let memberId: UUID
    let deviceId: String
    let fcmToken: String

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case deviceId = "device_id"
        case fcmToken = "fcm_token"
    }
}
