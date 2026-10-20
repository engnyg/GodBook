import SwiftUI

struct ReaderRoute: Identifiable {
    let id = UUID()
    let detail: ComicDetail
    let chapterIndex: Int
    let startPage: Int
}

struct DetailView: View {
    let summary: ComicSummary
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var prefsStore: ReaderPrefsStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var follow: FollowStore
    @State private var showFavoriteSheet = false
    @State private var reverseOrder = AppSettings.shared.reverseChapters
    @EnvironmentObject private var imageFavorites: ImageFavoritesStore
    @State private var detail: ComicDetail?
    @State private var isOffline = false
    @State private var errorMessage: String?
    @State private var reader: ReaderRoute?

    private var shown: ComicSummary { detail?.summary ?? summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let detail {
                    actions(detail)
                    DetailExtraBar(detail: detail)
                    if let text = detail.description, !text.isEmpty {
                        Text(text)
                            .font(.callout)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard()
                    }
                    if !detail.tags.isEmpty { tagSection(detail) }
                    ThumbnailStrip(detail: detail) { index in
                        reader = ReaderRoute(detail: detail, chapterIndex: detail.firstReadIndex, startPage: index)
                    }
                    if detail.chapters.count > 1 { chapterSection(detail) }
                    if !detail.related.isEmpty { relatedSection(detail) }
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Text(errorMessage).multilineTextAlignment(.center)
                        GlassButton(title: L("重試"), systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                    .padding()
                    .glassCard()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(shown.source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFavoriteSheet = true
                } label: {
                    Image(systemName: favorites.isFavorite(shown) ? "heart.fill" : "heart")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showFavoriteSheet) { FavoriteToggleSheet(summary: shown) }
        .fullScreenCover(item: $reader) { route in
            ReaderView(route: route, onClose: { reader = nil })
                .environmentObject(library)
                .environmentObject(theme)
                .environmentObject(settings)
                .environmentObject(prefsStore)
                .environmentObject(imageFavorites)
        }
    }

    // MARK: 區塊

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImageView(spec: shown.coverURL.map { ImageSpec(url: $0, source: shown.source) }, fill: true)
                .frame(width: 118, height: 164)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.title).font(.headline).textSelection(.enabled)
                if let detail {
                    if !detail.authors.isEmpty {
                        Text(detail.authors.joined(separator: "、")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !detail.stats.isEmpty {
                        Text(detail.stats.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let count = detail.pageCount {
                        Text(L("%@ 頁", "\(count)")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard(cornerRadius: 26)
    }

    private func actions(_ detail: ComicDetail) -> some View {
        let progress = library.progress(for: shown)
        let resumeIndex = progress.flatMap { entry in detail.chapters.firstIndex { $0.id == entry.chapterId } }
        return VStack(spacing: 12) {
            readButtons(detail, progress: progress, resumeIndex: resumeIndex)
            if !shown.source.isLocal { downloadAllButton(detail) }
            if isOffline {
                Label(L("離線模式：顯示已下載的內容"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func readButtons(_ detail: ComicDetail, progress: HistoryEntry?, resumeIndex: Int?) -> some View {
        HStack(spacing: 12) {
            if let progress, let resumeIndex {
                GlassButton(title: L("繼續 %@ 頁", "\(progress.pageIndex + 1)"), systemImage: "play.fill", prominent: true) {
                    reader = ReaderRoute(detail: detail, chapterIndex: resumeIndex, startPage: progress.pageIndex)
                }
                GlassButton(title: L("從頭"), systemImage: "backward.end.fill") {
                    reader = ReaderRoute(detail: detail, chapterIndex: detail.firstReadIndex, startPage: 0)
                }
            } else {
                GlassButton(title: L("開始閱讀"), systemImage: "book.fill", prominent: true) {
                    reader = ReaderRoute(detail: detail, chapterIndex: detail.firstReadIndex, startPage: 0)
                }
            }
        }
    }

    private func downloadAllButton(_ detail: ComicDetail) -> some View {
        let states = detail.chapters.map { downloads.item(detail.summary, $0) }
        let finished = states.filter { $0?.state == .finished }.count
        let active = states.compactMap { $0 }.filter { $0.state == .downloading || $0.state == .queued }
        return Group {
            if finished == detail.chapters.count {
                GlassButton(title: L("已下載（點此刪除）"), systemImage: "checkmark.circle.fill") {
                    downloads.removeComic(detail.summary)
                }
            } else if !active.isEmpty {
                let done = states.compactMap { $0 }.reduce(0) { $0 + $1.done }
                let total = states.compactMap { $0 }.reduce(0) { $0 + $1.total }
                GlassButton(title: total > 0 ? L("下載中 %@/%@（點此暫停）", "\(done)", "\(total)") : L("等待下載…"), systemImage: "arrow.down.circle.dotted") {
                    downloads.pauseAll(of: detail.summary)
                }
            } else if states.contains(where: { $0?.state == .paused || $0?.state == .failed }) {
                GlassButton(title: L("繼續下載"), systemImage: "arrow.down.circle") {
                    downloads.resumeAll(of: detail.summary)
                    downloads.enqueue(detail: detail, chapters: detail.chapters)
                }
            } else {
                GlassButton(title: detail.chapters.count > 1 ? L("下載全部章節") : L("下載"), systemImage: "arrow.down.circle") {
                    downloads.enqueue(detail: detail, chapters: detail.chapters)
                }
            }
        }
        .disabled(isOffline && finished != detail.chapters.count)
    }

    @ViewBuilder
    private func downloadAccessory(_ detail: ComicDetail, _ chapter: Chapter) -> some View {
        let item = downloads.item(detail.summary, chapter)
        switch item?.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            Button { downloads.pause(item!.id) } label: {
                ProgressView(value: item!.progress).progressViewStyle(.circular).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        case .queued:
            Button { downloads.pause(item!.id) } label: { Image(systemName: "clock") }
                .buttonStyle(.plain)
        case .paused, .failed:
            Button { downloads.resume(item!.id) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.plain)
        case nil:
            Button { downloads.enqueue(detail: detail, chapters: [chapter]) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(isOffline)
        }
    }

    private func tagSection(_ detail: ComicDetail) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(detail.tags) { tag in
                if let query = tag.query {
                    NavigationLink(value: SearchRoute(source: shown.source, query: query, title: tag.name)) {
                        tagLabel(tag)
                    }
                    .buttonStyle(.plain)
                } else {
                    tagLabel(tag)
                }
            }
        }
    }

    private func tagLabel(_ tag: ComicTag) -> some View {
        let translate = settings.translateTags && shown.source == .nhentai
        let title = translate ? TagTranslator.shared.translate(tag.name, group: tag.group) : tag.name
        return HStack(spacing: 4) {
            if let group = tag.group, group != "tag" {
                Text(translate ? TagTranslator.shared.groupTitle(group) : group).foregroundStyle(.secondary)
            }
            Text(title)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule(interactive: true)
    }

    private func chapterSection(_ detail: ComicDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("章節（%@）", "\(detail.chapters.count)")).font(.headline)
                Spacer()
                Button { withAnimation { reverseOrder.toggle() } } label: {
                    Label(reverseOrder ? L("倒序") : L("正序"), systemImage: "arrow.up.arrow.down").font(.caption)
                }
            }
            LazyVStack(spacing: 8) {
                let entries = Array(detail.chapters.enumerated())
                ForEach(reverseOrder ? Array(entries.reversed()) : entries, id: \.element.id) { index, chapter in
                    HStack(spacing: 12) {
                        Button {
                            reader = ReaderRoute(detail: detail, chapterIndex: index, startPage: 0)
                        } label: {
                            HStack {
                                Text(chapter.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        downloadAccessory(detail, chapter).font(.title3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .glassCard(cornerRadius: 16, interactive: true)
                }
            }
        }
    }

    private func relatedSection(_ detail: ComicDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("相關作品")).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(detail.related) { item in
                        NavigationLink(value: item) {
                            ComicCard(comic: item).frame(width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            let loaded = try await SourceRegistry.source(summary.source).detail(of: summary)
            detail = loaded
            isOffline = false
            follow.markRead(summary, chapterCount: loaded.chapters.count, latestTitle: loaded.chapters.last?.title ?? "")
            // 已下載過的作品，順手更新本機詳情快取
            if !downloads.items(for: summary).isEmpty { DownloadStorage.saveDetail(loaded) }
        } catch {
            if let cached = DownloadStorage.loadDetail(summary) {
                detail = cached
                isOffline = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
