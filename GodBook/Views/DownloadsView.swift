import SwiftUI

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var safe = AppSettings.shared
    @ObservedObject private var cloud = CloudSync.shared
    @ObservedObject private var cloudSettings = CloudSettings.shared
    @State private var exporting: String?
    @State private var exported: ExportedFile?
    @State private var errorMessage: String?
    @State private var confirmDelete: ComicSummary?

    /// 本機下載與只在雲端的作品
    private var visibleComics: [ComicSummary] {
        var seen = Set<String>()
        return (downloads.comics + cloud.cloudComics).filter { seen.insert($0.id).inserted && !SafeMode.hides($0) }
    }

    var body: some View {
        Group {
            if visibleComics.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle)
                    Text(L("還沒有下載內容"))
                    Text(L("在作品詳情頁按「下載」即可離線閱讀"))
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visibleComics) { comic in row(comic) }
                }
                .padding(12)
            }
        }
        .sheet(item: $exported) { file in ShareSheet(urls: [file.url]) }
        .alert(L("操作失敗"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L("好")) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(L("刪除下載"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { comic in
            if !downloads.items(for: comic).isEmpty {
                Button(L("只刪除本機（保留雲端）")) { downloads.removeComic(comic) }
            }
            Button(L("連同雲端一起刪除"), role: .destructive) { deleteEverywhere(comic) }
        } message: { _ in
            Text(L("雲端上的檔案刪除後無法復原。"))
        }
    }

    private func row(_ comic: ComicSummary) -> some View {
        let items = downloads.items(for: comic)
        let finished = items.filter { $0.state == .finished }.count
        let done = items.reduce(0) { $0 + $1.done }
        let total = items.reduce(0) { $0 + $1.total }
        let active = items.contains { $0.state == .downloading || $0.state == .queued }
        let failed = items.first { $0.state == .failed }
        let status = cloud.status(for: comic)
        let localCover = FileManager.default.fileExists(atPath: DownloadStorage.coverFile(comic).path)
            ? DownloadStorage.coverFile(comic) : comic.coverURL

        return NavigationLink(value: comic) {
            HStack(spacing: 12) {
                RemoteImageView(spec: localCover.map { ImageSpec(url: $0, source: comic.source) }, fill: true)
                    .frame(width: 56, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(comic.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(items.isEmpty
                         ? L("%@ · 僅雲端（%@ 話）", "\(comic.source.title)", "\(status.uploaded)")
                         : L("%@ · %@/%@ 章完成", "\(comic.source.title)", "\(finished)", "\(items.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                    if status.uploaded > 0 || status.active {
                        cloudLine(status)
                    }
                    if active || total > done {
                        ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    }
                    if let failed, let error = failed.error {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    } else if let error = status.failed {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if exporting == comic.id || status.active {
                    ProgressView()
                } else if active {
                    Button { downloads.pauseAll(of: comic) } label: { Image(systemName: "pause.circle") }
                        .buttonStyle(.plain).font(.title2)
                } else if finished < items.count {
                    Button { downloads.resumeAll(of: comic) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.plain).font(.title2)
                }
            }
            .padding(10)
            .glassCard(cornerRadius: 20, interactive: true)
            .contextMenu { menu(comic, finished: finished, status: status) }
        }
        .buttonStyle(.plain)
    }

    private func cloudLine(_ status: CloudComicStatus) -> some View {
        var parts = [L("雲端 %@ 話", "\(status.uploaded)")]
        if status.cloudOnly > 0 { parts.append(L("%@ 話僅雲端", "\(status.cloudOnly)")) }
        if status.notUploaded > 0 { parts.append(L("%@ 話未上傳", "\(status.notUploaded)")) }
        return Label(parts.joined(separator: " · "), systemImage: status.active ? "arrow.triangle.2.circlepath.icloud" : "icloud")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menu(_ comic: ComicSummary, finished: Int, status: CloudComicStatus) -> some View {
        if finished > 0 {
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title) { export(comic, format) }
                }
            } label: { Label(L("匯出"), systemImage: "square.and.arrow.up") }
        }
        if cloud.target != nil, status.notUploaded > 0 {
            Button { cloud.enqueue(comic: comic) } label: {
                Label(L("上傳到雲端"), systemImage: "icloud.and.arrow.up")
            }
        }
        if status.localBackedUp > 0 {
            Button { cloud.offload(comic: comic) } label: {
                Label(L("釋放本機空間（保留雲端）"), systemImage: "externaldrive.badge.minus")
            }
        }
        if status.cloudOnly > 0 {
            Button { Task { await cloud.restoreLocal(comic) } } label: {
                Label(L("從雲端下載回本機"), systemImage: "icloud.and.arrow.down")
            }
        }
        if status.uploaded > 0 || status.notUploaded > 0 {
            Picker(selection: policyBinding(comic)) {
                Text(L("跟隨預設（%@）", cloudSettings.defaultPolicy.title)).tag("")
                ForEach(RetentionMode.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Label(L("本機保存策略"), systemImage: "slider.horizontal.3")
            }
            .pickerStyle(.menu)
        }
        if status.uploaded > 0 {
            Button(role: .destructive) { confirmDelete = comic } label: {
                Label(L("刪除下載…"), systemImage: "trash")
            }
        } else {
            Button(role: .destructive) { downloads.removeComic(comic) } label: {
                Label(L("刪除下載"), systemImage: "trash")
            }
        }
    }

    private func policyBinding(_ comic: ComicSummary) -> Binding<String> {
        Binding(
            get: { cloudSettings.override(for: comic.id)?.rawValue ?? "" },
            set: { value in
                cloudSettings.setOverride(RetentionMode(rawValue: value), for: comic.id)
                cloud.applyRetention(for: comic)
            })
    }

    private func deleteEverywhere(_ comic: ComicSummary) {
        Task {
            do {
                try await cloud.deleteFromCloud(comic)
                downloads.removeComic(comic)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(_ comic: ComicSummary, _ format: ExportFormat) {
        exporting = comic.id
        Task {
            do {
                let url = try await Task.detached { try ComicExport.export(comic, as: format) }.value
                exported = ExportedFile(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            exporting = nil
        }
    }
}
