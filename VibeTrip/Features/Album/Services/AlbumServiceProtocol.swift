//
//  AlbumServiceProtocol.swift
//  VibeTrip
//
//  Created by CHOI on 3/24/26.
//

import Foundation
import Supabase

// MARK: - AlbumServiceProtocol

/// 앨범 관련 네트워크 서비스 인터페이스
/// Auth 레이어(AuthServiceProtocol)와 동일한 Protocol 기반 패턴 적용
protocol AlbumServiceProtocol {
    /// 앨범 목록 조회 (커서 기반 페이지네이션)
    func fetchAlbums(cursor: Int?, limit: Int) async throws -> AlbumListPayload
    /// 앨범 생성
    func createAlbum(request: AlbumCreateRequest) async throws -> AlbumCreateResponse
    /// 앨범 로그 조회
    func fetchAlbumLog(albumId: String) async throws -> AlbumLog
    /// 앨범 정보 수정
    func updateAlbum(albumId: String, request: AlbumUpdateRequest) async throws
    /// 앨범 삭제
    func deleteAlbum(albumId: String) async throws
    /// 앨범 로그 목록 조회 (커서 기반 페이지네이션)
    func fetchAlbumLogs(albumId: String, cursor: Int?, limit: Int) async throws -> AlbumLogListPayload
    /// 로그 등록
    func saveLog(request: AlbumLogRequest) async throws
    /// 로그 수정
    func updateLog(request: AlbumLogUpdateRequest) async throws
    /// 단일 앨범 조회 (title·musicUrl null 여부로 생성 완료 감지)
    func fetchAlbum(albumId: Int) async throws -> AlbumDetail
    /// 앨범 로그 삭제
    func deleteAlbumLog(albumId: String, albumLogId: Int) async throws
}

// MARK: - AlbumCreateRequest / AlbumCreateResponse

struct AlbumCreateRequest {
    let photoData: Data
    let location: String
    let startDate: Date
    let endDate: Date
    let lyricsOption: LyricsOption
    let vocalGender: VocalGender?
    let genre: AlbumGenre
    let comment: String
}

struct AlbumCreateResponse: Decodable {
    let albumId: Int
}

// MARK: - AlbumCreateRequestBody

// multipart request 파트
private struct AlbumLogRegisterRequestBody: Encodable {
    let description: String
}

private struct AlbumLogUpdateRequestBody: Encodable {
    let description: String
    let removeImageIds: [Int64]   // 삭제할 기존 이미지 ID 목록
}

private struct AlbumCreateRequestBody: Encodable {
    let region: String
    let travelStartDate: String
    let travelEndDate: String
    let genre: String
    let withLyrics: Bool
    let vocalGender: String
    let comment: String
}

// MARK: - AlbumService

final class AlbumService: AlbumServiceProtocol {

    // MARK: - Constants

    private enum Table {
        static let album = "album"
        static let albumCardView = "album_card_view"
        static let albumLog = "album_log"
        static let albumLogImage = "album_log_image"
    }

    // 메인 화면 카드 표시에 필요한 컬럼
    private static let albumCardColumns =
        "id,title,region,travel_start_date,travel_end_date,cover_image_path,log_image_count,preview_log_image_paths"
    // 상세·수정 화면 표시에 필요한 앨범 + 음악 컬럼
    private static let albumDetailColumns =
        "title,cover_image_path,region,travel_start_date,travel_end_date,comment,"
        + "album_music(genre,with_lyrics,vocal_gender,status,music_path)"
    // 앨범 삭제 시 정리할 파일 경로 (커버, 음악, 기록 이미지)
    private static let albumFileColumns =
        "cover_image_path,album_music(music_path),album_log(album_log_image(image_path))"
    // 상세 화면 로그 피드 표시에 필요한 로그 + 사진 컬럼
    private static let albumLogColumns =
        "id,description,created_at,album_log_image(id,image_path)"
    // 다음 페이지 존재 여부 확인용 추가 조회 수
    private static let nextPageProbeCount = 1

    // MARK: - Dependencies

    private let apiClient: APIClientProtocol
    private let supabase: SupabaseClient
    private let storage: AlbumStorage

    // MARK: - Init

