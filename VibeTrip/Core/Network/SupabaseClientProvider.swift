//
//  SupabaseClientProvider.swift
//  VibeTrip
//
//  Created by CHOI on 11/23/26.
//

// 앱 전역에서 공유하는 Supabase 클라이언트 진입점
// - 인증 세션은 SDK가 Keychain에 저장하고 만료 전 자동 갱신
// - DB, Storage, Edge Function 요청 시 로그인 세션의 토큰이 자동으로 첨부됨

import Foundation
import Supabase

enum SupabaseClientProvider {

    // 기본 공유 인스턴스
    static let shared: SupabaseClient = {
        guard let url = URL(string: AppConfig.supabaseURL) else {
            fatalError("SupabaseClientProvider: SUPABASE_URL 형식이 올바르지 않습니다. xcconfig 설정을 확인하세요.")
        }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabasePublishableKey,
            options: SupabaseClientOptions(
                // 앱 실행 시 저장된 세션을 만료 여부와 관계없이 먼저 전달 (만료 시 SDK가 갱신 후 다시 전달)
                auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
            )
        )
    }()
}
