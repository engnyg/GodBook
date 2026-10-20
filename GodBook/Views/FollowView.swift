import SwiftUI

struct FollowView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var follow: FollowStore
    @ObservedObject private var safe = AppSettings.shared

    private var folder: FavoriteFolder? { favorites.folders.first { $0.id == follow.followedFolderID } }

    private var items: [FavoriteItem] {
        guard let folder else { return [] }
        return folder.items.filter { !SafeMode.hides($0.summary) }.sorted { a, b in
            let ua = follow.infos[a.id]?.hasUpdate == true, ub = follow.infos[b.id]?.hasUpdate == true
            if ua != ub { return ua }
            return (follow.infos[a.id]?.checkedAt ?? .distantPast) > (follow.infos[b.id]?.checkedAt ?? .distantPast)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            GlassPanel(title: L("追蹤更新")) {
                Picker(L("追蹤的資料夾"), selection: Binding(
                    get: { follow.followedFolderID },
                    set: { follow.followedFolderID = $0 })) {
                    Text(L("不追蹤")).tag(UUID?.none)
                    ForEach(favorites.folders) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)

                if folder != nil {
                    GlassButton(title: follow.isChecking ? L("檢查中 %@/%@", "\(follow.progress.done)", "\(follow.progress.total)") : L("立即檢查更新"),
                                systemImage: "arrow.triangle.2.circlepath", prominent: true) {
                        Task { await follow.check(favorites: favorites) }
                    }
                    .disabled(follow.isChecking)
                    if let last = follow.lastCheck {
                        Text(L("上次檢查：%@", "\(last.formatted(date: .abbreviated, time: .shortened))"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(L("App 開啟時，距離上次檢查超過 6 小時會自動檢查。第一次檢查只會記錄目前章節數，之後有新章節才會標示。"))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(L("在「收藏」分頁選一個資料夾右上角選單 → 追蹤這個資料夾的更新。")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)

            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    let info = follow.infos[item.id]
                    NavigationLink(value: item.summary) {
                        HStack(spacing: 12) {
                            RemoteImageView(spec: item.summary.coverURL.map { ImageSpec(url: $0, source: item.summary.source) }, fill: true)
                                .frame(width: 56, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.summary.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    if info?.hasUpdate == true {
                                        Text(L("新")).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.red, in: Capsule()).foregroundStyle(.white)
                                    }
                                }
                                Text(info.map { L("最新：%@（共 %@ 章）", "\($0.latestTitle.isEmpty ? "—" : $0.latestTitle)", "\($0.chapterCount)") } ?? L("尚未檢查"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .glassCard(cornerRadius: 20, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }
}
