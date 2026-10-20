import CryptoKit
import Foundation

/// 可存放已下載漫畫的雲端服務。
enum CloudKind: String, CaseIterable, Identifiable, Codable {
    case oneDrivePersonal = "onedrive"
    case oneDriveBusiness = "onedrive-business"
    case googleDrive = "gdrive"
    case webdav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDrivePersonal: L("OneDrive 個人版")
        case .oneDriveBusiness: L("OneDrive 商業版")
        case .googleDrive: "Google Drive"
        case .webdav: "WebDAV"
        }
    }

    var systemImage: String {
        switch self {
        case .oneDrivePersonal, .oneDriveBusiness: "cloud.fill"
        case .googleDrive: "externaldrive.badge.icloud"
        case .webdav: "server.rack"
        }
    }

    /// WebDAV 沿用「快取、備份與 WebDAV」的帳密；其餘以 OAuth 登入
    var usesOAuth: Bool { self != .webdav }
}

/// 章節上傳到雲端後，本機檔案的保存方式。
enum RetentionMode: String, CaseIterable, Identifiable {
    case keep, offload, recent, auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: L("永遠保留本機")
        case .offload: L("上傳後刪除本機")
        case .recent: L("只保留最近幾話")
        case .auto: L("空間不足時才釋放")
        }
    }

    var detail: String {
        switch self {
        case .keep: L("雲端只當備份，本機檔案不會被自動刪除。")
        case .offload: L("章節上傳並確認完整後，立即刪除本機圖片，最省空間。")
        case .recent: L("保留目前閱讀位置起的幾話，其餘已上傳的章節只留在雲端。")
        case .auto: L("手機剩餘空間低於門檻時，從最久沒讀的作品開始改為只留雲端。")
        }
    }
}

/// 雲端相關設定（存於 UserDefaults；以 "cloud." 開頭，會一併放進 App 備份）。
final class CloudSettings: ObservableObject {
    static let shared = CloudSettings()

    @Stored("cloud.msPersonalClientId", "") var msPersonalClientId: String
    @Stored("cloud.msBusinessClientId", "") var msBusinessClientId: String
    @Stored("cloud.msBusinessTenant", "organizations") var msBusinessTenant: String
    @Stored("cloud.googleClientId", "") var googleClientId: String
    @Stored("cloud.target", "") var targetRaw: String
    /// 雲端上的存放資料夾（可多層，以 / 分隔）
    @Stored("cloud.rootFolder", "GodBook") var rootFolder: String
    @Stored("cloud.autoUpload", false) var autoUpload: Bool
    @Stored("cloud.wifiOnly", true) var wifiOnly: Bool
    @Stored("cloud.policy", "keep") var policyRaw: String
    @Stored("cloud.keepRecent", 3) var keepRecent: Int
    @Stored("cloud.lowSpaceGB", 2) var lowSpaceGB: Int
    @Stored("cloud.cacheLimitMB", 1024) var cacheLimitMB: Int
    /// 每部作品另外指定的保存策略（漫畫 id → RetentionMode.rawValue）
    @Stored("cloud.comicPolicies", [String: String]()) var comicPolicies: [String: String]

    private init() {}

    /// 上傳目標
    var target: CloudKind? {
        get { CloudKind(rawValue: targetRaw) }
        set { targetRaw = newValue?.rawValue ?? "" }
    }

    var defaultPolicy: RetentionMode {
        get { RetentionMode(rawValue: policyRaw) ?? .keep }
        set { policyRaw = newValue.rawValue }
    }

    func override(for comicId: String) -> RetentionMode? {
        comicPolicies[comicId].flatMap(RetentionMode.init(rawValue:))
    }

    func setOverride(_ mode: RetentionMode?, for comicId: String) {
        var map = comicPolicies
        map[comicId] = mode?.rawValue
        comicPolicies = map
    }

    func policy(for comicId: String) -> RetentionMode { override(for: comicId) ?? defaultPolicy }

    func clientId(for kind: CloudKind) -> String {
        let value: String
        switch kind {
        case .oneDrivePersonal: value = msPersonalClientId
        case .oneDriveBusiness: value = msBusinessClientId
        case .googleDrive: value = googleClientId
        case .webdav: value = ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 整理過的雲端資料夾路徑；空白時用預設的 GodBook
    var rootPath: [String] {
        let parts = rootFolder.split(separator: "/").compactMap { CloudPath.folderName(String($0)) }
        return parts.isEmpty ? CloudPath.defaultRoot : parts
    }

    var businessTenant: String {
        let value = msBusinessTenant.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "organizations" : value
    }
}

/// 雲端上的目錄結構：<資料夾>/index.json、<資料夾>/Comics/<作品>/{cover.jpg, ch_<章節>.cbz}
/// 資料夾可在設定中自訂（預設 GodBook）；每個章節會記住上傳時的資料夾，改設定後舊檔案仍讀得到。
enum CloudPath {
    static let defaultRoot = ["GodBook"]

    /// 目前設定的資料夾
    static var root: [String] { CloudSettings.shared.rootPath }
    static var index: [String] { root + ["index.json"] }

    static func comic(_ folder: String, root: [String]? = nil) -> [String] { (root ?? self.root) + ["Comics", folder] }

    /// 使用者輸入的資料夾名稱：替換各家雲端不接受的字元，去掉前後空白與句點
    static func folderName(_ raw: String) -> String? {
        let invalid = CharacterSet(charactersIn: "\\\"*:<>?|#%").union(.controlCharacters)
        let text = String(String.UnicodeScalarView(raw.unicodeScalars.map { invalid.contains($0) ? "_" : $0 }))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return text.isEmpty ? nil : text
    }

    static func folder(for summary: ComicSummary) -> String {
        component(DownloadStorage.comicDir(summary).lastPathComponent)
    }

    static func fileName(for chapter: Chapter) -> String {
        component("ch_" + chapter.id) + ".cbz"
    }

    /// 轉成各家雲端都接受的檔名；有字元被替換時加上雜湊，避免不同 ID 撞名
    static func component(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.() "))
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if text != raw || text.isEmpty || text.count > 80 {
            text = String(text.prefix(60)) + "_" + shortHash(raw)
        }
        return text
    }

    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// 已上傳到雲端的章節
struct CloudRecord: Codable, Hashable {
    var kind: CloudKind
    var summary: ComicSummary
    var chapter: Chapter
    var folder: String
    var fileName: String
    var size: Int64
    var uploadedAt: Date
    /// Google Drive 的檔案 ID（其他服務以路徑存取）
    var remoteId: String?
    /// 上傳時的雲端資料夾（舊紀錄沒有此欄位，代表預設的 GodBook）
    var root: [String]?

    var comicPath: [String] { CloudPath.comic(folder, root: root ?? CloudPath.defaultRoot) }
    var path: [String] { comicPath + [fileName] }
}

/// 從雲端刪除、但還沒同步到雲端清單的章節
struct CloudTombstone: Codable, Hashable {
    var kind: CloudKind
    var comicId: String
    var chapterId: String
}

/// 存在雲端的下載清單（GodBook/index.json），換裝置時用來還原。
struct CloudIndex: Codable {
    struct Entry: Codable {
        var title: String
        var fileName: String
        var size: Int64
        var uploadedAt: Date
        var remoteId: String?
        var root: [String]?
    }

    struct Comic: Codable {
        var detail: ComicDetail
        var folder: String
        var chapters: [String: Entry]
    }

    var version = 1
    var updatedAt = Date()
    var comics: [String: Comic] = [:]
}

struct CloudUploadResult {
    var size: Int64?
    var remoteId: String?
}
