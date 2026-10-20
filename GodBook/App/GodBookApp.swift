import SwiftUI

@main
struct GodBookApp: App {
    @StateObject private var theme = ThemeStore()
    @StateObject private var library = LibraryStore()
    @ObservedObject private var settings = AppSettings.shared
    private let downloads = DownloadManager.shared
    private let venera = VeneraStore.shared
    private let readerPrefs = ReaderPrefsStore.shared
    private let imageFavorites = ImageFavoritesStore.shared
    private let favoritesStore = FavoritesStore.shared
    private let followStore = FollowStore.shared
    private let localLibrary = LocalLibrary.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(settings.language)
                .environment(\.locale, Language.locale)
                .environmentObject(theme)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(venera)
                .environmentObject(readerPrefs)
                .environmentObject(imageFavorites)
                .environmentObject(favoritesStore)
                .environmentObject(followStore)
                .environmentObject(localLibrary)
                .tint(theme.accent)
                .preferredColorScheme(theme.preferredScheme)
                .onOpenURL { DeepLink.shared.handle($0) }
                .overlay {
                    // 鎖定中，或 App 鎖開啟時在多工畫面遮住內容
                    if lock.locked || (settings.appLockEnabled && scenePhase != .active) { LockOverlay() }
                }
                .task {
                    DispatchQueue.global(qos: .utility).async { ImageDiskCache.trim() }
                    if lock.locked { await lock.unlock() }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        library.flush()
                        lock.lockIfNeeded()
                        if settings.webdavAutoUpload, !settings.webdavURL.isEmpty { backgroundUpload() }
                    case .active:
                        if lock.locked { Task { await lock.unlock() } }
                    default: break
                    }
                }
        }
    }

    private func backgroundUpload() {
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(taskId) }
        Task {
            try? await WebDAV.upload()
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }
}
