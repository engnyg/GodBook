import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var settings: AppSettings

    @State private var photoItem: PhotosPickerItem?
    @State private var jmPassword = ""
    @State private var jmBusy = false
    @State private var jmMessage: String?
    @State private var downloadSize: Int64 = 0
    @State private var confirmClear = false
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var venera: VeneraStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                languageCard
                safeModeCard
                themeCard
                backgroundCard
                glassCard
                veneraCard
                if !settings.safeMode {
                    nhentaiCard
                    jmCard
                }
                readerCard
                browseCard
                advancedCard
                downloadCard
                aboutCard
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("設定"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Language", selection: $settings.language) {
                        ForEach(Language.choices, id: \.code) { Text(Language.title($0.code)).tag($0.code) }
                    }
                } label: {
                    Image(systemName: "globe")
                }
                .accessibilityLabel("語言 / Language")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    theme.setBackgroundImage(data: data)
                }
                photoItem = nil
            }
        }
    }

    // MARK: 主題

    private var themeCard: some View {
        SettingsCard(title: L("主題色"), systemImage: "paintpalette.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ThemePreset.all) { preset in
                        Button {
                            withAnimation(.snappy) {
                                theme.config.accentHex = preset.accent
                                theme.config.gradientStartHex = preset.start
                                theme.config.gradientEndHex = preset.end
                                if theme.config.backgroundMode == .system || theme.config.backgroundMode == .solid {
                                    theme.config.backgroundMode = .gradient
                                }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(hex: preset.start), Color(hex: preset.end)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .overlay(Circle().stroke(Color(hex: preset.accent), lineWidth: 3))
                                    .frame(width: 44, height: 44)
                                Text(preset.name).font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            ColorPicker(L("強調色"), selection: theme.colorBinding(\.accentHex), supportsOpacity: false)
            Picker(L("外觀"), selection: $theme.config.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var backgroundCard: some View {
        SettingsCard(title: L("背景"), systemImage: "photo.fill") {
            Picker(L("背景"), selection: $theme.config.backgroundMode) {
                ForEach(BackgroundMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch theme.config.backgroundMode {
            case .system:
                Text(L("使用系統預設背景")).font(.footnote).foregroundStyle(.secondary)
            case .solid:
                ColorPicker(L("背景顏色"), selection: theme.colorBinding(\.solidHex), supportsOpacity: false)
            case .gradient:
                ColorPicker(L("漸層起點"), selection: theme.colorBinding(\.gradientStartHex), supportsOpacity: false)
                ColorPicker(L("漸層終點"), selection: theme.colorBinding(\.gradientEndHex), supportsOpacity: false)
            case .image:
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(theme.backgroundImage == nil ? L("選擇背景圖片") : L("更換背景圖片"), systemImage: "photo.on.rectangle")
                }
                if theme.backgroundImage != nil {
                    LabeledSlider(title: L("模糊"), value: $theme.config.imageBlur, range: 0...30)
                    LabeledSlider(title: L("壓暗"), value: $theme.config.imageDim, range: 0...0.8)
                    Button(L("移除圖片"), role: .destructive) { theme.clearBackgroundImage() }
                }
            }
        }
    }

    private var glassCard: some View {
        SettingsCard(title: L("液態玻璃"), systemImage: "drop.fill") {
            Toggle(L("啟用玻璃效果"), isOn: $theme.config.useGlass)
            if theme.config.useGlass {
                LabeledSlider(title: L("染色強度"), value: $theme.config.glassTint, range: 0...0.6)
            }
            if #available(iOS 26.0, *) {
                Text(L("目前系統支援原生液態玻璃 (iOS 26)。")).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(L("iOS 26 以下以模糊材質模擬；升級到 iOS 26 即為原生液態玻璃。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(L("還原預設主題"), role: .destructive) { theme.reset() }
        }
    }

    // MARK: 語言

    /// 標題固定中英並列：不管目前是哪種語言都找得到
    private var languageCard: some View {
        SettingsCard(title: "語言 / Language", systemImage: "globe") {
            Picker("語言 / Language", selection: $settings.language) {
                ForEach(Language.choices, id: \.code) { Text(Language.title($0.code)).tag($0.code) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 安全模式

    private var safeModeCard: some View {
        SettingsCard(title: L("安全模式"), systemImage: "shield.lefthalf.filled") {
            Toggle(L("隱藏 18+ 內容"), isOn: Binding(
                get: { settings.safeMode },
                set: { value in Task { _ = await SafeMode.set(value) } }))
            Toggle(L("同時隱藏整個書庫分頁"), isOn: $settings.safeHideLibrary)
            Text(L("開啟後會隱藏 18+ 來源（nhentai、禁漫與標記為 18+ 的漫畫源），以及標題或標籤帶有成人字眼的作品，包含收藏、紀錄與下載列表。若已啟用 App 鎖，關閉安全模式需要驗證。"))
                .font(.footnote).foregroundStyle(.secondary)
            link(L("管理 18+ 來源標記"), systemImage: "checklist") { SafeModeSourcesView() }
        }
    }

    // MARK: 來源

    private var veneraCard: some View {
        SettingsCard(title: L("來源管理"), systemImage: "puzzlepiece.extension.fill") {
            NavigationLink {
                VeneraSourcesView()
            } label: {
                HStack {
                    Text(L("啟用 / 停用來源、管理 venera 漫畫源（%@ 個）", "\(venera.sources.count)"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(L("相容 venera 的 JavaScript 漫畫源；內建一批來源，也可自行新增。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var nhentaiCard: some View {
        SettingsCard(title: "nhentai", systemImage: "network") {
            TextField(L("鏡像網域"), text: $settings.nhMirror)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField(L("API Key（選填）"), text: $settings.nhApiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text(L("預設 nhentai.net。若遇到 403，可填入 API Key 或更換鏡像。API Key 只會送到 nhentai.net，不會送到其他鏡像網域。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var jmCard: some View {
        SettingsCard(title: L("禁漫"), systemImage: "person.crop.circle") {
            if settings.jmLoggedIn {
                HStack {
                    Label(settings.jmUsername, systemImage: "checkmark.seal.fill")
                    Spacer()
                    Button(L("登出"), role: .destructive) { Task { await JMClient.shared.logout() } }
                }
            } else {
                TextField(L("帳號"), text: $settings.jmUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField(L("密碼"), text: $jmPassword).textFieldStyle(.roundedBorder)
                GlassButton(title: jmBusy ? L("登入中…") : L("登入"), systemImage: "arrow.right.circle.fill", prominent: true) {
                    login()
                }
                .disabled(jmBusy || settings.jmUsername.isEmpty || jmPassword.isEmpty)
            }
            if let jmMessage {
                Text(jmMessage).font(.footnote).foregroundStyle(.secondary)
            }
            TextField(L("自訂 API 網域（選填，逗號分隔）"), text: $settings.jmCustomDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text(L("預設會自動向官方網域伺服器取得最新 API 網域。登入後可使用雲端收藏。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func login() {
        jmBusy = true
        jmMessage = nil
        let user = settings.jmUsername
        let pass = jmPassword
        Task {
            do {
                try await JMClient.shared.login(username: user, password: pass)
                jmMessage = L("登入成功")
                jmPassword = ""
            } catch {
                jmMessage = error.localizedDescription
            }
            jmBusy = false
        }
    }

    private var readerCard: some View {
        SettingsCard(title: L("閱讀"), systemImage: "book.fill") {
            link(L("閱讀設定（模式、手勢、縮放、音量鍵…）"), systemImage: "slider.horizontal.below.rectangle") { ReaderSettingsPage() }
        }
    }

    private var browseCard: some View {
        SettingsCard(title: L("瀏覽"), systemImage: "square.grid.2x2.fill") {
            link(L("列表、搜尋、屏蔽、啟動頁面"), systemImage: "slider.vertical.3") { BrowseSettingsView() }
        }
    }

    private var advancedCard: some View {
        SettingsCard(title: L("進階"), systemImage: "gearshape.2.fill") {
            link(L("網路（代理、憑證）"), systemImage: "network") { NetworkSettingsView() }
            link(L("快取、備份與 WebDAV"), systemImage: "externaldrive.fill") { CacheDataSettingsView() }
            link(L("安全性（App 鎖）"), systemImage: "lock.shield.fill") { SecuritySettingsView() }
        }
    }

    private func link<Destination: View>(_ title: String, systemImage: String,
                                         @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var downloadCard: some View {
        SettingsCard(title: L("下載"), systemImage: "arrow.down.circle.fill") {
            Stepper(L("同時下載圖片數：%@", "\(settings.downloadConcurrency)"), value: $settings.downloadConcurrency, in: 1...8)
            link(L("雲端儲存（OneDrive、Google Drive、WebDAV）"), systemImage: "icloud.fill") { CloudSettingsView() }
            Toggle(L("翻譯 nhentai 標籤（繁體中文）"), isOn: $settings.translateTags)
            HStack {
                Text(L("已佔用空間"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file)).foregroundStyle(.secondary)
            }
            Button(L("清除所有下載"), role: .destructive) { confirmClear = true }
                .disabled(downloads.items.isEmpty)
            Text(L("下載與匯出的檔案位於「檔案」App → GodBook → Downloads / Exports。清除下載不會刪除雲端上的檔案。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: downloads.items.map(\.done).reduce(0, +)) {
            downloadSize = await Task.detached { DownloadStorage.totalSize() }.value
        }
        .confirmationDialog(L("確定要刪除所有已下載內容？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("刪除全部"), role: .destructive) { downloads.removeAll() }
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: L("關於"), systemImage: "info.circle.fill") {
            Text([
                L("GodBook 整合 nhentai、禁漫與 venera 漫畫源。"),
                L("nhentai 的 API 流程參考 NClientV3 (Apache-2.0)；禁漫的 API 協定與下載流程參考 jmcomic (MIT) 與 jmcomic-downloader (MIT)；漫畫源執行環境與功能設計參考 venera。"),
                L("標籤翻譯來自 EhTagTranslation Database（經 venera 整理）。"),
                L("本 App 僅為第三方客戶端，內容版權屬原網站與作者所有。"),
            ].joined(separator: "\n"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 元件

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 26)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
        }
    }
}