    init(
        apiClient: APIClientProtocol = APIClient.shared,
        supabase: SupabaseClient = SupabaseClientProvider.shared
    ) {
        self.apiClient = apiClient
        self.supabase = supabase
        self.storage = AlbumStorage(client: supabase)
    }

    // 최신 앨범부터 조회 (RLS로 본인 앨범만 반환)
    // - cursor: 존재 -> 해당 albumId보다 먼저 만든 앨범부터, 존재X -> 첫 페이지부터 조회
    // - limit보다 1개 더 조회해 다음 페이지 존재 여부 판단
    // - totalCount: cursor 이후 남은 앨범 수
    func fetchAlbums(cursor: Int?, limit: Int) async throws -> AlbumListPayload {
        var query = supabase.from(Table.albumCardView)
            .select(Self.albumCardColumns, count: .exact)
        if let cursor {
            query = query.lt("id", value: cursor)
        }
        let response: PostgrestResponse<[AlbumCardRow]> = try await query
            .order("id", ascending: false)
            .limit(limit + Self.nextPageProbeCount)
            .execute()

        let rows = response.value
        let cards = rows.prefix(limit).map(makeAlbumCard)
        return AlbumListPayload(
            content: cards,
            totalCount: response.count ?? cards.count,
            hasNext: rows.count > limit
        )
    }

    // 커버 이미지 + 앨범 정보: multipart/form-data로 전송해 앨범 생성
    func createAlbum(request: AlbumCreateRequest) async throws -> AlbumCreateResponse {
        // 서버 필드명 기준으로 JSON 파트 구성
        let body = AlbumCreateRequestBody(
            region: request.location,
            travelStartDate: Self.dateFormatter.string(from: request.startDate),
            travelEndDate: Self.dateFormatter.string(from: request.endDate),
            genre: request.genre.serverValue(for: request.lyricsOption),
            withLyrics: request.lyricsOption == .include,
            // 가사 없음(nil): vocalGender: "N", 가사 있음: "M"/"F"
            vocalGender: request.vocalGender?.serverValue ?? "N",
            comment: request.comment
        )
        var formData = MultipartFormData()
        try formData.append(name: "request", encodable: body)
        formData.append(name: "coverImage", imageData: request.photoData)

        let endpoint = APIEndpoint(path: "/api/v1/albums", method: .post)
        #if DEBUG
        print(
            """
            [AlbumCreate][Request]
            - region: \(body.region)
            - travelStartDate: \(body.travelStartDate)
            - travelEndDate: \(body.travelEndDate)
            - genre: \(body.genre)
            - withLyrics: \(body.withLyrics)
            - vocalGender: \(body.vocalGender)
            - comment: \(body.comment)
            - coverImageBytes: \(request.photoData.count)
            """
        )
        #endif

        do {
            let response: AlbumCreateResponse = try await apiClient.upload(endpoint, formData: formData)
            #if DEBUG
            print("[AlbumCreate][Response] SUCCESS albumId=\(response.albumId)")
            #endif
            return response
        } catch APIClientError.serverError(let code) {
            #if DEBUG
            print("[AlbumCreate][Response] ERROR serverError=\(code.rawValue)")
            #endif
            throw APIClientError.serverError(code)
        } catch APIClientError.networkError(let urlError) {
            #if DEBUG
            print("[AlbumCreate][Response] ERROR networkError=\(urlError.code.rawValue)")
            #endif
            throw APIClientError.networkError(urlError)
        } catch {
            #if DEBUG
            print("[AlbumCreate][Response] ERROR unknown=\(error)")
            #endif
            throw error
        }
    }
    
    func fetchAlbumLog(albumId: String) async throws -> AlbumLog {
        fatalError("TODO: 로그 조회 API 엔드포인트 확인 후 구현")
    }

