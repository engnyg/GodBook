import Foundation

/// nhentai 來源。API 流程移植自 NClientV3 (Apache-2.0) 的 InspectorV3：
/// 使用 `/api/v2/galleries`、`/api/v2/search`、`/api/v2/galleries/{id}?include=related,favorite`。
struct NHentaiSource: ComicSource {
    let kind = SourceKind.nhentai

    let sortOptions: [SortOption] = [
        SortOption(id: "recent", title: L("最新")),
        SortOption(id: "popular", title: L("熱門（全部）"), order: "popular"),
        SortOption(id: "popular-month", title: L("熱門（本月）"), order: "popular-month"),
        SortOption(id: "popular-week", title: L("熱門（本週）"), order: "popular-week"),
        SortOption(id: "popular-today", title: L("熱門（今日）"), order: "popular-today"),
    ]

    private var host: String {
        let value = AppSettings.shared.nhMirror.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "nhentai.net" : value
    }

    private func request(_ path: String, _ items: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/" + path
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw AppError.message(L("網址無效")) }
        var request = URLRequest(url: url)
        request.setValue("NClient/3 (GodBook iOS)", forHTTPHeaderField: "User-Agent")
        let key = AppSettings.shared.nhApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Key \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> [String: Any] {
        var attempt = 0
        while true {
            let (data, response) = try await HTTP.data(for: request)
            if response.statusCode == 429, attempt < 2 {
                // 被限流：依 Retry-After（預設 2 秒）等待後重試
                let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 8) * 1_000_000_000))
                attempt += 1
                continue
            }
            guard response.statusCode == 200 else { throw AppError.http(response.statusCode) }
            return try HTTP.json(data)
        }
    }

    private func thumbURL(_ path: String) -> URL? {
        URL(string: "https://t1.\(host)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
    }

    private func imageURL(_ path: String) -> URL? {
        URL(string: "https://i1.\(host)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
    }

    // MARK: ComicSource

    var supportsTagSuggestions: Bool { true }

    var capabilities: SourceCapabilities { SourceCapabilities(comments: true) }

    func loadComments(_ context: CommentContext, page: Int, replyTo: String?) async throws -> CommentPage {
        guard page == 1, replyTo == nil else { return CommentPage(comments: [], maxPage: 1) }
        let (data, response) = try await HTTP.data(for: try request("galleries/\(context.summary.sid)/comments"))
        guard response.statusCode == 200 else { throw AppError.http(response.statusCode) }
        let object = try JSONSerialization.jsonObject(with: data)
        let list = (object as? [[String: Any]])
            ?? ((object as? [String: Any])?["result"] as? [[String: Any]])
            ?? ((object as? [String: Any])?["comments"] as? [[String: Any]]) ?? []
        let comments = list.map { item -> ComicComment in
            let poster = item["poster"] as? [String: Any] ?? [:]
            var avatar: URL?
            if let path = poster.string("avatar_url") {
                avatar = path.hasPrefix("http") ? URL(string: path) : URL(string: "https://i1.\(host)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
            }
            let time = (item["post_date"] as? Double).map {
                Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
            }
            return ComicComment(id: item.string("id") ?? UUID().uuidString, userName: poster.string("username") ?? "?",
                                avatar: avatar, content: item.string("body") ?? "", time: time)
        }
        return CommentPage(comments: comments, maxPage: 1)
    }

    func filterGroups(query: String) -> [FilterGroup] {
        [FilterGroup(id: "lang", title: L("語言"), kind: .select,
                     options: [FilterOption(value: "none", title: L("不限")), FilterOption(value: "chinese", title: L("中文")),
                               FilterOption(value: "english", title: L("英文")), FilterOption(value: "japanese", title: L("日文"))],
                     defaultValue: AppSettings.shared.autoLanguage)]
    }

    func browse(query: String, page: Int, sort: SortOption, filters: [String: String]) async throws -> ComicPageResult {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = filters["lang"] ?? AppSettings.shared.autoLanguage
        if language != "none", !language.isEmpty, !trimmed.contains("language:") {
            trimmed = (trimmed + " language:\(language)").trimmingCharacters(in: .whitespaces)
        }
        var items = [URLQueryItem(name: "page", value: String(page))]
        let path: String
        if trimmed.isEmpty && sort.order.isEmpty {
            path = "galleries"
        } else {
            path = "search"
            // NClientV3：沒有關鍵字但要依熱度排序時，使用 "-nclientv3" 這個排除條件取得全站清單
            items.insert(URLQueryItem(name: "query", value: trimmed.isEmpty ? "-nclientv3" : trimmed), at: 0)
            if !sort.order.isEmpty { items.append(URLQueryItem(name: "sort", value: sort.order)) }
        }
        let json = try await fetch(try request(path, items))
        guard json["result"] != nil else { throw AppError.message(L("伺服器沒有回傳結果")) }
        let list = json.dicts("result").compactMap(summary(from:))
        return ComicPageResult(items: list, total: json.int("total"), totalPages: json.int("num_pages"))
    }

    func detail(of summary: ComicSummary) async throws -> ComicDetail {
        let json = try await fetch(try request("galleries/\(summary.sid)",
                                               [URLQueryItem(name: "include", value: "related,favorite")]))
        if json["error"] != nil { throw AppError.message(L("找不到這本漫畫")) }
        guard let base = self.summary(from: json) else { throw AppError.message(L("資料格式錯誤")) }

        var tags: [ComicTag] = []
        var authors: [String] = []
        for tag in json.dicts("tags") {
            guard let name = tag.string("name"), let type = tag.string("type") else { continue }
            let query = "\(type):\"\(name)\""
            tags.append(ComicTag(name: name, group: type, query: query))
            if type == "artist" { authors.append(name) }
        }

        let pages = json.dicts("pages").enumerated().compactMap { index, page -> ReaderPage? in
            guard let path = page.string("path"), let url = imageURL(path) else { return nil }
            return ReaderPage(index: index, image: ImageSpec(url: url, source: .nhentai))
        }

        var stats: [String] = []
        if let favorites = json.int("num_favorites") { stats.append("♥ \(favorites)") }
        if let timestamp = json["upload_date"] as? Double {
            stats.append(Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .omitted))
        }
        stats.append("ID \(summary.sid)")

        var result = base
        result.tags = tags.map(\.name)
        if let cover = (json["cover"] as? [String: Any])?.string("path"), let url = thumbURL(cover) {
            result.coverURL = url
        }
        return ComicDetail(
            summary: result,
            description: nil,
            authors: authors,
            tags: tags,
            stats: stats,
            chapters: [Chapter(id: summary.sid, title: L("全部頁面"))],
            related: json.dicts("related").compactMap(self.summary(from:)),
            pageCount: pages.count,
            preloadedPages: pages,
            url: "https://\(host)/g/\(summary.sid)/"
        )
    }

    func pages(of detail: ComicDetail, chapter: Chapter) async throws -> [ReaderPage] {
        if let pages = detail.preloadedPages, !pages.isEmpty { return pages }
        return try await self.detail(of: detail.summary).preloadedPages ?? []
    }

    // MARK: 解析

    private func summary(from json: [String: Any]) -> ComicSummary? {
        guard let id = json.int("id") else { return nil }
        var title = ""
        if let titles = json["title"] as? [String: Any] {
            title = [titles.string("pretty"), titles.string("english"), titles.string("japanese")]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        } else {
            title = [json.string("english_title"), json.string("japanese_title")]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        if title.isEmpty { title = "#\(id)" }
        let thumb = json.string("thumbnail") ?? (json["thumbnail"] as? [String: Any])?.string("path") ?? ""
        let pages = json.int("num_pages")
        return ComicSummary(
            source: .nhentai,
            sid: String(id),
            title: title,
            coverURL: thumb.isEmpty ? nil : thumbURL(thumb),
            subtitle: pages.map { L("%@ 頁", "\($0)") }
        )
    }
}
