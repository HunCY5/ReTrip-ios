//
//  UserService.swift
//  VibeTrip
//
//  Created by CHOI on 3/23/26.
//

import Foundation
import Supabase

final class UserService: UserServiceProtocol {

    // MARK: - Constants

    private enum Constants {
        // 본인 프로필 + 앨범·기록 수 조회 DB 함수
        static let profileFunction = "get_my_profile"
        // 이름 미제공 회원(애플 재로그인 등)의 닉네임 표시값
        static let emptyNicknamePlaceholder = "-"
    }

    // MARK: - Dependencies

    private let apiClient: APIClientProtocol
    private let supabase: SupabaseClient

    // MARK: - Init

    init(
        apiClient: APIClientProtocol = APIClient.shared,
        supabase: SupabaseClient = SupabaseClientProvider.shared
    ) {
        self.apiClient = apiClient
        self.supabase = supabase
    }

    // MARK: - UserServiceProtocol

    // Supabase에서 로그인한 회원의 프로필과 앨범·기록 수 조회
    func fetchProfile() async throws -> UserProfile {
        let response: MyProfileResponse = try await supabase
            .rpc(Constants.profileFunction)
            .execute()
            .value

        let trimmedName = response.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserProfile(
            nickname: trimmedName.isEmpty ? Constants.emptyNicknamePlaceholder : trimmedName,
            email: response.email,
            profileImageUrl: response.profileImageUrl,
            albumCount: response.albumCount,
            albumLogCount: response.albumLogCount
        )
    }

    func deleteAccount() async throws {
        let endpoint = APIEndpoint(path: "/api/v1/members/me/withdraw", method: .delete)
        try await apiClient.perform(endpoint)
    }
}

// MARK: - Response

// get_my_profile 응답
private struct MyProfileResponse: Decodable {
    let name: String
    let email: String?
    let profileImageUrl: String?
    let albumCount: Int
    let albumLogCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case email
        case profileImageUrl = "profile_image_url"
        case albumCount = "album_count"
        case albumLogCount = "album_log_count"
    }
}
