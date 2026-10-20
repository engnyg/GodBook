import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var venera: VeneraStore
    @StateObject private var model = PagedListModel()
    @State private var searchText = ""
    @State private var query = ""
    @State private var sortIds: [SourceKind: String] = [:]
    @State private var filterValues: [SourceKind: [String: String]] = [:]
    @State private var directOpen: ComicSummary?
    @State private var showFilters = false
    @State private var showCategories = false
    @State private var aggregatedQuery: AggregatedRoute?
    @State private var tagSuggestions: [TagSuggestionRow] = []
    @ObservedObject private var deepLink = DeepLink.shared

    struct AggregatedRoute: Hashable, Identifiable {
        let query: String
        var id: String { query }
    }

    struct TagSuggestionRow: Identifiable, Hashable {
        let id: String
        let label: String
        let completion: String
    }

    private var source: ComicSource { SourceRegistry.source(settings.lastSource) }

    private var currentSort: SortOption {
        let options = source.sortOptions
        return options.first { $0.id == sortIds[settings.lastSource] } ?? options[0]
    }

    private var currentFilters: [String: String] { filterValues[settings.lastSource] ?? [:] }

    private var groups: [FilterGroup] { source.filterGroups(query: query) }

    /// 只有「目前這個 venera 漫畫源」載入完成時才需要重新抓取；
    /// 其他漫畫源啟動時陸續載入不應觸發重新請求（否則 nhentai 會因請求過多回 429）。
    private var catalogState: Int {
        settings.lastSource.isVenera
            ? (VeneraRegistry.shared.info(settings.lastSource.veneraKey) == nil ? 0 : 1)
            : 0
    }

    private struct LoadKey: Hashable {
        var source: SourceKind
        var query: String
        var sort: String
        var catalog: Int
        var filters: [String: String]
        var paging: Bool
        var blocked: [String]
        var safe: Bool
    }

    var body: some View {
        ScrollView {
            if settings.enabledSources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.slash").font(.largeTitle)
                    Text(L("沒有啟用的來源"))
                    Text(L("到「設定 → 來源管理」開啟至少一個來源")).font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                PagedComicList(model: model)
            }
        }
        .themedScreen()
        .safeAreaInset(edge: .top, spacing: 0) {
            sourceChips
        }
        .navigationTitle("GodBook")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: settings.lastSource == .nhentai ? L("搜尋標籤、關鍵字或 ID") : L("搜尋關鍵字")) {
            suggestionContent
        }
        .onSubmit(of: .search) { submitSearch() }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty && !query.isEmpty { query = "" }
        }
        .task(id: "\(searchText)|\(settings.lastSource.rawValue)") { await updateTagSuggestions() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !groups.isEmpty {
                    Button { showFilters = true } label: {
                        Image(systemName: currentFilters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                if !source.categorySections().isEmpty {
                    Button { showCategories = true } label: { Image(systemName: "square.grid.3x3") }
                }
                Menu {
                    Button { aggregatedQuery = AggregatedRoute(query: searchText.trimmingCharacters(in: .whitespaces)) } label: {
                        Label(L("聚合搜尋（多個來源）"), systemImage: "magnifyingglass.circle")
                    }
                    Button { openFromClipboard() } label: { Label(L("從剪貼簿開啟連結"), systemImage: "doc.on.clipboard") }
                    Button { Task { _ = await SafeMode.set(!settings.safeMode) } } label: {
                        Label(settings.safeMode ? L("關閉安全模式") : L("開啟安全模式"), systemImage: "shield.lefthalf.filled")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                if source.sortOptions.count > 1 {
                    SortMenu(options: source.sortOptions, selection: currentSort.id) {
                        sortIds[settings.lastSource] = $0
                    }
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(groups: groups, values: Binding(
                get: { filterValues[settings.lastSource] ?? [:] },
                set: { filterValues[settings.lastSource] = $0 }))
        }
        .navigationDestination(isPresented: $showCategories) { CategoriesView(source: settings.lastSource) }
        .navigationDestination(item: $aggregatedQuery) { AggregatedSearchView(query: $0.query) }
        .navigationDestination(item: $directOpen) { DetailView(summary: $0) }
        .onChange(of: deepLink.summary) { _, value in
            guard let value else { return }
            directOpen = value
            deepLink.summary = nil
        }
        .task(id: LoadKey(source: settings.lastSource, query: query, sort: currentSort.id, catalog: catalogState,
                          filters: currentFilters, paging: settings.listPaging, blocked: settings.blockedWords, safe: settings.safeMode)) {
            // 目前來源被停用時不送出請求，改切到第一個啟用的來源
            guard settings.isEnabled(settings.lastSource) else {
                if let first = settings.enabledSources.first { settings.lastSource = first }
                return
            }
            let source = self.source
            let sort = currentSort
            let query = self.query
            let filters = currentFilters
            await model.start(paging: settings.listPaging) { try await source.browse(query: query, page: $0, sort: sort, filters: filters) }
        }
    }

    // MARK: 來源切換列

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(settings.enabledSources) { kind in
                    let selected = kind == settings.lastSource
                    Button {
                        withAnimation(.snappy) { settings.lastSource = kind }
                    } label: {
                        Text(kind.title)
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(tint: selected ? nil : Color.clear, interactive: true)
                    .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .id(venera.sources.count * 1000 + settings.disabledSources.count + settings.sourceOrder.count) // 安裝 / 移除 / 停用 / 排序後重新整理
    }

    // MARK: 搜尋

    @ViewBuilder
    private var suggestionContent: some View {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if settings.safeMode {
            EmptyView()
        } else if text.isEmpty {
            ForEach(settings.searchHistory.prefix(8), id: \.self) { item in
                Label(item, systemImage: "clock.arrow.circlepath").searchCompletion(item)
            }
        } else {
            ForEach(tagSuggestions) { row in
                Label(row.label, systemImage: "tag").searchCompletion(row.completion)
            }
            ForEach(settings.searchHistory.filter { $0.localizedCaseInsensitiveContains(text) && $0 != text }.prefix(4), id: \.self) { item in
                Label(item, systemImage: "clock.arrow.circlepath").searchCompletion(item)
            }
        }
    }

    private func updateTagSuggestions() async {
        guard source.supportsTagSuggestions else { tagSuggestions = []; return }
        let tokens = searchText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let last = tokens.last, last.count >= 1, !last.contains(":") else { tagSuggestions = []; return }
        try? await Task.sleep(nanoseconds: 150_000_000) // 輸入防抖
        guard !Task.isCancelled else { return }

        let prefix = tokens.dropLast().joined(separator: " ")
        let matches = TagTranslator.shared.search(last)
        let kind = settings.lastSource
        var rows: [TagSuggestionRow] = []
        for match in matches {
            let insertion: String
            if kind.isVenera {
                insertion = await (source as? VeneraSource)?.tagSuggestionText(namespace: match.namespace, tag: match.name)
                    ?? "\(match.namespace):\(match.name)"
            } else {
                let type = ["female", "male", "mixed", "other"].contains(match.namespace) ? "tag" : match.namespace
                insertion = "\(type):\"\(match.name)\""
            }
            let completion = prefix.isEmpty ? insertion : "\(prefix) \(insertion)"
            rows.append(TagSuggestionRow(id: match.id, label: "\(match.translation)（\(match.name)）", completion: completion))
        }
        guard !Task.isCancelled else { return }
        tagSuggestions = rows
    }

    private func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        remember(text)
        // 貼上的是漫畫連結（或車號）時直接開啟
        if LinkResolver.looksLikeLink(text) || text.lowercased().hasPrefix("jm") {
            Task {
                if let found = await LinkResolver.resolve(text) { directOpen = found } else { query = text }
            }
            return
        }
        if settings.defaultSearchTarget == "aggregated" {
            aggregatedQuery = AggregatedRoute(query: text)
            return
        }
        // nhentai 的純數字視為 gallery ID，直接開啟
        if settings.lastSource == .nhentai, text.allSatisfy(\.isNumber) {
            directOpen = ComicSummary(source: .nhentai, sid: text, title: "#\(text)")
            return
        }
        query = text
    }

    private func openFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            ToastCenter.shared.show(L("剪貼簿是空的"))
            return
        }
        Task {
            if let found = await LinkResolver.resolve(text) { directOpen = found }
            else { ToastCenter.shared.show(L("剪貼簿的內容不是可辨識的漫畫連結")) }
        }
    }

    private func remember(_ text: String) {
        var list = settings.searchHistory.filter { $0 != text }
        list.insert(text, at: 0)
        settings.searchHistory = Array(list.prefix(30))
    }
}
