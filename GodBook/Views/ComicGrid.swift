import SwiftUI

/// 卡片上的「已收藏 / 已讀」狀態
private struct TileStatus: View {
    let comic: ComicSummary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if settings.showTileStatus {
            HStack(spacing: 4) {
                if favorites.isFavorite(comic) {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
                if library.progress(for: comic) != nil {
                    Image(systemName: "eye.fill").foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .glassCapsule()
            .opacity(favorites.isFavorite(comic) || library.progress(for: comic) != nil ? 1 : 0)
        }
    }
}

struct ComicCard: View {
    let comic: ComicSummary
    var showSourceBadge = false

    var body: some View {
        RemoteImageView(spec: comic.coverURL.map { ImageSpec(url: $0, source: comic.source) },
                        fill: true, placeholderAspect: 0.72)
            .frame(maxWidth: .infinity)
            .aspectRatio(0.72, contentMode: .fit)
            .clipped()
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comic.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = comic.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassCard(cornerRadius: 16)
                .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if showSourceBadge {
                    Text(comic.source.title)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassCapsule()
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) { TileStatus(comic: comic).padding(8) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 簡潔模式：封面 + 標題
struct BriefTile: View {
    let comic: ComicSummary
    var showSourceBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImageView(spec: comic.coverURL.map { ImageSpec(url: $0, source: comic.source) },
                            fill: true, placeholderAspect: 0.72)
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .clipped()
                .overlay(alignment: .topTrailing) { TileStatus(comic: comic).padding(6) }
                .overlay(alignment: .topLeading) {
                    if showSourceBadge {
                        Text(comic.source.title).font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4).glassCapsule().padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(comic.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}

/// 詳細模式：封面 + 標題 / 副標題 / 標籤
struct DetailedRow: View {
    let comic: ComicSummary
    var showSourceBadge = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImageView(spec: comic.coverURL.map { ImageSpec(url: $0, source: comic.source) },
                            fill: true, placeholderAspect: 0.72)
                .frame(width: 76, height: 106)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let subtitle = comic.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let tags = comic.tags, !tags.isEmpty {
                    Text(tags.prefix(5).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if showSourceBadge { Text(comic.source.title).font(.caption2.weight(.bold)) }
                    TileStatus(comic: comic)
                }
            }
            .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassCard(cornerRadius: 20, interactive: true)
        .contentShape(Rectangle())
    }
}

/// 依「列表顯示模式」設定選擇卡片樣式
struct ComicTile: View {
    let comic: ComicSummary
    var showSourceBadge = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch settings.listDisplay {
        case "brief": BriefTile(comic: comic, showSourceBadge: showSourceBadge)
        case "detailed": DetailedRow(comic: comic, showSourceBadge: showSourceBadge)
        default: ComicCard(comic: comic, showSourceBadge: showSourceBadge)
        }
    }
}

struct ComicGrid: View {
    let items: [ComicSummary]
    var showSourceBadge = false
    var onAppearItem: ((ComicSummary) -> Void)?
    @EnvironmentObject private var settings: AppSettings

    private var columns: [GridItem] {
        if settings.listDisplay == "detailed" { return [GridItem(.flexible())] }
        let base = 150 * min(max(settings.listScale, 0.6), 1.5)
        return [GridItem(.adaptive(minimum: base, maximum: base * 1.5), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { comic in
                NavigationLink(value: comic) {
                    ComicTile(comic: comic, showSourceBadge: showSourceBadge)
                }
                .buttonStyle(.plain)
                .onAppear { onAppearItem?(comic) }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// 帶分頁狀態的清單內容（載入中 / 錯誤 / 空結果 / 分頁列）。
struct PagedComicList: View {
    @ObservedObject var model: PagedListModel
    @State private var jumping = false
    @State private var jumpText = ""

    var body: some View {
        VStack(spacing: 16) {
            ComicGrid(items: model.items) { model.loadMoreIfNeeded(current: $0) }

            if model.isLoading {
                ProgressView().padding()
            } else if let message = model.errorMessage {
                VStack(spacing: 10) {
                    Text(message).font(.footnote).multilineTextAlignment(.center)
                    GlassButton(title: L("重試"), systemImage: "arrow.clockwise") { model.retry() }
                        .frame(maxWidth: 200)
                }
                .padding()
                .glassCard()
                .padding(.horizontal)
            } else if model.didLoadOnce && model.items.isEmpty {
                Text(L("沒有結果")).foregroundStyle(.secondary).padding()
            }

            if model.pagingMode && model.didLoadOnce { pager }
        }
        .padding(.vertical, 8)
    }

    private var pager: some View {
        HStack(spacing: 14) {
            Button { model.previousPageAction() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
                .disabled(model.currentPage <= 1 || model.isLoading)
            Button {
                jumpText = ""
                jumping = true
            } label: {
                Text(model.totalPages.map { L("第 %@ / %@ 頁", "\(model.currentPage)", "\($0)") } ?? L("第 %@ 頁", "\(model.currentPage)"))
                    .font(.footnote.weight(.semibold).monospacedDigit())
            }
            Button { model.nextPageAction() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                .disabled(!model.hasMore || model.isLoading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .glassCapsule(interactive: true)
        .alert(L("跳到第幾頁"), isPresented: $jumping) {
            TextField(L("頁碼"), text: $jumpText).keyboardType(.numberPad)
            Button(L("前往")) {
                if let page = Int(jumpText), page >= 1 { model.goTo(min(page, model.totalPages ?? page)) }
            }
            Button(L("取消"), role: .cancel) {}
        }
    }
}

struct SearchResultsView: View {
    let route: SearchRoute
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = PagedListModel()
    @State private var filters: [String: String] = [:]
    @State private var showFilters = false

    private var source: ComicSource { SourceRegistry.source(route.source) }
    private var groups: [FilterGroup] { source.filterGroups(query: route.query) }

    private struct LoadKey: Hashable {
        var filters: [String: String]
        var paging: Bool
    }

    @State private var startedKey: LoadKey?

    private var loadKey: LoadKey { LoadKey(filters: filters, paging: settings.listPaging) }

    var body: some View {
        ScrollView {
            PagedComicList(model: model)
        }
        .themedScreen()
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .sheet(isPresented: $showFilters) { FilterSheet(groups: groups, values: $filters) }
        .task(id: loadKey) {
            // 從詳情頁返回時 .task 會再執行一次；條件沒變就不要重新載入（否則清單會被清空、回到最上面）
            guard loadKey != startedKey else { return }
            startedKey = loadKey
            let source = self.source
            let sort = source.sortOptions[0]
            let query = route.query
            let filters = self.filters
            await model.start(paging: settings.listPaging) { try await source.browse(query: query, page: $0, sort: sort, filters: filters) }
        }
    }
}
