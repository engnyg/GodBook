import Foundation

/// 禁漫行動端 API 客戶端，協定移植自 jmcomic (MIT)：
/// 以 timestamp 產生 token / tokenparam，回應為 Base64 + AES-ECB 加密的 JSON。
final class JMClient {
    static let shared = JMClient()

    private let builtinDomains = [
        "www.cdnhjk.net", "www.cdngwc.cc", "www.cdngwc.net", "www.cdngwc.club",
        "www.cdnzack.cc", "www.cdnhth.cc", "www.cdnhth.net", "www.cdnbea.net", "www.cdn-mspjmapiproxy.xyz",
    ]
    private let domainServerURLs = [
        "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c03.tos-cn-beijing.bytepluses.com.cn/newsvr-2025.txt",
    ]
    let imageDomains = [
        "cdn-msp.jmapiproxy1.cc", "cdn-msp.jmapiproxy2.cc", "cdn-msp2.jmapiproxy2.cc",
        "cdn-msp3.jmapiproxy2.cc", "cdn-msp.jmapinodeudzn.net", "cdn-msp3.jmapinodeudzn.net",
    ]

    private let lock = NSLock()
    private var discovered: [String]?
    private var preferred: String?
    private var preferredProfile = 0
    private var triedDiscovery = false

    static let userAgent = "Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36"

    var imageDomain: String { imageDomains.randomElement() ?? imageDomains[0] }

    // MARK: 網域

    private func domains() async -> [String] {
        let custom = AppSettings.shared.jmCustomDomain
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        if !custom.isEmpty { return custom }

        lock.lock()
        let needDiscovery = !triedDiscovery
        triedDiscovery = true
        lock.unlock()
        if needDiscovery { await discoverDomains() }

        lock.lock(); defer { lock.unlock() }
        var list = (discovered ?? []) + builtinDomains.filter { !(discovered ?? []).contains($0) }
        if let preferred, let index = list.firstIndex(of: preferred) {
            list.remove(at: index)
            list.insert(preferred, at: 0)
        }
        return list
    }

