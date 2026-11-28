//
//  AlbumStorage.swift
//  VibeTrip
//
//  Created by CHOI on 11/24/26.
//

// 앨범 이미지·음악 파일 저장소 처리
// - DB에는 버킷 내 파일 경로만 저장 -> 화면 표시용 공개 URL로 변환
// - 이미지 업로드 경로: {회원 id}/{UUID}.jpg (본인 폴더에만 업로드 가능)
// - 파일 삭제는 실패해도 앨범 작업 결과에 영향 주지 않음

import Foundation
import Supabase

// MARK: - AlbumStorageBucket

enum AlbumStorageBucket: String {
    case covers = "covers"
    case logImages = "log-images"
    case music = "music"
}

// MARK: - AlbumStorage

struct AlbumStorage {

    // MARK: - Constants

    private static let imageFileExtension = "jpg"
    private static let imageContentType = "image/jpeg"

    // MARK: - Dependencies

    private let client: SupabaseClient

    // MARK: - Init

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Public

    /// 버킷 내 파일 경로 -> 공개 URL (경로가 없거나 비어 있으면 nil)
    func publicURL(bucket: AlbumStorageBucket, path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return try? client.storage.from(bucket.rawValue).getPublicURL(path: path)
    }

    /// JPEG 이미지 업로드 후 저장된 파일 경로 반환
    func uploadImage(_ data: Data, bucket: AlbumStorageBucket, memberId: UUID) async throws -> String {
        let path = Self.makeImagePath(memberId: memberId)
        try await client.storage.from(bucket.rawValue).upload(
            path,
            data: data,
            options: FileOptions(contentType: Self.imageContentType)
        )
        return path
    }

    /// 여러 JPEG 이미지를 전달한 순서대로 업로드 후 저장된 파일 경로 목록 반환
    /// - 중간에 실패하면 이미 올린 파일을 정리한 뒤 오류 전달
    func uploadImages(_ dataList: [Data], bucket: AlbumStorageBucket, memberId: UUID) async throws -> [String] {
        var uploadedPaths: [String] = []
        do {
            for data in dataList {
                let path = try await uploadImage(data, bucket: bucket, memberId: memberId)
                uploadedPaths.append(path)
            }
        } catch {
            await removeFiles(bucket: bucket, paths: uploadedPaths)
            throw error
        }
        return uploadedPaths
    }

    /// 파일 삭제 (실패 시 로그만 남기고 진행)
    func removeFiles(bucket: AlbumStorageBucket, paths: [String]) async {
        let targets = paths.filter { !$0.isEmpty }
        guard !targets.isEmpty else { return }
        do {
            try await client.storage.from(bucket.rawValue).remove(paths: targets)
        } catch {
            #if DEBUG
            print("[AlbumStorage] \(bucket.rawValue) 파일 삭제 실패: \(error)")
            #endif
        }
    }

    // MARK: - Private

    // 저장소 정책이 소문자 회원 id 폴더를 기준으로 판단하므로 소문자로 통일
    private static func makeImagePath(memberId: UUID) -> String {
        let folder = memberId.uuidString.lowercased()
        let fileName = UUID().uuidString.lowercased()
        return "\(folder)/\(fileName).\(imageFileExtension)"
    }
}