    // 앨범의 최신 로그부터 조회 (RLS로 본인 로그만 반환)
    // - cursor: 존재 -> 해당 로그 id보다 먼저 작성한 로그부터, 존재X -> 첫 페이지부터 조회
    // - 로그별 사진은 추가한 순서대로 정렬
    // - limit보다 1개 더 조회해 다음 페이지 존재 여부 판단
    func fetchAlbumLogs(albumId: String, cursor: Int?, limit: Int) async throws -> AlbumLogListPayload {
        var query = supabase.from(Table.albumLog)
            .select(Self.albumLogColumns)
            .eq("album_id", value: albumId)
        if let cursor {
            query = query.lt("id", value: cursor)
        }
        let rows: [AlbumLogRow] = try await query
            .order("id", ascending: false)
            .order("id", ascending: true, referencedTable: Table.albumLogImage)
            .limit(limit + Self.nextPageProbeCount)
            .execute()
            .value

        return AlbumLogListPayload(
            content: rows.prefix(limit).map(makeAlbumLogEntry),
            hasNext: rows.count > limit
        )
    }
    
    // 앨범 정보 수정 + (사진 변경 시) 커버 교체
    // - 새 커버 업로드 -> 앨범 정보 변경 -> 이전 커버 삭제 순서로 진행해 커버가 비는 상태 방지
    // - 음악 재생성은 음악 생성 처리와 연결되기 전까지 지원하지 않음
    func updateAlbum(albumId: String, request: AlbumUpdateRequest) async throws {
        guard !request.regenerateMusic else {
            throw AlbumError.unknown
        }

        var newCoverPath: String?
        var oldCoverPath: String?
        if let photoData = request.photoData {
            let memberId = try await supabase.auth.session.user.id
            oldCoverPath = try await fetchCoverImagePath(albumId: albumId)
            newCoverPath = try await storage.uploadImage(photoData, bucket: .covers, memberId: memberId)
        }

        let payload = AlbumUpdatePayload(
            title: request.title,
            region: request.location,
            travelStartDate: Self.dateFormatter.string(from: request.startDate),
            travelEndDate: Self.dateFormatter.string(from: request.endDate),
            comment: request.comment,
            coverImagePath: newCoverPath
        )

        do {
            // 변경된 행을 1건 반환받아 본인 앨범이 아닌 경우(RLS로 0건) 실패 처리
            try await supabase.from(Table.album)
                .update(payload)
                .eq("id", value: albumId)
                .select("id")
                .single()
                .execute()
        } catch {
            // 앨범 정보 변경 실패 시 새로 올린 커버는 사용되지 않으므로 정리
            if let newCoverPath {
                await storage.removeFiles(bucket: .covers, paths: [newCoverPath])
            }
            throw error
        }

        if let oldCoverPath {
            await storage.removeFiles(bucket: .covers, paths: [oldCoverPath])
        }
    }

    // 앨범 삭제 후 관련 파일 정리
    // - 앨범 행 삭제 시 음악·기록·기록 이미지 행은 DB에서 함께 삭제
    // - 행이 사라지면 파일 경로를 알 수 없으므로 삭제 전에 경로를 먼저 수집
    // - 파일 정리는 실패해도 앨범 삭제는 성공으로 처리
    func deleteAlbum(albumId: String) async throws {
        let files: AlbumFilesRow = try await supabase.from(Table.album)
            .select(Self.albumFileColumns)
            .eq("id", value: albumId)
            .single()
            .execute()
            .value

        // 삭제된 행을 1건 반환받아 본인 앨범이 아닌 경우(RLS로 0건) 실패 처리
        try await supabase.from(Table.album)
            .delete()
            .eq("id", value: albumId)
            .select("id")
            .single()
            .execute()

        await storage.removeFiles(bucket: .covers, paths: [files.coverImagePath])
        await storage.removeFiles(bucket: .logImages, paths: files.logImagePaths)
        await storage.removeFiles(bucket: .music, paths: files.musicPaths)
    }

    // 앨범 정보 + 음악 정보 한 번에 조회 (RLS로 본인 앨범이 아니면 조회 실패)
    func fetchAlbum(albumId: Int) async throws -> AlbumDetail {
        let row: AlbumDetailRow = try await supabase.from(Table.album)
            .select(Self.albumDetailColumns)
            .eq("id", value: albumId)
            .single()
            .execute()
            .value
        return makeAlbumDetail(from: row)
    }

    func saveLog(request: AlbumLogRequest) async throws {
        let body = AlbumLogRegisterRequestBody(description: request.logText)
        var formData = MultipartFormData()
        try formData.append(name: "request", encodable: body)
        for imageData in request.photoDataList {
            formData.append(name: "images", imageData: imageData)
        }
        let endpoint = APIEndpoint(path: "/api/v1/albums/\(request.albumId)/album-logs", method: .post)
        try await apiClient.performUpload(endpoint, formData: formData)
    }