    /// 向官方域名伺服器查詢最新的 API 網域；失敗則沿用內建清單。
    private func discoverDomains() async {
        for urlString in domainServerURLs.shuffled() {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, _) = try await HTTP.data(for: request)
                var text = String(decoding: data, as: UTF8.self)
                while let first = text.unicodeScalars.first, !first.isASCII { text.removeFirst() }
                let plain = try JMCrypto.decrypt(text, ts: "", secret: JMCrypto.domainServerSecret)
                let json = try HTTP.json(plain)
                let servers = json.strings("Server")
                if !servers.isEmpty {
                    lock.lock(); discovered = servers; lock.unlock()
                    return
                }
            } catch {
                continue
            }
        }
    }

    // MARK: 請求

    struct Response {
        let ts: String
        let body: Data
    }

    func call(_ path: String,
              query: [URLQueryItem] = [],
              form: [String: String]? = nil,
              scramble: Bool = false) async throws -> Response {
        var lastError: Error = AppError.message(L("所有 API 網域皆無法連線"))
        let profileOrder: [Int] = {
            lock.lock(); defer { lock.unlock() }
            let all = Array(JMCrypto.profiles.indices)
            return [preferredProfile] + all.filter { $0 != preferredProfile }
        }()

        for domain in await domains() {
            for profileIndex in profileOrder {
                let profile = JMCrypto.profiles[profileIndex]
                let ts = String(Int(Date().timeIntervalSince1970))
                var components = URLComponents()
                components.scheme = "https"
                components.host = domain
                components.path = path
                if !query.isEmpty { components.queryItems = query }
                guard let url = components.url else { continue }

                var request = URLRequest(url: url)
                // 回應是用本次的時間戳加密的；不能拿 URL 快取裡的舊回應（會解密失敗，也可能混到登入前後的內容）
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let secret = scramble ? profile.scrambleSecret : profile.tokenSecret
                let (token, tokenparam) = JMCrypto.token(ts: ts, secret: secret, version: profile.version)
                request.setValue(token, forHTTPHeaderField: "token")
                request.setValue(tokenparam, forHTTPHeaderField: "tokenparam")
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                if let form {
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var encoder = URLComponents()
                    encoder.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
                    request.httpBody = Data((encoder.percentEncodedQuery ?? "").utf8)
                }
                installSessionCookie(domain: domain)

                do {
                    let (data, response) = try await HTTP.data(for: request)
                    guard response.statusCode == 200 else {
                        // 密鑰過期時伺服器會回 403；換下一組密鑰再試
                        lastError = AppError.http(response.statusCode)
                        continue
                    }
                    // 有些網域會回 200 但內容不是 API 的 JSON（維護頁、封鎖頁…）；這種直接換下一個網域
                    if !scramble && !Self.looksLikeEnvelope(data) {
                        let snippet = String(String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                        lastError = AppError.message(L("禁漫：%@ 回傳的不是有效資料：%@", domain, snippet))
                        break
                    }
                    lock.lock()
                    preferred = domain
                    preferredProfile = profileIndex
                    lock.unlock()
                    return Response(ts: ts, body: data)
                } catch {
                    lastError = error
                    if Task.isCancelled { throw error }
                    break // 連線層級失敗：直接換下一個網域
                }
            }
        }
        throw lastError
    }

    private static func looksLikeEnvelope(_ data: Data) -> Bool {
        var text = String(decoding: data, as: UTF8.self)
        if let brace = text.firstIndex(of: "{") { text = String(text[brace...]) } else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
        return object["code"] != nil
    }

    /// 呼叫並解密 JSON 回應，回傳解密後的 `data`。
    func json(_ path: String,
              query: [URLQueryItem] = [],
              form: [String: String]? = nil) async throws -> [String: Any] {
        let response = try await call(path, query: query, form: form)
        return try decode(response)
    }

    func decode(_ response: Response) throws -> [String: Any] {
        var text = String(decoding: response.body, as: UTF8.self)
        if let brace = text.firstIndex(of: "{") { text = String(text[brace...]) }
        let envelope = try HTTP.json(Data(text.utf8))
        guard (envelope.int("code") ?? 0) == 200 else {
            let message = envelope.string("errorMsg") ?? envelope.string("message") ?? L("請求失敗")
            let lower = message.lowercased()
            if envelope.int("code") == 401 || lower.contains("登入") || lower.contains("登录") || lower.contains("login") {
                throw AppError.message(L("禁漫：%@\n這個內容需要登入，請到「設定 → 禁漫」登入帳號", "\(message)"))
            }
            throw AppError.message(L("禁漫：%@", "\(message)"))
        }
        guard let encoded = envelope["data"] as? String else { return [:] }
        let plain = try JMCrypto.decrypt(encoded, ts: response.ts, secret: JMCrypto.dataSecret)
        guard let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            // 沒登入時，需要會員的內容常回空陣列或無法解析的資料
            let hint = AppSettings.shared.jmAVS.isEmpty ? L("（可能需要登入，請到「設定 → 禁漫」登入帳號）") : ""
            throw AppError.message(L("無法解析禁漫資料") + hint)
        }
        return object
    }

    private func installSessionCookie(domain: String) {
        let avs = AppSettings.shared.jmAVS
        guard !avs.isEmpty,
              let cookie = HTTPCookie(properties: [.name: "AVS", .value: avs, .domain: domain, .path: "/"])
        else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
    }

    // MARK: 登入

    func login(username: String, password: String) async throws {
        let result = try await json("/login", form: ["username": username, "password": password])
        guard let session = result.string("s") else { throw AppError.message(L("登入失敗：沒有取得工作階段")) }
        await MainActor.run {
            AppSettings.shared.jmAVS = session
            AppSettings.shared.jmUsername = username
        }
    }

    func logout() async {
        await MainActor.run {
            AppSettings.shared.jmAVS = ""
        }
    }
}

struct JMComicSource: ComicSource {
    let kind = SourceKind.jmcomic

    let sortOptions: [SortOption] = [
        SortOption(id: "mr", title: L("最新"), order: "mr", time: "a"),
        SortOption(id: "mv_t", title: L("觀看（今日）"), order: "mv", time: "t"),
        SortOption(id: "mv_w", title: L("觀看（本週）"), order: "mv", time: "w"),
        SortOption(id: "mv_m", title: L("觀看（本月）"), order: "mv", time: "m"),
        SortOption(id: "mv", title: L("觀看（全部）"), order: "mv", time: "a"),
        SortOption(id: "tf", title: L("愛心最多"), order: "tf", time: "a"),
        SortOption(id: "mp", title: L("圖片最多"), order: "mp", time: "a"),
    ]

    private let client = JMClient.shared

    var capabilities: SourceCapabilities { SourceCapabilities(comments: true, remoteFavorites: true) }

