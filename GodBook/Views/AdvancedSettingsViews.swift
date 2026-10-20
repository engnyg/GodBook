import SwiftUI
import UniformTypeIdentifiers

// MARK: - 網路

struct NetworkSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: L("代理")) {
                    Picker(L("模式"), selection: $settings.proxyMode) {
                        Text(L("系統")).tag("system")
                        Text(L("直連")).tag("direct")
                        Text(L("手動")).tag("manual")
                    }
                    .pickerStyle(.segmented)

                    if settings.proxyMode == "manual" {
                        Picker(L("類型"), selection: $settings.proxyType) {
                            Text("HTTP").tag("http")
                            Text("SOCKS5").tag("socks5")
                        }
                        .pickerStyle(.segmented)
                        TextField(L("主機（例如 127.0.0.1）"), text: $settings.proxyHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        TextField(L("連接埠（例如 7890）"), text: $settings.proxyPort)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    }
                    GlassButton(title: testing ? L("測試中…") : L("套用並測試連線"), systemImage: "network", prominent: true) { apply() }
                        .disabled(testing)
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }

                GlassPanel(title: L("安全")) {
                    Toggle(L("忽略憑證錯誤"), isOn: $settings.ignoreBadCert)
                        .onChange(of: settings.ignoreBadCert) { _, _ in HTTP.reload() }
                    Text(L("僅在連到自架或使用自簽憑證的伺服器時開啟；開啟後連線可能被中間人攔截。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                GlassPanel(title: L("關於 DNS 覆寫")) {
                    Text(L("iOS 的網路層不允許只替單一網域指定 IP 而不破壞 TLS（SNI 與憑證驗證），因此無法像桌面版一樣做 DNS 覆寫。若要繞過 DNS 污染，請使用代理，或在 iOS 設定中安裝加密 DNS（DoH / DoT）描述檔。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("網路"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apply() {
        HTTP.reload()
        testing = true
        status = nil
        Task {
            let start = Date()
            do {
                var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
                request.timeoutInterval = 10
                let (_, response) = try await HTTP.data(for: request)
                status = L("連線正常（HTTP %@，%@ ms）", "\(response.statusCode)", "\(Int(Date().timeIntervalSince(start) * 1000))")
            } catch {
                status = L("連線失敗：%@", "\(error.localizedDescription)")
            }
            testing = false
        }
    }
}

// MARK: - 快取與資料

struct CacheDataSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager
    @State private var cacheSize: Int64 = 0
    @State private var exported: ExportedFile?
    @State private var importing = false
    @State private var message: String?
    @State private var davPassword = WebDAV.password
    @State private var busy = false

    private let limits = [512, 1024, 2048, 4096, 0]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: L("圖片快取")) {
                    HStack {
                        Text(L("目前大小"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    Picker(L("上限"), selection: $settings.cacheLimitMB) {
                        ForEach(limits, id: \.self) { Text($0 == 0 ? L("不限制") : "\($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB")").tag($0) }
                    }
                    .pickerStyle(.menu)
                    GlassButton(title: L("清除快取"), systemImage: "trash") {
                        ImageDiskCache.clear()
                        URLCache.shared.removeAllCachedResponses()
                        HTTP.session.configuration.urlCache?.removeAllCachedResponses()
                        Task { await ImageLoader.shared.clearMemory(); await refreshSize() }
                    }
                }

                GlassPanel(title: L("備份與還原")) {
                    GlassButton(title: L("匯出全部資料"), systemImage: "square.and.arrow.up") { export() }
                    GlassButton(title: L("匯入備份檔"), systemImage: "square.and.arrow.down") { importing = true }
                    Text(L("包含收藏、歷史、設定、主題、漫畫源與登入狀態；不含已下載的圖片。匯入後請完全關閉並重新開啟 App。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                GlassPanel(title: L("WebDAV 同步")) {
                    TextField(L("WebDAV 網址（資料夾）"), text: $settings.webdavURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    TextField(L("帳號"), text: $settings.webdavUser)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    SecureField(L("密碼"), text: $davPassword).textFieldStyle(.roundedBorder)
                        .onChange(of: davPassword) { _, value in WebDAV.password = value }
                    HStack(spacing: 12) {
                        GlassButton(title: L("上傳"), systemImage: "icloud.and.arrow.up") { davUpload() }.disabled(busy)
                        GlassButton(title: L("下載"), systemImage: "icloud.and.arrow.down") { davDownload() }.disabled(busy)
                    }
                    Toggle(L("離開 App 時自動上傳"), isOn: $settings.webdavAutoUpload)
                }

                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("快取與資料"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSize() }
        .sheet(item: $exported) { file in ShareSheet(urls: [file.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try AppBackup.restore(try Data(contentsOf: url))
                message = L("已匯入。請完全關閉並重新開啟 GodBook 以套用。")
            } catch { message = error.localizedDescription }
        }
    }

    private func refreshSize() async {
        let disk = await Task.detached { ImageDiskCache.size() }.value
        cacheSize = disk
    }

    private func export() {
        do { exported = ExportedFile(url: try AppBackup.exportFile()) }
        catch { message = error.localizedDescription }
    }

    private func davUpload() {
        busy = true; message = L("上傳中…")
        Task {
            do { try await WebDAV.upload(); message = L("已上傳到 WebDAV") }
            catch { message = L("上傳失敗：%@", "\(error.localizedDescription)") }
            busy = false
        }
    }

    private func davDownload() {
        busy = true; message = L("下載中…")
        Task {
            do {
                let data = try await WebDAV.download()
                try AppBackup.restore(data)
                message = L("已下載並還原。請完全關閉並重新開啟 GodBook 以套用。")
            } catch { message = L("下載失敗：%@", "\(error.localizedDescription)") }
            busy = false
        }
    }
}

// MARK: - 安全性

struct SecuritySettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassPanel(title: L("App 鎖")) {
                    Toggle(L("需要 Face ID / Touch ID / 密碼才能開啟"), isOn: $settings.appLockEnabled)
                    Text(L("離開 App 後再回來會要求驗證，並在多工畫面隱藏內容。若裝置沒有設定密碼則不會鎖定。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("安全性"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
