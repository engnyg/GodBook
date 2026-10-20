import SwiftUI

/// 資料夾挑選面板（移動 / 複製 / 加入收藏共用）
struct FolderPickerSheet: View {
    let title: String
    var excluding: UUID?
    let onPick: (UUID) -> Void
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(favorites.folders.filter { $0.id != excluding }) { folder in
                    Button {
                        onPick(folder.id)
                        dismiss()
                    } label: {
                        HStack { Label(folder.name, systemImage: "folder"); Spacer(); Text("\(folder.visibleItems.count)").foregroundStyle(.secondary) }
                    }
                }
                Button { creating = true } label: { Label(L("新增資料夾"), systemImage: "folder.badge.plus") }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("取消")) { dismiss() } } }
            .alert(L("新增資料夾"), isPresented: $creating) {
                TextField(L("名稱"), text: $newName)
                Button(L("建立")) {
                    let id = favorites.createFolder(newName)
                    newName = ""
                    onPick(id)
                    dismiss()
                }
                Button(L("取消"), role: .cancel) { newName = "" }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 在詳情頁決定一本漫畫要放進哪些收藏資料夾
struct FavoriteToggleSheet: View {
    let summary: ComicSummary
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(favorites.folders) { folder in
                    let included = favorites.folderIDs(containing: summary).contains(folder.id)
                    Button {
                        favorites.toggle(summary, in: folder.id)
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: included ? "checkmark.circle.fill" : "circle")
                            Spacer()
                            Text("\(folder.visibleItems.count)").foregroundStyle(.secondary)
                        }
                    }
                }
                Button { creating = true } label: { Label(L("新增資料夾"), systemImage: "folder.badge.plus") }
            }
            .navigationTitle(L("加入收藏"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
            .alert(L("新增資料夾"), isPresented: $creating) {
                TextField(L("名稱"), text: $newName)
                Button(L("建立並加入")) {
                    favorites.add(summary, to: favorites.createFolder(newName))
                    newName = ""
                }
                Button(L("取消"), role: .cancel) { newName = "" }
            }
        }
        .presentationDetents([.medium])
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var follow: FollowStore
    @ObservedObject private var safe = AppSettings.shared
    @State private var folderID: UUID?
    @State private var editing = false
    @State private var selection = Set<String>()
    @State private var tagFilter: String?
    @State private var pick: PickAction?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var tagEditing: FavoriteItem?
    @State private var tagText = ""

    private enum PickAction: Identifiable {
        case move, copy
        var id: Int { self == .move ? 0 : 1 }
    }

    private var currentID: UUID? {
        if let folderID, favorites.folders.contains(where: { $0.id == folderID }) { return folderID }
        return favorites.folders.first?.id
    }

    private var folder: FavoriteFolder? { favorites.folders.first { $0.id == currentID } }

    private var items: [FavoriteItem] {
        guard let id = currentID else { return [] }
        let sorted = favorites.sortedItems(id).filter { !SafeMode.hides($0.summary) }
        guard let tagFilter else { return sorted }
        return sorted.filter { $0.tags.contains(tagFilter) }
    }

    var body: some View {
        VStack(spacing: 8) {
            folderChips
            if let id = currentID, !favorites.allTags(in: id).isEmpty { tagChips(favorites.allTags(in: id)) }

            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart").font(.largeTitle)
                    Text(tagFilter == nil ? L("這個資料夾還沒有收藏") : L("沒有符合這個標籤的收藏"))
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                grid
            }
        }
        .padding(.vertical, 4)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .safeAreaInset(edge: .bottom) { if editing { selectionBar } }
        .sheet(item: $pick) { action in
            FolderPickerSheet(title: action == .move ? L("移動到") : L("複製到"), excluding: currentID) { target in
                guard let from = currentID else { return }
                if action == .move { favorites.batchMove(selection, from: from, to: target) }
                else { favorites.batchCopy(selection, from: from, to: target) }
                selection = []; editing = false
            }
        }
        .alert(L("重新命名資料夾"), isPresented: $renaming) {
            TextField(L("名稱"), text: $renameText)
            Button(L("確定")) { if let id = currentID { favorites.rename(id, to: renameText) } }
            Button(L("取消"), role: .cancel) {}
        }
        .alert(L("新增資料夾"), isPresented: $creating) {
            TextField(L("名稱"), text: $newName)
            Button(L("建立")) { folderID = favorites.createFolder(newName); newName = "" }
            Button(L("取消"), role: .cancel) { newName = "" }
        }
        .alert(L("編輯標籤"), isPresented: Binding(get: { tagEditing != nil }, set: { if !$0 { tagEditing = nil } })) {
            TextField(L("用逗號分隔，例如：長篇, 已看完"), text: $tagText)
            Button(L("儲存")) {
                if let item = tagEditing, let id = currentID {
                    let tags = tagText.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    favorites.setTags(item.id, in: id, tags: tags)
                }
            }
            Button(L("取消"), role: .cancel) {}
        }
        .confirmationDialog(L("刪除這個資料夾？裡面的收藏也會一併移除。"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("刪除"), role: .destructive) { if let id = currentID { favorites.deleteFolder(id); folderID = nil } }
        }
    }

    // MARK: 子視圖

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favorites.folders) { folder in
                    let selected = folder.id == currentID
                    Button { folderID = folder.id; tagFilter = nil; selection = [] } label: {
                        Text("\(folder.name)（\(folder.visibleItems.count)）")
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(tint: selected ? nil : Color.clear, interactive: true)
                    .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                Button { creating = true } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.plain).glassCapsule(interactive: true)
            }
            .padding(.horizontal, 12)
        }
    }

    private func tagChips(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button { tagFilter = tagFilter == tag ? nil : tag } label: {
                        Text("#\(tag)").font(.caption.weight(tagFilter == tag ? .bold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(tint: tagFilter == tag ? nil : Color.clear)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var grid: some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                if editing {
                    Button {
                        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                    } label: {
                        ComicCard(comic: item.summary, showSourceBadge: true)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).padding(10)
                                    .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .white)
                                    .shadow(radius: 2)
                            }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item.summary) {
                        ComicCard(comic: item.summary, showSourceBadge: true)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { tagText = item.tags.joined(separator: ", "); tagEditing = item } label: { Label(L("編輯標籤"), systemImage: "tag") }
                        Button(role: .destructive) { if let id = currentID { favorites.remove(item.summary, from: id) } } label: {
                            Label(L("取消收藏"), systemImage: "heart.slash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var menu: some View {
        Menu {
            Button { editing.toggle(); selection = [] } label: { Label(editing ? L("完成選取") : L("選取"), systemImage: "checkmark.circle") }
            if let id = currentID, let folder {
                Menu(L("排序")) {
                    ForEach(FavoriteSort.allCases) { sort in
                        Button { favorites.setSort(id, sort) } label: {
                            if folder.sort == sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                        }
                    }
                }
                Button { renameText = folder.name; renaming = true } label: { Label(L("重新命名"), systemImage: "pencil") }
                Button { favorites.moveFolder(id, by: -1) } label: { Label(L("資料夾前移"), systemImage: "arrow.left") }
                Button { favorites.moveFolder(id, by: 1) } label: { Label(L("資料夾後移"), systemImage: "arrow.right") }
                Button {
                    follow.followedFolderID = follow.followedFolderID == id ? nil : id
                } label: {
                    Label(follow.followedFolderID == id ? L("取消追蹤更新") : L("追蹤這個資料夾的更新"), systemImage: "bell")
                }
                if favorites.folders.count > 1 {
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("刪除資料夾"), systemImage: "trash") }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button(L("全選")) { selection = Set(items.map(\.id)) }
            Spacer()
            Button { pick = .move } label: { Label(L("移動"), systemImage: "folder") }.disabled(selection.isEmpty)
            Button { pick = .copy } label: { Label(L("複製"), systemImage: "doc.on.doc") }.disabled(selection.isEmpty)
            Button(role: .destructive) {
                if let id = currentID { favorites.batchDelete(selection, from: id) }
                selection = []
            } label: { Label(L("刪除"), systemImage: "trash") }.disabled(selection.isEmpty)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}
