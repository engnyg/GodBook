import SwiftUI

/// 評論面板（漫畫評論 / 章節評論）。回覆會往下一層頁面顯示。
struct CommentsSheet: View {
    let kind: SourceKind
    let context: CommentContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CommentThreadView(kind: kind, context: context, parent: nil)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("關閉")) { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct CommentThreadView: View {
    let kind: SourceKind
    let context: CommentContext
    let parent: ComicComment?

    @State private var comments: [ComicComment] = []
    @State private var page = 1
    @State private var maxPage: Int?
    @State private var loading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var notice: String?

    private var source: ComicSource { SourceRegistry.source(kind) }
    private var caps: SourceCapabilities { source.capabilities }
    private var canSend: Bool { context.chapterId == nil ? caps.sendComments : caps.sendChapterComments }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let parent {
                        CommentRow(kind: kind, context: context, comment: parent, isRoot: true)
                        Divider()
                    }
                    if !didLoad && loading {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(comments) { comment in
                        CommentRow(kind: kind, context: context, comment: comment, isRoot: false)
                    }
                    if didLoad && comments.isEmpty && errorMessage == nil {
                        Text(L("還沒有評論")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                    if let errorMessage {
                        VStack(spacing: 8) {
                            Text(errorMessage).font(.footnote).multilineTextAlignment(.center)
                            GlassButton(title: L("重試"), systemImage: "arrow.clockwise") { Task { await load(reset: false) } }
                                .frame(maxWidth: 200)
                        }
                        .frame(maxWidth: .infinity).padding()
                    }
                    if hasMore && !loading {
                        Button(L("載入更多")) { Task { await load(reset: false) } }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    } else if loading && didLoad {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(16)
            }
            if canSend { composer }
        }
        .themedScreen()
        .navigationTitle(parent == nil ? (context.chapterId == nil ? L("評論") : L("章節評論")) : L("回覆"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let notice {
                Text(notice).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8).glassCapsule().padding(.top, 8)
            }
        }
        .task { if !didLoad { await load(reset: true) } }
    }

    private var hasMore: Bool {
        guard didLoad, errorMessage == nil, !comments.isEmpty else { return false }
        if parent?.replies.isEmpty == false { return false } // 回覆已內嵌，不需分頁
        if let maxPage { return page <= maxPage }
        return true
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(parent == nil ? L("寫下評論…") : L("回覆 %@…", "\(parent?.userName ?? "")"), text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassCard(cornerRadius: 20)
            Button { Task { await send() } } label: {
                Image(systemName: sending ? "hourglass" : "paperplane.fill")
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), tint: nil, interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: 載入 / 發送

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; didLoad = true }
        if reset { comments = []; page = 1; maxPage = nil }

        if let parent, !parent.replies.isEmpty {
            comments = parent.replies.filter { !Blocklist.blocksComment($0.content) }
            return
        }
        do {
            let result = try await source.loadComments(context, page: page, replyTo: parent?.id)
            let fresh = result.comments.filter { !Blocklist.blocksComment($0.content) }
            let known = Set(comments.map(\.id))
            comments.append(contentsOf: fresh.filter { !known.contains($0.id) })
            maxPage = result.maxPage
            page += 1
            if result.comments.isEmpty { maxPage = page - 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await source.sendComment(context, content: text, replyTo: parent?.id)
            draft = ""
            show(L("已送出"))
            await load(reset: true)
        } catch {
            show(L("發送失敗：%@", "\(error.localizedDescription)"))
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { notice = nil } }
    }
}

struct CommentRow: View {
    let kind: SourceKind
    let context: CommentContext
    @State var comment: ComicComment
    let isRoot: Bool
    @State private var busy = false

    private var source: ComicSource { SourceRegistry.source(kind) }

    var body: some View {
        let parsed = RichComment.parse(comment.content)
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.userName).font(.subheadline.weight(.semibold))
                    if let time = comment.time { Text(time).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(parsed.text).font(.callout).textSelection(.enabled)
                ForEach(parsed.images, id: \.self) { url in
                    RemoteImageView(spec: ImageSpec(url: url, source: kind, imageKey: url.absoluteString), placeholderAspect: 1.4)
                        .frame(maxWidth: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = comment.avatar {
            RemoteImageView(spec: ImageSpec(url: url, source: kind, imageKey: url.absoluteString), fill: true, placeholderAspect: 1)
                .frame(width: 36, height: 36).clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            if !isRoot, (comment.replyCount ?? 0) > 0 || !comment.replies.isEmpty {
                NavigationLink {
                    CommentThreadView(kind: kind, context: context, parent: comment)
                } label: {
                    Label(L("%@ 則回覆", "\(comment.replyCount ?? comment.replies.count)"), systemImage: "bubble.left.and.bubble.right").font(.caption)
                }
            } else if !isRoot, source.capabilities.sendComments, !comment.id.isEmpty {
                NavigationLink {
                    CommentThreadView(kind: kind, context: context, parent: comment)
                } label: {
                    Label(L("回覆"), systemImage: "arrowshape.turn.up.left").font(.caption)
                }
            }
            if source.capabilities.likeComment, !comment.id.isEmpty {
                Button { Task { await toggleLike() } } label: {
                    Label(comment.score.map(String.init) ?? L("讚"), systemImage: comment.isLiked == true ? "heart.fill" : "heart").font(.caption)
                }
            }
            if source.capabilities.voteComment, !comment.id.isEmpty {
                Button { Task { await vote(up: true) } } label: {
                    Image(systemName: comment.voteStatus == 1 ? "hand.thumbsup.fill" : "hand.thumbsup").font(.caption)
                }
                if let score = comment.score { Text("\(score)").font(.caption.monospacedDigit()) }
                Button { Task { await vote(up: false) } } label: {
                    Image(systemName: comment.voteStatus == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.caption)
                }
            } else if let score = comment.score, !source.capabilities.likeComment {
                Label("\(score)", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(busy)
    }

    private func toggleLike() async {
        busy = true
        defer { busy = false }
        let target = !(comment.isLiked ?? false)
        do {
            try await source.likeComment(context, commentId: comment.id, like: target)
            comment.isLiked = target
            if let score = comment.score { comment.score = score + (target ? 1 : -1) }
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }

    private func vote(up: Bool) async {
        busy = true
        defer { busy = false }
        let current = comment.voteStatus ?? 0
        let cancel = (up && current == 1) || (!up && current == -1)
        do {
            let score = try await source.voteComment(context, commentId: comment.id, up: up, cancel: cancel)
            comment.score = score
            comment.voteStatus = cancel ? 0 : (up ? 1 : -1)
        } catch { ToastCenter.shared.show(error.localizedDescription) }
    }
}
