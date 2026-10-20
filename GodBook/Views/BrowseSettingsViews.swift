import SwiftUI

struct BrowseSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: L("列表顯示")) {
                    Picker(L("樣式"), selection: $settings.listDisplay) {
                        Text(L("卡片")).tag("card")
                        Text(L("簡潔")).tag("brief")
                        Text(L("詳細")).tag("detailed")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text(L("卡片大小"))
                        Slider(value: $settings.listScale, in: 0.75...1.25)
                    }
                    Toggle(L("分頁模式（關閉則連續捲動載入）"), isOn: $settings.listPaging)
                    Toggle(L("卡片上顯示「已收藏 / 已讀」狀態"), isOn: $settings.showTileStatus)
                    Toggle(L("章節列表預設反轉順序"), isOn: $settings.reverseChapters)
                }

                GlassPanel(title: L("搜尋")) {
                    Picker(L("預設搜尋目標"), selection: $settings.defaultSearchTarget) {
                        Text(L("目前來源")).tag("current")
                        Text(L("聚合搜尋（多個來源）")).tag("aggregated")
                    }
                    .pickerStyle(.menu)
                    Picker(L("自動語言過濾"), selection: $settings.autoLanguage) {
                        Text(L("不過濾")).tag("none")
                        Text(L("中文")).tag("chinese")
                        Text(L("英文")).tag("english")
                        Text(L("日文")).tag("japanese")
                    }
                    .pickerStyle(.menu)
                    Text(L("語言過濾只對 nhentai 與 ehentai 生效。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(L("清除搜尋歷史"), role: .destructive) { settings.searchHistory = [] }
                        .disabled(settings.searchHistory.isEmpty)
                }

                GlassPanel(title: L("屏蔽")) {
                    NavigationLink { BlocklistView(comments: false) } label: {
                        HStack { Text(L("漫畫關鍵字屏蔽（%@）", "\(settings.blockedWords.count)")); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    NavigationLink { BlocklistView(comments: true) } label: {
                        HStack { Text(L("評論關鍵字屏蔽（%@）", "\(settings.blockedCommentWords.count)")); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                GlassPanel(title: L("啟動")) {
                    Picker(L("開啟時的頁面"), selection: $settings.initialTab) {
                        Text(L("探索")).tag(0)
                        Text(L("書庫")).tag(1)
                        Text(L("設定")).tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("瀏覽"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BlocklistView: View {
    let comments: Bool
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""

    private var words: [String] { comments ? settings.blockedCommentWords : settings.blockedWords }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L("新增關鍵字"), text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(add)
                    Button(L("加入"), action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(comments ? L("包含這些關鍵字的評論不會顯示。") : L("標題、副標題或標籤包含這些關鍵字的漫畫不會出現在列表中。"))
            }
            Section {
                ForEach(words, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        var list = words
                        list.remove(atOffsets: offsets)
                        if comments { settings.blockedCommentWords = list } else { settings.blockedWords = list }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .themedScreen()
        .navigationTitle(comments ? L("評論關鍵字") : L("漫畫關鍵字"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !words.contains(word) else { text = ""; return }
        if comments { settings.blockedCommentWords.append(word) } else { settings.blockedWords.append(word) }
        text = ""
    }
}

/// 自訂來源在首頁來源列的順序
struct SourceOrderView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var venera: VeneraStore
    @State private var items: [SourceKind] = SourceKind.all

    var body: some View {
        List {
            ForEach(items.filter { !SafeMode.hides($0) }) { kind in
                HStack {
                    Text(kind.title)
                    Spacer()
                    if !settings.isEnabled(kind) { Text(L("已停用")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .onMove { from, to in
                items.move(fromOffsets: from, toOffset: to)
                settings.sourceOrder = items.map(\.rawValue)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .themedScreen()
        .navigationTitle(L("來源順序"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = SourceKind.all }
    }
}

/// 安全模式：選擇哪些漫畫源視為 18+
struct SafeModeSourcesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var venera: VeneraStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: L("視為 18+ 的來源")) {
                    HStack {
                        Text("nhentai"); Spacer()
                        Text(L("固定")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L("禁漫")); Spacer()
                        Text(L("固定")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(venera.sources) { info in
                        Toggle(info.name, isOn: Binding(
                            get: { SafeMode.isAdultKey(info.key) },
                            set: { set(info.key, $0) }))
                    }
                    Text(L("標記為 18+ 的來源在安全模式下會從首頁、搜尋與設定中隱藏。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("18+ 來源標記"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ key: String, _ adult: Bool) {
        var marked = settings.adultMarked.filter { $0 != key }
        var unmarked = settings.adultUnmarked.filter { $0 != key }
        let builtin = SafeMode.builtinAdultKeys.contains(key)
        if adult && !builtin { marked.append(key) }
        if !adult && builtin { unmarked.append(key) }
        settings.adultMarked = marked
        settings.adultUnmarked = unmarked
    }
}
