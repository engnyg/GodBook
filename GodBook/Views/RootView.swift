import SwiftUI

struct RootView: View {
    /// 切換語言時整個畫面會重建；記住目前的分頁，切完仍停在原本的分頁（例如設定）
    private static var lastTab: Int?
    @State private var tab = RootView.lastTab ?? AppSettings.shared.initialTab
    @State private var homePath = NavigationPath()
    @ObservedObject private var deepLink = DeepLink.shared
    @ObservedObject private var settings = AppSettings.shared

    private var showLibrary: Bool { !(settings.safeMode && settings.safeHideLibrary) }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $homePath) {
                HomeView(path: $homePath)
                    .comicDestinations()
            }
            .tabItem { Label(L("探索"), systemImage: "square.grid.2x2.fill") }
            .tag(0)

            if showLibrary {
                NavigationStack {
                    LibraryView()
                        .comicDestinations()
                }
                .tabItem { Label(L("書庫"), systemImage: "books.vertical.fill") }
                .tag(1)
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(L("設定"), systemImage: "slider.horizontal.3") }
            .tag(2)
        }
        .overlay { ToastOverlay() }
        .onChange(of: tab) { _, value in RootView.lastTab = value }
        .onChange(of: showLibrary) { _, shown in if !shown && tab == 1 { tab = 0 } }
        .onChange(of: deepLink.summary) { _, value in if value != nil { tab = 0 } }
        .task {
            DownloadManager.shared.resumeQueued()
            CloudSync.shared.start()
            await VeneraStore.shared.bootstrap()
            await FollowStore.shared.checkIfDue(favorites: FavoritesStore.shared)
        }
    }
}

extension View {
    /// 註冊詳情頁與標籤搜尋頁的導覽目的地。
    func comicDestinations() -> some View {
        navigationDestination(for: ComicSummary.self) { DetailView(summary: $0) }
            .navigationDestination(for: SearchRoute.self) { SearchResultsView(route: $0) }
            .navigationDestination(for: AggregatedRoute.self) { AggregatedSearchView(query: $0.query) }
            .navigationDestination(for: CategoriesRoute.self) { CategoriesView(source: $0.source) }
    }
}
