import Foundation

/// 把 venera 漫畫源（JS）轉接成 GodBook 的 ComicSource。
struct VeneraSource: ComicSource {
    let kind: SourceKind

    private final class TokenBox {
        var next: [Int: String] = [:]
        var folder: String??
    }
    private let tokens = TokenBox()

    private var key: String { kind.veneraKey }
    private var info: VeneraInfo? { VeneraRegistry.shared.info(key) }
    private var runtime: VeneraRuntime { .shared }

    /// 呼叫腳本函式；若腳本回報登入過期，用已儲存的帳密重新登入後重試一次。
    private func invoke(_ function: String, _ args: [Any?]) async throws -> [String: Any] {
        do {
            return try await runtime.call(key, function, args)
        } catch let error as AppError {
            guard case .message(let text) = error, text.contains("Login expired"),
                  let account = Keychain.get("venera.\(key).account"),
                  let password = Keychain.get("venera.\(key).password") else { throw error }
            _ = try await runtime.callValue(key, "__login", [account, password])
            return try await runtime.call(key, function, args)
        }
    }

    init(kind: SourceKind) { self.kind = kind }

    // MARK: 排序 / 分區

    var supportsTagSuggestions: Bool { info?.search?.enableTags == true }

    var capabilities: SourceCapabilities {
        guard let info else { return SourceCapabilities() }
        let c = info.comic
        return SourceCapabilities(
            comments: c?.comments == true, sendComments: c?.sendComment == true,
            chapterComments: c?.chapterComments == true, sendChapterComments: c?.sendChapterComment == true,
            likeComic: c?.like == true, rating: c?.rating == true, thumbnails: c?.thumbnails == true,
            likeComment: c?.likeComment == true, voteComment: c?.voteComment == true,
            remoteFavorites: info.favorites?.canToggle == true)
    }

    private func mapComments(_ value: Any?) -> [ComicComment] {
        ((value as? [[String: Any]]) ?? []).map { item in
            ComicComment(id: (item["id"] as? String) ?? "", userName: (item["userName"] as? String) ?? "",
                         avatar: (item["avatar"] as? String).flatMap(VeneraURL.make),
                         content: (item["content"] as? String) ?? "", time: item["time"] as? String,
                         replyCount: item["replyCount"] as? Int, score: item["score"] as? Int,
                         isLiked: item["isLiked"] as? Bool, voteStatus: item["voteStatus"] as? Int)
        }
    }

    func loadComments(_ context: CommentContext, page: Int, replyTo: String?) async throws -> CommentPage {
        let r = try await invoke("__comments", [context.summary.sid, context.subId, context.chapterId, page, replyTo])
        return CommentPage(comments: mapComments(r["comments"]), maxPage: r["maxPage"] as? Int)
    }

    func sendComment(_ context: CommentContext, content: String, replyTo: String?) async throws {
        _ = try await invoke("__sendComment", [context.summary.sid, context.subId, context.chapterId, content, replyTo])
    }

    func likeComment(_ context: CommentContext, commentId: String, like: Bool) async throws {
        _ = try await runtime.callValue(key, "__likeComment", [context.summary.sid, context.subId, commentId, like])
    }

    func voteComment(_ context: CommentContext, commentId: String, up: Bool, cancel: Bool) async throws -> Int {
        let value = try await runtime.callValue(key, "__voteComment", [context.summary.sid, context.subId, commentId, up, cancel])
        return (value as? Int) ?? 0
    }

    func setLiked(_ summary: ComicSummary, liked: Bool) async throws {
        _ = try await runtime.callValue(key, "__likeComic", [summary.sid, liked])
    }

    func rate(_ summary: ComicSummary, stars: Int) async throws {
        _ = try await runtime.callValue(key, "__rate", [summary.sid, stars])
    }

    func loadThumbnails(_ summary: ComicSummary, next: String?) async throws -> (urls: [String], next: String?) {
        let r = try await invoke("__thumbnails", [summary.sid, next])
        return ((r["thumbnails"] as? [String]) ?? [], r["next"] as? String)
    }

    func remoteFavorites(for summary: ComicSummary) async throws -> RemoteFavoriteState {
        let r = try await invoke("__favFolders", [summary.sid])
        let folders = ((r["folders"] as? [[String: Any]]) ?? []).compactMap { item -> RemoteFolder? in
            guard let id = item["id"] as? String else { return nil }
            return RemoteFolder(id: id, name: (item["name"] as? String) ?? id)
        }
        let favorited = Set((r["favorited"] as? [String]) ?? [])
        let canManage = info?.favorites?.canAddFolder == true && info?.favorites?.multiFolder == true
        return RemoteFavoriteState(folders: folders.isEmpty ? [RemoteFolder(id: "0", name: L("收藏"))] : folders,
                                   favorited: favorited, canManageFolders: canManage)
    }

