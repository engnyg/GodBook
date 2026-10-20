import SwiftUI

/// 閱讀設定表單（全域設定頁與閱讀器內的設定面板共用）
struct ReaderPrefsForm: View {
    @Binding var prefs: ReaderPrefs
    @ObservedObject private var app = AppSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            GlassPanel(title: L("閱讀方式")) {
                Picker(L("模式"), selection: $prefs.mode) {
                    ForEach(ReaderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(L("翻頁動畫"), isOn: $prefs.pageAnimation)
            }

            GlassPanel(title: L("操作")) {
                Toggle(L("點擊畫面兩側翻頁"), isOn: $prefs.tapToTurn)
                if prefs.tapToTurn {
                    Toggle(L("反向點擊（左右對調）"), isOn: $prefs.reverseTap)
                }
                Toggle(L("雙擊縮放"), isOn: $prefs.doubleTapZoom)
                    .disabled(prefs.quickCollect)
                Toggle(L("長按放大（放開還原）"), isOn: $prefs.longPressZoom)
                Toggle(L("雙擊收藏圖片"), isOn: $prefs.quickCollect)
                Toggle(L("音量鍵翻頁"), isOn: $prefs.volumeKeys)
                Text(L("連續由上到下的模式（條漫）點擊只會顯示或隱藏工具列。音量鍵翻頁時，音量上 = 上一頁、音量下 = 下一頁。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            GlassPanel(title: L("自動與預載")) {
                Stepper(prefs.autoTurnSeconds == 0 ? L("自動翻頁：關閉") : L("自動翻頁：每 %@ 秒", "\(prefs.autoTurnSeconds)"),
                        value: $prefs.autoTurnSeconds, in: 0...60)
                Stepper(L("預載後面 %@ 張", "\(prefs.preloadCount)"), value: $prefs.preloadCount, in: 0...10)
                Toggle(L("翻到章節盡頭自動進入下一章 / 上一章"), isOn: $app.autoNextChapter)
            }

            GlassPanel(title: L("畫面")) {
                Toggle(L("顯示頁碼"), isOn: $prefs.showPageNumber)
                Toggle(L("顯示時間與電量"), isOn: $prefs.showClockBattery)
                Toggle(L("閱讀時保持螢幕不熄滅"), isOn: $prefs.keepScreenOn)
            }
        }
    }
}

struct ReaderSettingsPage: View {
    @EnvironmentObject private var store: ReaderPrefsStore

    var body: some View {
        ScrollView {
            ReaderPrefsForm(prefs: $store.global).padding(16)
        }
        .themedScreen()
        .navigationTitle(L("閱讀設定"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 閱讀器內的設定面板：可切換成「只對這部漫畫生效」。
struct ReaderSettingsSheet: View {
    let comicKey: String
    @EnvironmentObject private var store: ReaderPrefsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassPanel(title: nil) {
                        Toggle(L("這部漫畫使用獨立設定"), isOn: Binding(
                            get: { store.hasOverride(comicKey) },
                            set: { on in store.setOverride(comicKey, on ? store.global : nil) }))
                        Text(L("開啟後，下面的調整只影響這部漫畫，不會改到全域設定。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ReaderPrefsForm(prefs: Binding(
                        get: { store.prefs(for: comicKey) },
                        set: { store.update(for: comicKey, $0) }))
                }
                .padding(16)
            }
            .themedScreen()
            .navigationTitle(L("閱讀設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct ReaderChapterSheet: View {
    let chapters: [Chapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        onSelect(index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title).lineLimit(2)
                            Spacer()
                            if index == currentIndex { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle(L("章節"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("關閉")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct ShareItemsSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 閱讀器角落的時間 / 電量
struct ReaderInfoBadge: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let level = UIDevice.current.batteryLevel
            HStack(spacing: 6) {
                Text(context.date, style: .time)
                if level >= 0 {
                    Image(systemName: level > 0.75 ? "battery.100" : level > 0.5 ? "battery.75" : level > 0.25 ? "battery.50" : "battery.25")
                    Text("\(Int(level * 100))%")
                }
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
        }
    }
}
