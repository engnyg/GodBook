import SwiftUI

/// 排序 / 分區選單；有 `section` 的選項會分組顯示（venera 漫畫源）。
struct SortMenu: View {
    let options: [SortOption]
    let selection: String
    let onSelect: (String) -> Void

    private var groups: [(title: String?, items: [SortOption])] {
        var result: [(title: String?, items: [SortOption])] = []
        for option in options {
            if let last = result.indices.last, result[last].title == option.section {
                result[last].items.append(option)
            } else {
                result.append((option.section, [option]))
            }
        }
        return result
    }

    var body: some View {
        Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) { items(group.items) }
                } else {
                    items(group.items)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    @ViewBuilder
    private func items(_ list: [SortOption]) -> some View {
        ForEach(list) { option in
            Button {
                onSelect(option.id)
            } label: {
                if option.id == selection {
                    Label(option.title, systemImage: "checkmark")
                } else {
                    Text(option.title)
                }
            }
        }
    }
}
