import SwiftUI

/// 設定 → 下載 → 雲端儲存：連結 OneDrive / Google Drive / WebDAV、上傳與本機保存策略。
struct CloudSettingsView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @ObservedObject private var settings = CloudSettings.shared
    @State private var connecting: CloudKind?
    @State private var restoring = false
    @State private var message: String?
    @State private var cacheSize: Int64 = 0
    @State private var freeSpace: Int64 = 0
    @State private var folderDraft = CloudSettings.shared.rootFolder

    private let cacheLimits = [256, 512, 1024, 2048, 4096]
    private static let guideURL = URL(string: "https://github.com/Ray3558/GodBook/blob/main/docs/cloud-setup.md")!

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: nil) {
                    Text(L("把已下載的章節以 CBZ 格式上傳到雲端，並可釋放手機空間；閱讀只在雲端的章節時會自動下載。OneDrive 與 Google Drive 需要先在各自的開發者後台建立用戶端 ID。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Link(destination: Self.guideURL) {
                        Label(L("設定教學（Azure / Google Cloud）"), systemImage: "book")
                    }
                    .font(.footnote)
                }

                ForEach(CloudKind.allCases) { serviceCard($0) }
                uploadPanel
                retentionPanel
                cachePanel

                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("雲端儲存"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSizes() }
    }

    // MARK: 服務

    private func serviceCard(_ kind: CloudKind) -> some View {
        GlassPanel(title: kind.title) {
            if let account = cloud.accounts[kind.rawValue] {
                HStack {
                    Label(account, systemImage: "checkmark.seal.fill").lineLimit(1)
                    Spacer()
                    Button(L("中斷連結"), role: .destructive) { cloud.disconnect(kind) }
                }
            } else {
                switch kind {
                case .oneDrivePersonal:
                    clientField($settings.msPersonalClientId)
                case .oneDriveBusiness:
                    clientField($settings.msBusinessClientId)
                    TextField(L("租用戶（網域或租用戶 ID，預設 organizations）"), text: $settings.msBusinessTenant)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Text(L("適用 Microsoft 365 公司或學校帳號（例如 E3）。若應用程式只註冊在自己的租用戶，請填租用戶網域，例如 contoso.onmicrosoft.com。"))
                        .font(.footnote).foregroundStyle(.secondary)
                case .googleDrive:
                    clientField($settings.googleClientId)
                    Text(L("只會存取 GodBook 自己建立的檔案（drive.file 權限）。"))
                        .font(.footnote).foregroundStyle(.secondary)
                case .webdav:
                    Text(L("使用「快取、備份與 WebDAV」中填寫的伺服器與帳號，章節會放在該網址底下的雲端資料夾。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let redirect = OAuthConfig.redirectURI(for: kind) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("重新導向 URI")).font(.caption).foregroundStyle(.secondary)
                        Text(redirect).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                GlassButton(title: connecting == kind ? L("連結中…") : L("連結"), systemImage: "link", prominent: true) {
                    connect(kind)
                }
                .disabled(connecting != nil || (kind.usesOAuth && settings.clientId(for: kind).isEmpty))
            }
        }
    }

    private func clientField(_ text: Binding<String>) -> some View {
        TextField(L("用戶端 ID（應用程式識別碼）"), text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
    }

    private func connect(_ kind: CloudKind) {
        connecting = kind
        message = nil
        Task {
            do {
                try await cloud.connect(kind)
                message = L("已連結 %@", kind.title)
            } catch is CancellationError {
                // 使用者關閉了登入頁
            } catch {
                message = error.localizedDescription
            }
            connecting = nil
        }
    }

    // MARK: 上傳

    private var uploadPanel: some View {
        GlassPanel(title: L("上傳")) {
            Picker(L("上傳目標"), selection: Binding(
                get: { cloud.target?.rawValue ?? "" },
                set: { value in
                    settings.target = CloudKind(rawValue: value)
                    cloud.settingsChanged()
                })) {
                Text(L("未選擇")).tag("")
                ForEach(cloud.connectedKinds) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            folderField
            Toggle(L("下載完成後自動上傳"), isOn: $settings.autoUpload)
                .onChange(of: settings.autoUpload) { _, _ in cloud.settingsChanged() }
            Toggle(L("只在 Wi-Fi 上傳"), isOn: $settings.wifiOnly)
                .onChange(of: settings.wifiOnly) { _, _ in cloud.settingsChanged() }

            if !cloud.queue.isEmpty || cloud.waitingForWiFi {
                HStack {
                    Text(cloud.waitingForWiFi ? L("等待 Wi-Fi，%@ 話待上傳", "\(cloud.queue.count)") : L("%@ 話待上傳", "\(cloud.queue.count)"))
                    Spacer()
                    Button(L("取消"), role: .destructive) { cloud.cancelQueue() }
                }
                .font(.footnote)
            }
            if let progress = currentProgress {
                ProgressView(value: progress) { Text(L("上傳中")).font(.caption) }
            }
            if let text = cloud.message { Text(text).font(.footnote).foregroundStyle(.orange) }

            GlassButton(title: L("上傳所有尚未上傳的章節"), systemImage: "icloud.and.arrow.up") { cloud.enqueuePending() }
                .disabled(cloud.target == nil)
            if failedCount > 0 {
                GlassButton(title: L("重試失敗的項目（%@）", "\(failedCount)"), systemImage: "arrow.clockwise") { cloud.retryFailed() }
            }
            GlassButton(title: restoring ? L("還原中…") : L("從雲端還原下載清單"), systemImage: "arrow.down.doc") { restore() }
                .disabled(cloud.target == nil || restoring)
            Text(L("換裝置或重新安裝後，可依雲端上的清單把作品加回下載列表（只在雲端，閱讀時才下載）。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 雲端資料夾：按「儲存」或鍵盤的完成才套用，避免輸入到一半就開始上傳到半成品的資料夾
    private var folderField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("雲端資料夾")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("GodBook", text: $folderDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(saveFolder)
                if folderDraft != settings.rootFolder {
                    Button(L("儲存"), action: saveFolder)
                }
            }
            Text(L("目前位置：%@。可用 / 建立多層資料夾，例如「漫畫/GodBook」。已上傳的章節會留在原本的資料夾並照常讀取，之後上傳的才會放到新資料夾；Google Drive 只看得到 GodBook 自己建立的資料夾。", settings.rootPath.joined(separator: "/")))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func saveFolder() {
        settings.rootFolder = folderDraft
        // 存成整理後的路徑（空白會變回 GodBook、不合法的字元換成 _）
        folderDraft = settings.rootPath.joined(separator: "/")
        settings.rootFolder = folderDraft
    }

    private var currentProgress: Double? {
        for state in cloud.tasks.values { if case .uploading(let value) = state { return value } }
        return nil
    }

    private var failedCount: Int {
        cloud.tasks.values.filter { if case .failed = $0 { return true } else { return false } }.count
    }

    private func restore() {
        guard let kind = cloud.target else { return }
        restoring = true
        message = nil
        Task {
            do {
                let count = try await cloud.restoreList(from: kind)
                message = L("已從雲端加入 %@ 話", "\(count)")
            } catch {
                message = error.localizedDescription
            }
            restoring = false
        }
    }

    // MARK: 本機保存策略

    private var retentionPanel: some View {
        GlassPanel(title: L("本機保存策略")) {
            Picker(L("預設策略"), selection: $settings.defaultPolicy) {
                ForEach(RetentionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Text(settings.defaultPolicy.detail).font(.footnote).foregroundStyle(.secondary)
            Stepper(L("「只保留最近幾話」保留 %@ 話", "\(settings.keepRecent)"), value: $settings.keepRecent, in: 1...50)
            Stepper(L("「空間不足時」門檻：剩餘 %@ GB", "\(settings.lowSpaceGB)"), value: $settings.lowSpaceGB, in: 1...64)
            HStack {
                Text(L("目前剩餘空間"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)).foregroundStyle(.secondary)
            }
            Text(L("只有已上傳且確認大小一致的章節才會從本機刪除；作品的詳情與封面會保留。每部作品可在「書庫 → 下載」長按另外指定策略。"))
                .font(.footnote).foregroundStyle(.secondary)
            Text(L("下載回本機的章節會暫時保留，不會被保存策略自動刪除；不需要時可在作品詳情頁逐話或整部釋放。"))
                .font(.footnote).foregroundStyle(.secondary)
            GlassButton(title: L("立即套用"), systemImage: "checkmark.circle") {
                cloud.applyRetention()
                Task { await refreshSizes() }
            }
        }
    }

    // MARK: 快取

    private var cachePanel: some View {
        GlassPanel(title: L("雲端閱讀快取")) {
            HStack {
                Text(L("目前大小"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).foregroundStyle(.secondary)
            }
            Picker(L("上限"), selection: $settings.cacheLimitMB) {
                ForEach(cacheLimits, id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
            }
            .pickerStyle(.menu)
            GlassButton(title: L("清除快取"), systemImage: "trash") {
                CloudCache.clear()
                Task { await refreshSizes() }
            }
            Text(L("閱讀只在雲端的章節時會先下載到這裡，超過上限會刪除最久沒讀的章節；系統空間不足時也可能自動清除。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func refreshSizes() async {
        cacheSize = await Task.detached { CloudCache.size() }.value
        freeSpace = CloudSync.availableSpace()
    }
}