    func updateLog(request: AlbumLogUpdateRequest) async throws {
        let body = AlbumLogUpdateRequestBody(description: request.logText, removeImageIds: request.removeImageIds)
        var formData = MultipartFormData()
        try formData.append(name: "request", encodable: body)
        for imageData in request.newPhotoDataList {
            formData.append(name: "newImages", imageData: imageData)
        }
        let endpoint = APIEndpoint(
            path: "/api/v1/albums/\(request.albumId)/album-logs/\(request.albumLogId)",
            method: .put
        )
        try await apiClient.performUpload(endpoint, formData: formData)
    }

    func deleteAlbumLog(albumId: String, albumLogId: Int) async throws {
        let endpoint = APIEndpoint(
            path: "/api/v1/albums/\(albumId)/album-logs/\(albumLogId)",
            method: .delete
        )
        try await apiClient.perform(endpoint)
    }

    // 서버 요구 날짜 포맷
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Private

    // 앨범의 현재 커버 이미지 경로 조회
    private func fetchCoverImagePath(albumId: String) async throws -> String {
        let row: AlbumCoverRow = try await supabase.from(Table.album)
            .select("cover_image_path")
            .eq("id", value: albumId)
            .single()
            .execute()
            .value
        return row.coverImagePath
    }

    // MARK: - Mapping

    // 조회 결과 -> 카드 모델 (파일 경로는 공개 URL로 변환)
    private func makeAlbumCard(from row: AlbumCardRow) -> AlbumCard {
        AlbumCard(
            id: row.id,
            // 빈 문자열은 타이틀 생성 중 상태이므로 nil 처리
            title: row.title?.isEmpty == true ? nil : row.title,
            location: row.region,
            startDate: row.travelStartDate,
            endDate: row.travelEndDate,
            coverImageUrl: storage.publicURL(bucket: .covers, path: row.coverImagePath),
            logImageCount: row.logImageCount ?? 0,
            previewLogImages: (row.previewLogImagePaths ?? []).compactMap { path in
                storage.publicURL(bucket: .logImages, path: path).map(PreviewLogImage.init)
            }
        )
    }

    // 조회 결과 -> 상세 모델
    // 음악 생성 완료 전에는 musicUrl nil -> 화면에서 생성 중 상태로 판단
    private func makeAlbumDetail(from row: AlbumDetailRow) -> AlbumDetail {
        let music = row.albumMusic
        let isMusicReady = music?.status == AlbumMusicStatusValue.completed
        return AlbumDetail(
            title: row.title?.isEmpty == true ? nil : row.title,
            coverImageUrl: storage.publicURL(bucket: .covers, path: row.coverImagePath),
            region: row.region,
            travelStartDate: row.travelStartDate,
            travelEndDate: row.travelEndDate,
            musicUrl: isMusicReady ? storage.publicURL(bucket: .music, path: music?.musicPath) : nil,
            genre: music.flatMap { AlbumGenre(serverValue: $0.genre) },
            vocalGender: music.flatMap { VocalGender(serverValue: $0.vocalGender) },
            withLyrics: music?.withLyrics ?? false,
            comment: row.comment
        )
    }

    // 조회 결과 -> 로그 피드 아이템 (사진 경로는 공개 URL로 변환)
    private func makeAlbumLogEntry(from row: AlbumLogRow) -> AlbumLogEntry {
        AlbumLogEntry(
            id: row.id,
            description: row.description,
            postedAt: Self.makePostedAt(from: row.createdAt),
            images: row.albumLogImage.compactMap { image in
                storage.publicURL(bucket: .logImages, path: image.imagePath).map {
                    AlbumLogImage(id: image.id, imageUrl: $0)
                }
            }
        )
    }

    // DB 작성 시각 -> 초 단위 UTC ISO8601 문자열 (예: 2026-11-25T03:12:45Z)
    // - DB 시각은 소수 초 자릿수가 일정하지 않아(최대 6자리) 기본 ISO8601 파싱이 실패하므로 소수 초 제거 후 변환
    // - 변환 실패 시 원본 문자열 유지
    private static func makePostedAt(from createdAt: String) -> String {
        let withoutFraction = createdAt.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        guard let date = postedAtFormatter.date(from: withoutFraction) else { return createdAt }
        return postedAtFormatter.string(from: date)
    }

