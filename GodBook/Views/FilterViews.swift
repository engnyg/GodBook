import SwiftUI

/// 篩選條件面板（排序、語言、分類、搜尋選項…）
struct FilterSheet: View {
    let groups: [FilterGroup]
    @Binding var values: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups) { group in
                    Section(group.title) {
                        switch group.kind {
                        case .select:
                            Picker(group.title, selection: binding(group)) {
                                ForEach(group.options, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .pickerStyle(.menu)
                        case .dropdown:
                            Picker(group.title, selection: binding(group)) {
                                Text(L("不限")).tag("")
                                ForEach(group.options, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .pickerStyle(.menu)
                        case .multi:
                            ForEach(group.options, id: \.value) { option in
                                Toggle(option.title, isOn: multiBinding(group, option.value))
                            }
                        }
                    }
                }
                Section {
                    Button(L("全部還原"), role: .destructive) { values = [:] }
                }
            }
            .navigationTitle(L("篩選"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(_ group: FilterGroup) -> Binding<String> {
        Binding(get: { values[group.id] ?? group.effective([:]) ?? "" },
                set: { values[group.id] = $0 })
    }

    private func multiBinding(_ group: FilterGroup, _ value: String) -> Binding<Bool> {
        func current() -> [String] {
            let json = values[group.id] ?? group.effective([:]) ?? "[]"
            return ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String]) ?? []
        }
        return Binding(
            get: { current().contains(value) },
            set: { on in
                var list = current()
                if on { if !list.contains(value) { list.append(value) } } else { list.removeAll { $0 == value } }
                let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
                values[group.id] = String(decoding: data, as: UTF8.self)
            })
    }
}

/// 分類 / 排行頁
struct CategoriesView: View {
    let source: SourceKind

    var body: some View {
        let sections = SourceRegistry.source(source).categorySections()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if sections.isEmpty {
                    Text(L("這個來源沒有分類頁")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(section.entries) { entry in
                                NavigationLink(value: SearchRoute(source: source, query: entry.query, title: entry.title)) {
                                    Text(entry.title).font(.subheadline)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .glassCapsule(interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 24)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("分類"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一次搜尋多個來源
struct AggregatedSearchView: View {
    @State var query: String
    @EnvironmentObject private var settings: AppSettings
    @State private var selected: Set<SourceKind> = []
    @State private var results: [SourceKind: Outcome] = [:]
    @State private var running = false
    @State private var didInit = false

    enum Outcome {
        case loading
        case items([ComicSummary])
        case failed(String)
    }

    private var candidates: [SourceKind] {
        settings.enabledSources.filter { kind in
            if kind.isVenera { return VeneraRegistry.shared.info(kind.veneraKey)?.search != nil }
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L("搜尋關鍵字"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { run() }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(candidates) { kind in
                                let on = selected.contains(kind)
                                Button {
                                    if on { selected.remove(kind) } else { selected.insert(kind) }
                                } label: {
                                    Label(kind.title, systemImage: on ? "checkmark.circle.fill" : "circle")
                                        .font(.caption.weight(on ? .bold : .regular))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                .glassCapsule(tint: on ? nil : Color.clear, interactive: true)
                            }
                        }
                    }
                    GlassButton(title: running ? L("搜尋中…") : L("搜尋"), systemImage: "magnifyingglass", prominent: true) { run() }
                        .disabled(running || selected.isEmpty || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
                .glassCard(cornerRadius: 24)

                ForEach(candidates.filter { selected.contains($0) }) { kind in
                    if let outcome = results[kind] { section(kind, outcome) }
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("聚合搜尋"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            selected = Set(candidates)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { run() }
        }
    }

    @ViewBuilder
    private func section(_ kind: SourceKind, _ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title).font(.headline)
                Spacer()
                NavigationLink(value: SearchRoute(source: kind, query: query, title: "\(kind.title)：\(query)")) {
                    Text(L("更多")).font(.footnote)
                }
            }
            switch outcome {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.secondary)
            case .items(let list):
                if list.isEmpty {
                    Text(L("沒有結果")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(list.prefix(12)) { comic in
                                NavigationLink(value: comic) {
                                    BriefTile(comic: comic).frame(width: 118)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func run() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        running = true
        let targets = candidates.filter { selected.contains($0) }
        for kind in targets { results[kind] = .loading }
        Task {
            var index = 0
            while index < targets.count {
                let batch = Array(targets[index..<min(index + 3, targets.count)])
                index += batch.count
                await withTaskGroup(of: (SourceKind, Outcome).self) { group in
                    for kind in batch {
                        group.addTask {
                            let source = SourceRegistry.source(kind)
                            do {
                                let page = try await source.browse(query: text, page: 1, sort: source.sortOptions[0])
                                return (kind, .items(page.items.filter { !Blocklist.blocks($0) }))
                            } catch {
                                return (kind, .failed(error.localizedDescription))
                            }
                        }
                    }
                    for await (kind, outcome) in group { results[kind] = outcome }
                }
            }
            running = false
            addToHistory(text)
        }
    }

    private func addToHistory(_ text: String) {
        var list = settings.searchHistory.filter { $0 != text }
        list.insert(text, at: 0)
        settings.searchHistory = Array(list.prefix(30))
    }
}
