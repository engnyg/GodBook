import LocalAuthentication
import SwiftUI

/// App 鎖：進入背景後再回來需要 Face ID / Touch ID / 密碼。
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var locked: Bool
    @Published var failed = false
    private var authenticating = false

    private init() {
        locked = AppSettings.shared.appLockEnabled
    }

    func lockIfNeeded() {
        if AppSettings.shared.appLockEnabled { locked = true }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false // 裝置沒有設定密碼時無法驗證，避免把使用者鎖在外面
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("解鎖 GodBook"))
            locked = false
            failed = false
        } catch {
            failed = true
        }
    }
}

struct LockOverlay: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text(L("GodBook 已鎖定")).font(.headline)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(L("解鎖"), systemImage: "faceid").padding(.horizontal, 24).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