    // 로그 작성 시각 포맷 (UTC, 초 단위)
    private static let postedAtFormatter = ISO8601DateFormatter()
}

// 음악 생성 상태 (DB music_status)
private enum AlbumMusicStatusValue {
    static let completed = "COMPLETED"
}

// MARK: - AlbumGenre + Server Value

private extension AlbumGenre {
    // DB 장르 값 -> 장르 (가사 없는 재즈는 재즈로 표시)
    init?(serverValue: String) {
        if serverValue == "JAZZ_NO_VOCAL" {
            self = .jazz
            return
        }
        guard let matched = AlbumGenre.allCases.first(where: { $0.serverValue == serverValue }) else {
            return nil
        }
        self = matched
    }
}

// MARK: - VocalGender + Server Value

private extension VocalGender {
    // DB 값 "M"/"F" -> 보컬 성별, "N"(보컬 없음) -> nil
    init?(serverValue: String) {
        switch serverValue {
        case "M": self = .male
        case "F": self = .female
        default: return nil
        }
    }
}

// MARK: - Supabase Row

// 앨범 카드 조회 결과 (album_card_view)
private nonisolated struct AlbumCardRow: Decodable {
    let id: Int
    let title: String?
    let region: String
    let travelStartDate: String
    let travelEndDate: String
    let coverImagePath: String?
    let logImageCount: Int?
    let previewLogImagePaths: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, region
        case travelStartDate = "travel_start_date"
        case travelEndDate = "travel_end_date"
        case coverImagePath = "cover_image_path"
        case logImageCount = "log_image_count"
        case previewLogImagePaths = "preview_log_image_paths"
    }
}

// 앨범 상세 조회 결과 (album + album_music)
private nonisolated struct AlbumDetailRow: Decodable {
    let title: String?
    let coverImagePath: String?
    let region: String
    let travelStartDate: String
    let travelEndDate: String
    let comment: String?
    // 앨범당 음악 1개 (생성 요청 전이면 nil)
    let albumMusic: AlbumMusicRow?

    enum CodingKeys: String, CodingKey {
        case title, region, comment
        case coverImagePath = "cover_image_path"
        case travelStartDate = "travel_start_date"
        case travelEndDate = "travel_end_date"
        case albumMusic = "album_music"
    }
}

// 앨범 커버 경로 조회 결과
private nonisolated struct AlbumCoverRow: Decodable {
    let coverImagePath: String

    enum CodingKeys: String, CodingKey {
        case coverImagePath = "cover_image_path"
    }
}

// 앨범 삭제 시 정리할 파일 경로 조회 결과
private nonisolated struct AlbumFilesRow: Decodable {
    let coverImagePath: String
    let albumMusic: MusicPath?
    let albumLog: [LogImages]

    struct MusicPath: Decodable {
        let musicPath: String?

        enum CodingKeys: String, CodingKey {
            case musicPath = "music_path"
        }
    }

    struct LogImages: Decodable {
        let albumLogImage: [ImagePath]

        enum CodingKeys: String, CodingKey {
            case albumLogImage = "album_log_image"
        }
    }

    struct ImagePath: Decodable {
        let imagePath: String

        enum CodingKeys: String, CodingKey {
            case imagePath = "image_path"
        }
    }

    var musicPaths: [String] {
        [albumMusic?.musicPath].compactMap { $0 }
    }

    var logImagePaths: [String] {
        albumLog.flatMap { $0.albumLogImage.map(\.imagePath) }
    }

    enum CodingKeys: String, CodingKey {
        case coverImagePath = "cover_image_path"
        case albumMusic = "album_music"
        case albumLog = "album_log"
    }
}

// 앨범 음악 조회 결과 (album_music)
private nonisolated struct AlbumMusicRow: Decodable {
    let genre: String
    let withLyrics: Bool
    let vocalGender: String
    let status: String
    let musicPath: String?

    enum CodingKeys: String, CodingKey {
        case genre, status
        case withLyrics = "with_lyrics"
        case vocalGender = "vocal_gender"
        case musicPath = "music_path"
    }
}