    func setRemoteFavorite(_ summary: ComicSummary, folderId: String, adding: Bool) async throws {
        _ = try await runtime.callValue(key, "__favToggle", [summary.sid, folderId, adding, nil])
    }

    func addRemoteFolder(_ name: String) async throws {
        _ = try await runtime.callValue(key, "__favAddFolder", [name])
    }

    func deleteRemoteFolder(_ id: String) async throws {
        _ = try await runtime.callValue(key, "__favDelFolder", [id])
    }

    private var hidden: Set<String> { VeneraVisibility.hidden(key) }

    var sortOptions: [SortOption] {
        guard let info else { return [SortOption(id: "none", title: "—")] }
        var options: [SortOption] = []
        for (index, page) in info.explore.enumerated() where !hidden.contains("explore:\(page.title)") {
            options.append(SortOption(id: "explore:\(index)", title: page.title, section: L("探索")))
        }
        return options.isEmpty ? [SortOption(id: "none", title: "—")] : options
    }

    func categorySections() -> [CategorySection] {
        guard let info else { return [] }
        var sections: [CategorySection] = []
        if let category = info.category {
            for part in category.parts where !hidden.contains("cat:\(part.name)") {
                let entries = part.items.map { item -> CategoryEntry in
                    if item.kind == "search" { return CategoryEntry(title: item.label, query: item.text ?? item.label) }
                    return CategoryEntry(title: item.label, query: VeneraQuery.category(item.category ?? item.label, item.param))
                }
                if !entries.isEmpty { sections.append(CategorySection(title: part.name.isEmpty ? category.title : part.name, entries: entries)) }
            }
        }
        if let ranking = info.ranking, !hidden.contains("rank") {
            let entries = ranking.options.compactMap { pair -> CategoryEntry? in
                pair.count == 2 ? CategoryEntry(title: pair[1], query: VeneraQuery.rank(pair[0])) : nil
            }
            if !entries.isEmpty { sections.append(CategorySection(title: L("排行"), entries: entries)) }
        }
        return sections
    }

    /// 選中標籤建議後要插入搜尋框的文字（腳本可自訂格式）
    func tagSuggestionText(namespace: String, tag: String) async -> String {
        let value = try? await runtime.callValue(key, "__tagSuggestion", [namespace, tag])
        return (value as? String) ?? "\(namespace):\(tag)"
    }

    // MARK: 瀏覽

    func filterGroups(query: String) -> [FilterGroup] {
        guard let info else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if VeneraQuery.decodeCategory(trimmed) != nil {
            return groups(from: info.categoryOptions, prefix: "c")
        }
        if VeneraQuery.decodeRank(trimmed) != nil || trimmed.isEmpty { return [] }
        return groups(from: info.search?.options ?? [], prefix: "s")
    }

    private func groups(from options: [VeneraInfo.Option], prefix: String) -> [FilterGroup] {
        options.enumerated().compactMap { index, option in
            let choices = option.options.compactMap { pair -> FilterOption? in
                pair.count == 2 ? FilterOption(value: pair[0], title: pair[1]) : nil
            }
            guard !choices.isEmpty else { return nil }
            let kind: FilterGroup.Kind = option.type == "multi-select" ? .multi : (option.type == "dropdown" ? .dropdown : .select)
            return FilterGroup(id: "\(prefix)\(index)", title: option.label.isEmpty ? L("選項 %@", "\(index + 1)") : option.label,
                               kind: kind, options: choices, defaultValue: option.def)
        }
    }

    /// 依使用者在篩選面板的選擇組出傳給腳本的 options 陣列
    private func options(_ list: [VeneraInfo.Option], prefix: String, filters: [String: String]) -> [String?] {
        let defaults = defaultOptions(list)
        return list.enumerated().map { index, _ in
            if let chosen = filters["\(prefix)\(index)"] { return chosen.isEmpty ? nil : chosen }
            return defaults[index]
        }
    }