    func loadComments(_ context: CommentContext, page: Int, replyTo: String?) async throws -> CommentPage {
        let result = try await client.json("/forum", query: [
            URLQueryItem(name: "mode", value: "all"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "aid", value: context.summary.sid),
        ])
        func map(_ item: [String: Any]) -> ComicComment {
            let replies = result.isEmpty ? [] : ((item["replys"] as? [[String: Any]]) ?? []).map(map)
            let name = item.string("nickname").flatMap { $0.isEmpty ? nil : $0 } ?? item.string("username") ?? "?"
            return ComicComment(id: item.string("CID") ?? UUID().uuidString, userName: name, avatar: nil,
                                content: item.string("content") ?? "", time: item.string("addtime"),
                                replyCount: replies.isEmpty ? nil : replies.count,
                                score: item.int("likes"), replies: replies)
        }
        let list = result.dicts("list").map(map)
        let total = result.int("total") ?? 0
        return CommentPage(comments: list, maxPage: total > 0 ? max(1, Int((Double(total) / 10).rounded(.up))) : nil)
    }

    func remoteFavorites(for summary: ComicSummary) async throws -> RemoteFavoriteState {
        let json = try await client.json("/album", query: [URLQueryItem(name: "id", value: summary.sid)])
        let favorited = (json["is_favorite"] as? Bool) == true || json.string("is_favorite") == "true"
        return RemoteFavoriteState(folders: [RemoteFolder(id: "0", name: L("禁漫收藏"))],
                                   favorited: favorited ? ["0"] : [], canManageFolders: false)
    }

    func setRemoteFavorite(_ summary: ComicSummary, folderId: String, adding: Bool) async throws {
        let state = try await remoteFavorites(for: summary)
        // 禁漫的收藏 API 是「切換」；狀態已符合就不用再送
        guard state.favorited.contains(folderId) != adding else { return }
        _ = try await client.json("/favorite", form: ["aid": summary.sid])
    }

    private func coverURL(_ id: String) -> URL? {
        URL(string: "https://\(client.imageDomain)/media/albums/\(id)_3x4.jpg")
    }

    private func summary(from item: [String: Any]) -> ComicSummary? {
        guard let id = item.string("id") else { return nil }
        var parts: [String] = []
        if let author = item.string("author"), !author.isEmpty { parts.append(author) }
        if let category = (item["category"] as? [String: Any])?.string("title") { parts.append(category) }
        return ComicSummary(
            source: .jmcomic,
            sid: id,
            title: item.string("name") ?? "JM\(id)",
            coverURL: coverURL(id),
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }

    // MARK: ComicSource

    func filterGroups(query: String) -> [FilterGroup] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return [FilterGroup(id: "c", title: L("分類"), kind: .select, options: [
            FilterOption(value: "0", title: L("全部")), FilterOption(value: "doujin", title: L("同人")),
            FilterOption(value: "single", title: L("單本")), FilterOption(value: "short", title: L("短篇")),
            FilterOption(value: "another", title: L("其他")), FilterOption(value: "hanman", title: L("韓漫")),
            FilterOption(value: "meiman", title: L("美漫")), FilterOption(value: "doujin_cosplay", title: "Cosplay"),
            FilterOption(value: "3D", title: "3D"), FilterOption(value: "english_site", title: L("英文站")),
        ], defaultValue: "0")]
    }

