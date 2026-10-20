import SwiftUI

/// 圖片收藏牆
struct ImageFavoritesView: View {
    @EnvironmentObject private var store: ImageFavoritesStore
    @ObservedObject private var safe = AppSettings.shared
    @State private var selected: ImageFavorite?

    private var visibleItems: [ImageFavorite] { store.items.filter { !SafeMode.hides($0.summary) } }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        Group {
            if visibleItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle").font(.largeTitle)
                    Text(L("還沒有收藏的圖片"))
                    Text(L("閱讀時點右上角「…」→「收藏這張圖」，或在閱讀設定開啟雙擊收藏"))
                        .font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(visibleItems) { item in
                        Button { selected = item } label: {
                            RemoteImageView(spec: ImageSpec(url: store.fileURL(item), source: item.summary.source), fill: true, placeholderAspect: 0.75)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(0.75, contentMode: .fit)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .fullScreenCover(item: $selected) { item in
            ImageFavoriteViewer(item: item)
        }
    }
}

struct ImageFavoriteViewer: View {
    let item: ImageFavorite
    @EnvironmentObject private var store: ImageFavoritesStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var prefsStore: ReaderPrefsStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var shareImage: ShareImageItem?
    @State private var route: ReaderRoute?
    @State private var message: String?
    @State private var loadingReader = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImage(spec: ImageSpec(url: store.fileURL(item), source: item.summary.source))
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                circle("xmark") { dismiss() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.summary.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(L("%@ · 第 %@ 頁", "\(item.chapterTitle)", "\(item.pageIndex + 1)")).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8).glassCapsule()
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 14) {
                circle("square.and.arrow.up") {
                    if let image = UIImage(contentsOfFile: store.fileURL(item).path) { shareImage = ShareImageItem(image: image) }
                }
                circle("square.and.arrow.down") {
                    if let image = UIImage(contentsOfFile: store.fileURL(item).path) {
                        Task { message = PhotoSaver.resultMessage(await PhotoSaver.save(image)) }
                    }
                }
                circle(loadingReader ? "hourglass" : "book") { Task { await openReader() } }
                circle("trash") { store.remove(item); dismiss() }
            }
            .padding(.bottom, 12)
            .foregroundStyle(.white)
        }
        .overlay {
            if let message {
                Text(message).font(.footnote.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10).glassCapsule()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $shareImage) { ShareItemsSheet(items: [$0.image]) }
        .fullScreenCover(item: $route) { route in
            ReaderView(route: route, onClose: { self.route = nil })
                .environmentObject(library).environmentObject(prefsStore).environmentObject(store)
                .environmentObject(theme).environmentObject(settings)
        }
    }

    private func circle(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.headline).frame(width: 48, height: 48)
                .glass(in: Circle(), interactive: true).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 回到這張圖在漫畫中的位置繼續閱讀
    private func openReader() async {
        loadingReader = true
        defer { loadingReader = false }
        let summary = item.summary
        let detail: ComicDetail
        if let loaded = try? await SourceRegistry.source(summary.source).detail(of: summary) {
            detail = loaded
        } else if let cached = DownloadStorage.loadDetail(summary) {
            detail = cached
        } else {
            message = L("無法載入漫畫資料")
            return
        }
        let index = detail.chapters.firstIndex { $0.id == item.chapterId } ?? 0
        route = ReaderRoute(detail: detail, chapterIndex: index, startPage: item.pageIndex)
    }
}