// 앨범 로그 피드 조회 결과 (album_log + album_log_image)
private nonisolated struct AlbumLogRow: Decodable {
    let id: Int
    let description: String
    let createdAt: String
    let albumLogImage: [ImageRow]

    struct ImageRow: Decodable {
        let id: Int64
        let imagePath: String

        enum CodingKeys: String, CodingKey {
            case id
            case imagePath = "image_path"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, description
        case createdAt = "created_at"
        case albumLogImage = "album_log_image"
    }
}

// MARK: - Supabase Payload

// 앨범 정보 수정 (커버 미변경 시 coverImagePath 생략)
private nonisolated struct AlbumUpdatePayload: Encodable {
    let title: String
    let region: String
    let travelStartDate: String
    let travelEndDate: String
    let comment: String
    let coverImagePath: String?

    enum CodingKeys: String, CodingKey {
        case title, region, comment
        case travelStartDate = "travel_start_date"
        case travelEndDate = "travel_end_date"
        case coverImagePath = "cover_image_path"
    }
}

// MARK: - MockAlbumService (DEBUG 전용)

#if DEBUG
final class MockAlbumService: AlbumServiceProtocol {

    var simulatedError: AlbumError? = nil   // 에러 시나리오 테스트
    var isEmpty: Bool = false              // 빈 목록 테스트
    var delay: UInt64 = 500_000_000       // 응답 지연 시뮬레이션(0.5초)

    // true일 경우, fetchAlbums 결과에 title: nil 앨범 포함 -> skeleton 테스트용
    var hasGeneratingAlbum: Bool = false
    // n번째 fetchAlbum 호출부터 musicUrl 반환 (음악 생성 완료 시뮬레이션)
    var musicReadyAfterAttempts: Int = 1
    private var fetchAlbumCount: [Int: Int] = [:]

    func fetchAlbums(cursor: Int?, limit: Int) async throws -> AlbumListPayload {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
        if isEmpty { return AlbumListPayload(content: [], totalCount: 0, hasNext: false) }
        // hasGeneratingAlbum: true -> title nil 앨범(mockItems[3]) 포함
        var items = Array(AlbumCard.mockItems.prefix(3))
        if hasGeneratingAlbum { items.append(AlbumCard.mockItems[3]) }
        return AlbumListPayload(content: items, totalCount: items.count, hasNext: false)
    }
    
    func createAlbum(request: AlbumCreateRequest) async throws -> AlbumCreateResponse {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
        return AlbumCreateResponse(albumId: 1)
    }
    
    func fetchAlbumLog(albumId: String) async throws -> AlbumLog {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
        return AlbumLog.mock
    }

    func fetchAlbumLogs(albumId: String, cursor: Int?, limit: Int) async throws -> AlbumLogListPayload {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
        return AlbumLogListPayload(content: AlbumLogEntry.mockItems, hasNext: false)
    }
    
    func updateAlbum(albumId: String, request: AlbumUpdateRequest) async throws {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
    }
    
    func deleteAlbum(albumId: String) async throws {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
    }
    
    func saveLog(request: AlbumLogRequest) async throws {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
    }

    func updateLog(request: AlbumLogUpdateRequest) async throws {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
    }

    func fetchAlbum(albumId: Int) async throws -> AlbumDetail {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
        // 호출 횟수 누적 후 titleReadyAfterAttempts 도달 시 타이틀 반환
        fetchAlbumCount[albumId, default: 0] += 1
        let count = fetchAlbumCount[albumId]!
        let isReady = count >= musicReadyAfterAttempts
        return AlbumDetail(
            title: isReady ? "Mock 앨범 타이틀" : nil,
            coverImageUrl: nil,
            region: "일본 오사카",
            travelStartDate: "2026-01-12",
            travelEndDate: "2026-01-15",
            musicUrl: isReady ? URL(string: "https://example.com/music.mp3") : nil
        )
    }

    func deleteAlbumLog(albumId: String, albumLogId: Int) async throws {
        try await Task.sleep(nanoseconds: delay)
        if let error = simulatedError { throw error }
    }
}
#endif
