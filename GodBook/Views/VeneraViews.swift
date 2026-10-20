import SwiftUI
import UniformTypeIdentifiers
import WebKit

private struct Panel<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 26)
    }
}

// MARK: - 漫畫源清單

struct VeneraSourcesView: View {
    @EnvironmentObject private var store: VeneraStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showAdd = false
    @State private var showLog = false
    @State private var restoring = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Panel(title: L("顯示在首頁的來源")) {
                    ForEach(SourceKind.all.filter { !SafeMode.hides($0) }) { kind in
                        Toggle(isOn: Binding(
                            get: { settings.isEnabled(kind) },
                            set: { settings.setEnabled(kind, $0) })) {
                            Text(kind.title)
                        }
                    }
                    Text(L("關閉後該來源不會出現在首頁與雲端收藏，也不會發出任何請求；已安裝的腳本與設定都會保留，隨時可重新開啟。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Panel(title: L("已安裝（%@）", "\(store.sources.count)")) {
                    if store.isBootstrapping && store.sources.isEmpty {
                        HStack { ProgressView(); Text(L("載入內建漫畫源…")).foregroundStyle(.secondary) }
                    }
                    ForEach(store.sources.filter { !SafeMode.hides($0.kind) }) { info in
                        NavigationLink {
                            VeneraSourceDetailView(key: info.key)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.name).font(.subheadline.weight(.semibold))
                                    Text("v\(info.version) · \(info.key)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if store.sources.isEmpty && !store.isBootstrapping {
                        Text(L("尚未安裝任何漫畫源")).foregroundStyle(.secondary)
                    }
                }

                Panel(title: L("排序")) {
                    NavigationLink { SourceOrderView() } label: {
                        HStack { Text(L("調整首頁來源順序")); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Panel(title: L("更新")) {
                    Toggle(L("啟動時自動更新漫畫源"), isOn: $settings.autoUpdateSources)
                    TextField(L("索引網址 (index.json)"), text: $settings.sourceListURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    GlassButton(title: store.isUpdating ? L("更新中…") : L("立即檢查並更新"), systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            let count = await store.checkUpdates(install: true)
                            ToastCenter.shared.show(count > 0 ? L("已更新 %@ 個漫畫源", "\(count)") : L("漫畫源都是最新版"))
                        }
                    }
                    .disabled(store.isUpdating)
                }

                Panel(title: nil) {
                    GlassButton(title: L("新增或更新漫畫源"), systemImage: "plus.circle.fill", prominent: true) { showAdd = true }
                    GlassButton(title: restoring ? L("處理中…") : L("重新安裝內建漫畫源"), systemImage: "arrow.counterclockwise") {
                        restoring = true
                        Task { await store.restoreBundled(); await store.bootstrap(); restoring = false }
                    }
                    GlassButton(title: L("執行記錄"), systemImage: "doc.text.magnifyingglass") { showLog = true }
                    Text(L("漫畫源是 venera 格式的 JavaScript 腳本，內建版本在編譯時打包。只安裝你信任的腳本。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("來源管理"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) { NavigationStack { VeneraAddSourceView() } }
        .sheet(isPresented: $showLog) { NavigationStack { VeneraLogView() } }
    }
}

struct VeneraLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines = VeneraLog.shared.all()

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? L("沒有記錄") : lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .themedScreen()
        .navigationTitle(L("執行記錄"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(L("關閉")) { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("清除")) { VeneraLog.shared.clear(); lines = [] }
            }
        }
    }
}

// MARK: - 新增 / 更新

struct VeneraAddSourceView: View {
    @EnvironmentObject private var store: VeneraStore
    @Environment(\.dismiss) private var dismiss

    @State private var indexURL = ""
    @State private var entries: [VeneraIndexEntry] = []
    @State private var loading = false
    @State private var message: String?
    @State private var scriptURL = ""
    @State private var importing = false
    @State private var busyKey: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Panel(title: L("從索引安裝")) {
                    TextField(L("索引網址 (index.json)"), text: $indexURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    GlassButton(title: loading ? L("載入中…") : L("載入清單"), systemImage: "arrow.down.doc") { loadIndex() }
                        .disabled(loading)
                    ForEach(entries.filter { !(SafeMode.isOn && SafeMode.isAdultKey($0.key)) }) { entry in
                        let installed = store.isInstalled(entry.key)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.subheadline.weight(.semibold))
                                Text("v\(entry.version)" + (installed.map { L(" · 已安裝 v%@", "\($0.version)") } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busyKey == entry.id {
                                ProgressView()
                            } else if installed == nil || isNewerVersion(entry.version, than: installed?.version ?? "0") {
                                Button(installed == nil ? L("安裝") : L("更新")) { install(entry) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        Divider()
                    }
                }

                Panel(title: L("從網址或檔案安裝")) {
                    TextField(L("腳本網址 (.js)"), text: $scriptURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    GlassButton(title: L("安裝"), systemImage: "square.and.arrow.down") { installScriptURL() }
                        .disabled(scriptURL.isEmpty)
                    GlassButton(title: L("從檔案匯入"), systemImage: "folder") { importing = true }
                }

                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding(16)
        }
        .themedScreen()
        .navigationTitle(L("新增漫畫源"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("完成")) { dismiss() } } }
        .onAppear { if indexURL.isEmpty { indexURL = store.defaultIndexURL } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let js = try? String(contentsOf: url, encoding: .utf8) else { message = L("無法讀取檔案"); return }
            Task {
                do { let info = try await store.install(js: js); message = L("已安裝 %@", "\(info.name)") }
                catch { message = error.localizedDescription }
            }
        }
    }

    private func loadIndex() {
        loading = true
        message = nil
        Task {
            do { entries = try await store.fetchIndex(indexURL) }
            catch { message = L("載入失敗：%@", "\(error.localizedDescription)") }
            loading = false
        }
    }

    private func install(_ entry: VeneraIndexEntry) {
        busyKey = entry.id
        Task {
            do { try await store.install(entry: entry, indexURL: indexURL); message = L("已安裝 %@", "\(entry.name)") }
            catch { message = L("安裝失敗：%@", "\(error.localizedDescription)") }
            busyKey = nil
        }
    }

    private func installScriptURL() {
        guard let url = URL(string: scriptURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = L("網址無效"); return }
        Task {
            do { try await store.install(from: url); message = L("安裝完成") }
            catch { message = L("安裝失敗：%@", "\(error.localizedDescription)") }
        }
    }
}

// MARK: - 單一漫畫源

struct VeneraSourceDetailView: View {
    let key: String
    @EnvironmentObject private var store: VeneraStore
    @Environment(\.dismiss) private var dismiss

    @State private var logged = false
    @State private var account = ""
    @State private var password = ""
    @State private var cookieValues: [String] = []
    @State private var message: String?
    @State private var busy = false
    @State private var showWeb = false
    @State private var confirmRemove = false
    @State private var hiddenRefresh = 0

    private var info: VeneraInfo? { store.isInstalled(key) }

    var body: some View {
        ScrollView {
            if let info {
                VStack(spacing: 16) {
                    Panel(title: info.name) {
                        Text("v\(info.version)  ·  \(info.key)").font(.caption).foregroundStyle(.secondary)
                        if !info.url.isEmpty { Text(info.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        HStack(spacing: 8) {
                            if !info.explore.isEmpty { badge(L("探索")) }
                            if info.search != nil { badge(L("搜尋")) }
                            if info.category != nil { badge(L("分類")) }
                            if info.favorites != nil { badge(L("收藏")) }
                        }
                    }

                    pagesPanel(info)

                    if let accountInfo = info.account { accountPanel(info, accountInfo) }

                    if !info.settings.isEmpty {
                        Panel(title: L("設定")) {
                            ForEach(info.settings) { setting in VeneraSettingRow(sourceKey: key, setting: setting) }
                        }
                    }

                    Panel(title: nil) {
                        Button(L("移除這個漫畫源"), role: .destructive) { confirmRemove = true }
                    }
                }
                .padding(16)
            }
        }
        .themedScreen()
        .navigationTitle(info?.name ?? key)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            logged = VeneraStorage.shared.isLogged(key)
            cookieValues = Array(repeating: "", count: info?.account?.cookieFields?.count ?? 0)
        }
        .confirmationDialog(L("確定要移除？設定與登入資料也會一併刪除。"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L("移除"), role: .destructive) { store.remove(key: key); dismiss() }
        }
        .sheet(isPresented: $showWeb) {
            if let info, let urlString = info.account?.webviewUrl, let url = URL(string: urlString) {
                VeneraWebLoginSheet(key: key, url: url) { logged = true }
            }
        }
    }

    /// 要在首頁顯示哪些探索頁 / 分類區塊 / 排行
    @ViewBuilder
    private func pagesPanel(_ info: VeneraInfo) -> some View {
        let parts = info.category?.parts.map(\.name).filter { !$0.isEmpty } ?? []
        if !info.explore.isEmpty || !parts.isEmpty || info.ranking != nil {
            Panel(title: L("顯示的頁面")) {
                ForEach(info.explore.map(\.title), id: \.self) { title in pageToggle(L("探索：%@", "\(title)"), item: "explore:\(title)") }
                ForEach(parts, id: \.self) { name in pageToggle(L("分類：%@", "\(name)"), item: "cat:\(name)") }
                if info.ranking != nil { pageToggle(L("排行"), item: "rank") }
            }
        }
    }

    private func pageToggle(_ title: String, item: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !VeneraVisibility.hidden(key).contains(item) },
            set: { VeneraVisibility.setHidden(key, item, !$0); hiddenRefresh += 1 }))
            .id(hiddenRefresh)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).glassCapsule()
    }

    @ViewBuilder
    private func accountPanel(_ info: VeneraInfo, _ accountInfo: VeneraInfo.Account) -> some View {
        Panel(title: L("帳號")) {
            if logged {
                HStack {
                    Label(L("已登入"), systemImage: "checkmark.seal.fill")
                    Spacer()
                    Button(L("登出"), role: .destructive) { logout() }
                }
            } else {
                if accountInfo.hasLogin {
                    TextField(L("帳號"), text: $account)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    SecureField(L("密碼"), text: $password).textFieldStyle(.roundedBorder)
                    GlassButton(title: busy ? L("登入中…") : L("登入"), systemImage: "arrow.right.circle.fill", prominent: true) { login() }
                        .disabled(busy || account.isEmpty || password.isEmpty)
                }
                if accountInfo.webviewUrl != nil {
                    GlassButton(title: L("用網頁登入"), systemImage: "globe") { showWeb = true }
                }
                if let fields = accountInfo.cookieFields, !fields.isEmpty, !accountInfo.hasLogin {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        TextField(field, text: Binding(
                            get: { cookieValues[safe: index] ?? "" },
                            set: { if cookieValues.indices.contains(index) { cookieValues[index] = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    }
                    GlassButton(title: L("驗證 Cookie"), systemImage: "checkmark.shield") { cookieLogin() }
                        .disabled(busy)
                }
                if let register = accountInfo.registerWebsite, let url = URL(string: register) {
                    Link(L("註冊帳號"), destination: url).font(.footnote)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func login() {
        busy = true; message = nil
        let user = account, pass = password
        Task {
            do {
                _ = try await VeneraRuntime.shared.callValue(key, "__login", [user, pass])
                VeneraStorage.shared.setData(key, "account", jsLiteral(user))
                Keychain.set(user, for: "venera.\(key).account")
                Keychain.set(pass, for: "venera.\(key).password")
                logged = true; password = ""
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func cookieLogin() {
        busy = true; message = nil
        let values = cookieValues
        Task {
            do {
                let ok = try await VeneraRuntime.shared.callValue(key, "__cookieLogin", [values]) as? Bool ?? false
                if ok { VeneraStorage.shared.setData(key, "account", jsLiteral(values)); logged = true }
                else { message = L("Cookie 驗證失敗") }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func logout() {
        Task {
            _ = try? await VeneraRuntime.shared.callValue(key, "__logout", [])
            VeneraStorage.shared.deleteData(key, "account")
            Keychain.delete("venera.\(key).account")
            Keychain.delete("venera.\(key).password")
            logged = false
        }
    }
}

private struct VeneraSettingRow: View {
    let sourceKey: String
    let setting: VeneraInfo.Setting

    @State private var text = ""
    @State private var flag = false
    @State private var choice = ""
    @State private var loaded = false
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch setting.type {
            case "switch":
                Toggle(setting.title, isOn: $flag)
                    .onChange(of: flag) { _, value in if loaded { save(jsLiteral(value)) } }
            case "select":
                Picker(setting.title, selection: $choice) {
                    ForEach(setting.options, id: \.value) { Text($0.text).tag($0.value) }
                }
                .pickerStyle(.menu)
                .onChange(of: choice) { _, value in if loaded { save(encodeChoice(value)) } }
            case "callback":
                Button {
                    running = true
                    Task {
                        _ = try? await VeneraRuntime.shared.callValue(sourceKey, "__settingCallback", [setting.name])
                        running = false
                    }
                } label: {
                    HStack {
                        Text(setting.buttonText ?? setting.title)
                        if running { ProgressView() }
                    }
                }
            default:
                Text(setting.title).font(.footnote).foregroundStyle(.secondary)
                TextField(setting.title, text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, value in if loaded { save(jsLiteral(value)) } }
            }
        }
        .onAppear(perform: load)
    }

    private func current() -> Any? {
        let json = VeneraStorage.shared.setting(sourceKey, setting.name) ?? setting.defJSON
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func load() {
        guard !loaded else { return }
        let value = current()
        switch setting.type {
        case "switch": flag = (value as? Bool) ?? false
        case "select":
            if let string = value as? String { choice = string }
            else if let number = value as? NSNumber { choice = number.stringValue }
            else { choice = setting.options.first?.value ?? "" }
        default: text = (value as? String) ?? ""
        }
        loaded = true
    }

    private func encodeChoice(_ value: String) -> String {
        // 預設值是數字時，保持數字型別
        if let defaultJSON = setting.defJSON, let data = defaultJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           object is NSNumber, !(object is Bool), let number = Double(value) {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        return jsLiteral(value)
    }

    private func save(_ json: String) {
        VeneraStorage.shared.setSetting(sourceKey, setting.name, json)
    }
}

// MARK: - 網頁登入

struct VeneraWebLoginSheet: View {
    let key: String
    let url: URL
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        NavigationStack {
            LoginWebView(url: url) { current, title in
                guard !finished else { return }
                Task {
                    let ok = (try? await VeneraRuntime.shared.callValue(key, "__webCheck", [current, title]) as? Bool) ?? false
                    guard ok, !finished else { return }
                    finished = true
                    await syncCookies()
                    _ = try? await VeneraRuntime.shared.callValue(key, "__webSuccess", [])
                    VeneraStorage.shared.setData(key, "account", "true")
                    onSuccess()
                    dismiss()
                }
            }
            .navigationTitle(L("登入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L("取消")) { dismiss() } } }
        }
    }

    @MainActor
    private func syncCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let onFinish: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFinish: (String, String) -> Void
        init(onFinish: @escaping (String, String) -> Void) { self.onFinish = onFinish }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish(webView.url?.absoluteString ?? "", webView.title ?? "")
        }
    }
}

// MARK: - Toast

struct ToastOverlay: View {
    @ObservedObject private var toast = ToastCenter.shared

    var body: some View {
        VStack {
            if let message = toast.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCapsule()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.snappy, value: toast.message)
        .allowsHitTesting(false)
    }
}