    func browse(query: String, page: Int, sort: SortOption, filters: [String: String]) async throws -> ComicPageResult {
        guard let info else { throw AppError.message(L("漫畫源尚未載入")) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let (category, param) = VeneraQuery.decodeCategory(trimmed) {
            let result = try await invoke("__category", [category, param, options(info.categoryOptions, prefix: "c", filters: filters), page])
            return decodePage(result, page: page)
        }

        if let option = VeneraQuery.decodeRank(trimmed) {
            let result = try await invoke("__ranking", [option, page, tokens.next[page]])
            return decodePage(result, page: page)
        }

        if !trimmed.isEmpty {
            guard let search = info.search else { throw AppError.message(L("這個漫畫源不支援搜尋")) }
            var keyword = trimmed
            // 與 venera 相同：只對 nhentai / ehentai 自動加語言條件
            let language = filters["lang"] ?? AppSettings.shared.autoLanguage
            if ["nhentai", "ehentai"].contains(key), language != "none", !keyword.contains("language:") {
                keyword += " language:\(language)"
            }
            var chosen = options(search.options, prefix: "s", filters: filters)
            if sort.id.hasPrefix("search:"), !chosen.isEmpty, filters["s0"] == nil {
                chosen[0] = String(sort.id.dropFirst("search:".count))
            }
            let result = try await invoke("__search", [keyword, chosen, page, tokens.next[page]])
            return decodePage(result, page: page)
        }

        let parts = sort.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "explore":
            let result = try await invoke( "__explore", [Int(parts[safe: 1] ?? "") ?? 0, page, tokens.next[page]])
            return decodePage(result, page: page)
        case "cat":
            let item = info.category?.parts[safe: Int(parts[safe: 1] ?? "") ?? 0]?.items[safe: Int(parts[safe: 2] ?? "") ?? 0]
            guard let item else { throw AppError.message(L("分類不存在")) }
            if item.kind == "search" {
                return try await browse(query: item.text ?? item.label, page: page, sort: SortOption(id: "none", title: ""), filters: filters)
            }
            let result = try await invoke("__category", [item.category ?? item.label, item.param, options(info.categoryOptions, prefix: "c", filters: filters), page])
            return decodePage(result, page: page)
        case "rank":
            let result = try await invoke( "__ranking", [parts.dropFirst().joined(separator: ":"), page, tokens.next[page]])
            return decodePage(result, page: page)
        default:
            // 沒有選任何分區時的預設行為
            if !info.explore.isEmpty {
                let result = try await invoke( "__explore", [0, page, tokens.next[page]])
                return decodePage(result, page: page)
            }
            throw AppError.message(L("這個漫畫源沒有可瀏覽的首頁，請使用搜尋"))
        }
    }

    func favorites(page: Int) async throws -> ComicPageResult {
        guard let info, let favorites = info.favorites else { throw AppError.message(L("這個漫畫源沒有雲端收藏")) }
        var folder: String?
        if favorites.multiFolder {
            if tokens.folder == nil {
                let result = try await invoke( "__favoriteFolders", [])
                let first = (result["folders"] as? [[String: Any]])?.first?["id"] as? String
                tokens.folder = .some(first)
            }
            folder = tokens.folder ?? nil
        }
        let result = try await invoke( "__favorites", [page, folder, tokens.next[page]])
        return decodePage(result, page: page)
    }

    // MARK: 詳情