    func browse(query: String, page: Int, sort: SortOption, filters: [String: String]) async throws -> ComicPageResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: [String: Any]
        if trimmed.isEmpty {
            let order = sort.time == "a" ? sort.order : "\(sort.order)_\(sort.time)"
            result = try await client.json("/categories/filter", query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "order", value: ""),
                URLQueryItem(name: "c", value: filters["c"] ?? "0"),
                URLQueryItem(name: "o", value: order),
            ])
        } else {
            result = try await client.json("/search", query: [
                URLQueryItem(name: "main_tag", value: "0"),
                URLQueryItem(name: "search_query", value: trimmed),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "o", value: sort.order),
                URLQueryItem(name: "t", value: sort.time),
            ])
            // 直接搜尋車號時，伺服器會回傳 redirect_aid
            if let aid = result.string("redirect_aid"), !aid.isEmpty {
                let detail = try await self.detail(of: ComicSummary(source: .jmcomic, sid: aid, title: "JM\(aid)"))
                return ComicPageResult(items: [detail.summary], total: 1, totalPages: 1)
            }
        }
        let items = result.dicts("content").compactMap(summary(from:))
        return ComicPageResult(items: items, total: result.int("total"), totalPages: nil)
    }

    func favorites(page: Int) async throws -> ComicPageResult {
        let result = try await client.json("/favorite", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "folder_id", value: "0"),
            URLQueryItem(name: "o", value: "mr"),
        ])
        return ComicPageResult(items: result.dicts("list").compactMap(summary(from:)),
                               total: result.int("total"), totalPages: nil)
    }

    func detail(of summary: ComicSummary) async throws -> ComicDetail {
        let json = try await client.json("/album", query: [URLQueryItem(name: "id", value: summary.sid)])
        guard let name = json.string("name") else { throw AppError.message(L("找不到這本漫畫")) }

        var base = summary
        base.title = name
        base.coverURL = coverURL(summary.sid)
        let authors = json.strings("author")
        base.subtitle = authors.joined(separator: " · ")

        var tags: [ComicTag] = json.strings("tags").map { ComicTag(name: $0, group: "tag", query: $0) }
        tags += json.strings("works").map { ComicTag(name: $0, group: "work", query: $0) }
        tags += json.strings("actors").map { ComicTag(name: $0, group: "actor", query: $0) }

        var chapters = json.dicts("series").compactMap { item -> (Int, Chapter)? in
            guard let id = item.string("id") else { return nil }
            let sort = item.int("sort") ?? 0
            let rawTitle = item.string("name") ?? ""
            return (sort, Chapter(id: id, title: rawTitle.isEmpty ? L("第%@話", "\(sort)") : rawTitle))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
        if chapters.isEmpty { chapters = [Chapter(id: summary.sid, title: L("開始閱讀"))] }

        var stats: [String] = []
        if let views = json.string("total_views") { stats.append("👁 \(views)") }
        if let likes = json.string("likes") { stats.append("♥ \(likes)") }
        if let comments = json.string("comment_total") { stats.append("💬 \(comments)") }
        stats.append("JM\(summary.sid)")

        let description = json.string("description").flatMap { $0.isEmpty ? nil : $0 }
        let related = json.dicts("related_list").compactMap(self.summary(from:))
        var detail = ComicDetail(
            summary: base,
            description: description,
            authors: authors,
            tags: tags,
            stats: stats,
            chapters: chapters,
            related: related,
            pageCount: json.int("total_photos")
        )
        detail.url = "https://jmcomic.me/album/\(summary.sid)"
        detail.isRemoteFavorite = (json["is_favorite"] as? Bool) ?? (json.string("is_favorite") == "true")
        return detail
    }

    func pages(of detail: ComicDetail, chapter: Chapter) async throws -> [ReaderPage] {
        let json = try await client.json("/chapter", query: [URLQueryItem(name: "id", value: chapter.id)])
        let names = json.strings("images")
        guard !names.isEmpty else { throw AppError.message(L("這個章節沒有圖片")) }
        let scrambleId = await fetchScrambleId(chapter.id)
        let aid = Int(chapter.id) ?? 0
        let domain = client.imageDomain
        let stamp = String(Int(Date().timeIntervalSince1970))

        return names.enumerated().compactMap { index, name in
            guard let url = URL(string: "https://\(domain)/media/photos/\(chapter.id)/\(name)?v=\(stamp)") else { return nil }
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension
            let count = ext == "gif" ? 0 : JMCrypto.scrambleCount(scrambleId: scrambleId, aid: aid, filename: stem)
            return ReaderPage(index: index, image: ImageSpec(url: url, source: .jmcomic, scramble: count))
        }
    }

    /// `/chapter_view_template` 回傳 HTML 文字，內含 `var scramble_id = N;`；使用另一組密鑰。
    private func fetchScrambleId(_ chapterId: String) async -> Int {
        let fallback = 220980
        do {
            let response = try await client.call("/chapter_view_template", query: [
                URLQueryItem(name: "id", value: chapterId),
                URLQueryItem(name: "mode", value: "vertical"),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "app_img_shunt", value: "1"),
                URLQueryItem(name: "express", value: "off"),
                URLQueryItem(name: "v", value: String(Int(Date().timeIntervalSince1970))),
            ], scramble: true)
            let text = String(decoding: response.body, as: UTF8.self)
            if let range = text.range(of: #"var scramble_id = (\d+);"#, options: .regularExpression) {
                let digits = text[range].filter(\.isNumber)
                return Int(digits) ?? fallback
            }
        } catch {}
        return fallback
    }
}
