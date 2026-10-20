import SwiftUI

/// 詳情頁的次要動作列：評論、讚、評分、雲端收藏、分享
struct DetailExtraBar: View {
    let detail: ComicDetail
    @State private var liked: Bool?
    @State private var showComments = false
    @State private var showRemote = false
    @State private var showRating = false
    @State private var busy = false

    private var source: ComicSource { SourceRegistry.source(detail.summary.source) }
    private var caps: SourceCapabilities { source.capabilities }

    var body: some View {
        let bar = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if caps.comments { chip(L("評論"), "text.bubble") { showComments = true } }
                if caps.likeComic { chip(liked == true ? L("已讚") : L("讚"), liked == true ? "heart.fill" : "heart") { Task { await toggleLike() } } }
                if caps.rating { chip(L("評分"), "star") { showRating = true } }
                if caps.remoteFavorites { chip(L("雲端收藏"), "icloud") { showRemote = true } }
                shareChip
            }
        }
        bar
            .onAppear { if liked == nil { liked = detail.isLiked } }
            .sheet(isPresented: $showComments) {
                CommentsSheet(kind: detail.summary.source,
                              context: CommentContext(summary: detail.summary, subId: detail.subId, chapterId: nil))
            }
            .sheet(isPresented: $showRemote) { RemoteFavoriteSheet(summary: detail.summary) }
            .confirmationDialog(L("給這部作品幾顆星？"), isPresented: $showRating, titleVisibility: .visible) {
                ForEach(1...5, id: \.self) { stars in
                    Button(String(repeating: "★", count: stars)) { Task { await rate(stars) } }
                }
            }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
        .disabled(busy)
    }

    @ViewBuilder
    private var shareChip: some View {
        if let text = detail.url, let url = URL(string: text) {
            ShareLink(item: url, subject: Text(detail.summary.title)) {
                Label(L("分享"), systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain).glassCapsule(interactive: true)
        } else {
            ShareLink(item: "\(detail.summary.title)（\(detail.summary.source.title) \(detail.summary.sid)）") {
                Label(L("分享"), systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain).glassCapsule(interactive: true)
        }
    }

    private func toggleLike() async {
        busy = true
        defer { busy = false }
        let target = !(liked ?? false)
        do {
            try await source.setLiked(detail.summary, liked: target)
            liked = target
            ToastCenter.shared.show(target ? L("已按讚") : L("已取消讚"))
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }

    private func rate(_ stars: Int) async {
        busy = true
        defer { busy = false }
        do {
            try await source.rate(detail.summary, stars: stars * 2)
            ToastCenter.shared.show(L("已評 %@ 顆星", "\(stars)"))
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
}

/// 來源的雲端收藏（venera 資料夾 / 禁漫）加入或移除
struct RemoteFavoriteSheet: View {
    let summary: ComicSummary
    @Environment(\.dismiss) private var dismiss
    @State private var state: RemoteFavoriteState?
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var newName = ""
    @State private var creating = false
    @State private var busyFolder: String?

    private var source: ComicSource { SourceRegistry.source(summary.source) }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text(L("載入中…")) }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage).font(.footnote)
                        Text(L("若顯示需要登入，請到「設定 → 來源管理」登入該來源的帳號。")).font(.footnote).foregroundStyle(.secondary)
                        Button(L("重試")) { Task { await load() } }
                    }
                } else if let state {
                    ForEach(state.folders) { folder in
                        let included = state.favorited.contains(folder.id)
                        Button { Task { await toggle(folder, included) } } label: {
                            HStack {
                                Label(folder.name, systemImage: included ? "checkmark.circle.fill" : "circle")
                                Spacer()
                                if busyFolder == folder.id { ProgressView() }
                            }
                        }
                        .swipeActions {
                            if state.canManageFolders {
                                Button(L("刪除"), role: .destructive) { Task { await deleteFolder(folder) } }
                            }
                        }
                    }
                    if state.canManageFolders {
                        Button { creating = true } label: { Label(L("新增資料夾"), systemImage: "folder.badge.plus") }
                    }
                }
            }
            .navigationTitle(L("雲端收藏"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
            .alert(L("新增資料夾"), isPresented: $creating) {
                TextField(L("名稱"), text: $newName)
                Button(L("建立")) { Task { await addFolder() } }
                Button(L("取消"), role: .cancel) { newName = "" }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do { state = try await source.remoteFavorites(for: summary) }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }

    private func toggle(_ folder: RemoteFolder, _ included: Bool) async {
        busyFolder = folder.id
        defer { busyFolder = nil }
        do {
            try await source.setRemoteFavorite(summary, folderId: folder.id, adding: !included)
            if included { state?.favorited.remove(folder.id) } else { state?.favorited.insert(folder.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func addFolder() async {
        let name = newName
        newName = ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { try await source.addRemoteFolder(name); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteFolder(_ folder: RemoteFolder) async {
        do { try await source.deleteRemoteFolder(folder.id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}

/// 縮圖預覽列（點一下從該頁開始閱讀）
struct ThumbnailStrip: View {
    let detail: ComicDetail
    let onOpen: (Int) -> Void

    @State private var urls: [String] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loadedOnce = false

    private var source: ComicSource { SourceRegistry.source(detail.summary.source) }

    var body: some View {
        Group {
            if !urls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("預覽")).font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { index, string in
                                Button { onOpen(index) } label: {
                                    RemoteImageView(spec: ImageSpec(url: VeneraURL.make(string) ?? VeneraURL.placeholder,
                                                                    source: detail.summary.source, imageKey: string),
                                                    fill: true, placeholderAspect: 0.7)
                                        .frame(width: 92, height: 130)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            if next != nil {
                                Button { Task { await loadMore() } } label: {
                                    VStack { if loading { ProgressView() } else { Image(systemName: "ellipsis"); Text(L("更多")).font(.caption2) } }
                                        .frame(width: 60, height: 130)
                                }
                                .buttonStyle(.plain).glassCard(cornerRadius: 10)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            if let list = detail.thumbnails, !list.isEmpty { urls = list; return }
            if source.capabilities.thumbnails { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await source.loadThumbnails(detail.summary, next: next)
            urls.append(contentsOf: result.urls)
            next = result.next
        } catch { next = nil }
    }
}