    func detail(of summary: ComicSummary) async throws -> ComicDetail {
        let r = try await invoke( "__loadInfo", [summary.sid])

        var base = summary
        if let title = r["title"] as? String, !title.isEmpty { base.title = title }
        if let cover = (r["cover"] as? String).flatMap(VeneraURL.make) { base.coverURL = cover }
        let subtitle = (r["subtitle"] as? String) ?? ""
        if !subtitle.isEmpty { base.subtitle = subtitle }

        let authorNamespaces: Set<String> = ["author", "authors", "artist", "artists", "作者", "画师", "畫師"]
        var tags: [ComicTag] = []
        var authors: [String] = []
        for item in (r["tags"] as? [[String: Any]]) ?? [] {
            guard let name = item["name"] as? String else { continue }
            let namespace = (item["ns"] as? String) ?? ""
            var query: String? = name
            if let target = item["target"] as? [String: Any] {
                if (target["kind"] as? String) == "category", let category = target["category"] as? String {
                    query = VeneraQuery.category(category, target["param"] as? String)
                } else if let text = target["text"] as? String {
                    query = text
                }
            }
            tags.append(ComicTag(name: name, group: namespace.isEmpty ? nil : namespace, query: query))
            if authorNamespaces.contains(namespace.lowercased()) { authors.append(name) }
        }
        if authors.isEmpty, !subtitle.isEmpty { authors = [subtitle] }

        var chapters: [Chapter] = ((r["chapters"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let title = (item["title"] as? String) ?? id
            if let group = item["group"] as? String, !group.isEmpty { return Chapter(id: id, title: "\(group) · \(title)") }
            return Chapter(id: id, title: title)
        }
        if chapters.isEmpty { chapters = [Chapter(id: VeneraQuery.noChapter, title: L("開始閱讀"))] }

        var stats: [String] = []
        if let likes = r["likesCount"] as? Int { stats.append("♥ \(likes)") }
        if let comments = r["commentCount"] as? Int { stats.append("💬 \(comments)") }
        if let stars = r["stars"] as? Double { stats.append("★ \(String(format: "%.1f", stars))") }
        if let uploader = r["uploader"] as? String, !uploader.isEmpty { stats.append(uploader) }
        if let updated = (r["updateTime"] as? String) ?? (r["uploadTime"] as? String) { stats.append(updated) }

        let related = ((r["recommend"] as? [[String: Any]]) ?? []).compactMap(makeSummary)
        let description = (r["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var detail = ComicDetail(summary: base, description: description, authors: authors, tags: tags,
                                 stats: stats, chapters: chapters, related: related, pageCount: r["maxPage"] as? Int)
        detail.subId = r["subId"] as? String
        detail.url = r["url"] as? String
        detail.isLiked = r["isLiked"] as? Bool
        detail.stars = r["stars"] as? Double
        detail.thumbnails = r["thumbnails"] as? [String]
        detail.isRemoteFavorite = r["isFavorite"] as? Bool
        return detail
    }

    func pages(of detail: ComicDetail, chapter: Chapter) async throws -> [ReaderPage] {
        let epId: String? = chapter.id == VeneraQuery.noChapter ? nil : chapter.id
        let result = try await invoke( "__loadEp", [detail.summary.sid, epId])
        let images = (result["images"] as? [String]) ?? []
        guard !images.isEmpty else { throw AppError.message(L("這個章節沒有圖片")) }
        return images.enumerated().map { index, string in
            let spec = ImageSpec(url: VeneraURL.make(string) ?? VeneraURL.placeholder, source: kind,
                                 imageKey: string, comicId: detail.summary.sid, epId: epId ?? "")
            return ReaderPage(index: index, image: spec)
        }
    }

    // MARK: 轉換

    private func makeSummary(_ item: [String: Any]) -> ComicSummary? {
        guard let id = item["id"] as? String else { return nil }
        var subtitle = (item["subtitle"] as? String) ?? ""
        if subtitle.isEmpty, let tags = item["tags"] as? [String], !tags.isEmpty {
            subtitle = tags.prefix(3).joined(separator: " · ")
        }
        return ComicSummary(source: kind, sid: id, title: (item["title"] as? String) ?? id,
                            coverURL: (item["cover"] as? String).flatMap(VeneraURL.make),
                            subtitle: subtitle.isEmpty ? nil : subtitle,
                            tags: (item["tags"] as? [String]))
    }

    private func decodePage(_ result: [String: Any], page: Int) -> ComicPageResult {
        let items = ((result["comics"] as? [[String: Any]]) ?? []).compactMap(makeSummary)
        if let next = result["next"] as? String { tokens.next[page + 1] = next }
        var totalPages = result["maxPage"] as? Int
        if totalPages == nil, (result["usesNext"] as? Bool) == true, result["next"] == nil || result["next"] is NSNull {
            totalPages = page
        }
        return ComicPageResult(items: items, total: nil, totalPages: totalPages)
    }

    private func defaultOptions(_ options: [VeneraInfo.Option]) -> [String?] {
        options.map { option in
            if let value = option.def { return value }
            if option.type == "multi-select" { return "[]" }
            if option.type == "dropdown" { return nil }
            return option.options.first?.first
        }
    }

    private func defaultCategoryOptions(_ info: VeneraInfo) -> [String?] {
        defaultOptions(info.categoryOptions)
    }
}

enum VeneraURL {
    static let placeholder = URL(string: "https://venera.invalid/")!

    static func make(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed) { return url }
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }
}

/// 以特殊前綴把「分類」編碼成搜尋字串，讓標籤點擊可以沿用同一條導覽路徑。
enum VeneraQuery {
    static let noChapter = "__none__"
    private static let prefix = "\u{1}category\u{1}"

    static func category(_ name: String, _ param: String?) -> String {
        prefix + name + "\u{1}" + (param ?? "")
    }

    private static let rankPrefix = "\u{1}rank\u{1}"

    static func rank(_ option: String) -> String { rankPrefix + option }

    static func decodeRank(_ query: String) -> String? {
        query.hasPrefix(rankPrefix) ? String(query.dropFirst(rankPrefix.count)) : nil
    }

    static func decodeCategory(_ query: String) -> (String, String?)? {
        guard query.hasPrefix(prefix) else { return nil }
        let rest = query.dropFirst(prefix.count).split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = rest.first else { return nil }
        let param = rest.count > 1 ? String(rest[1]) : ""
        return (String(name), param.isEmpty ? nil : param)
    }
}
