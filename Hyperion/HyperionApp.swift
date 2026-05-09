import SwiftUI
import UIKit

@main
struct HyperionApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var connection = ConnectionManager.shared
    @StateObject private var player     = PlayerViewModel.shared
    @StateObject private var library    = LibraryViewModel.shared

    init() {
        HyperionApp.configureAppearance()
        // Register custom Audio Units before any AVAudioEngine chain is built.
        CrossfeedAudioUnit.register()
        // Touch singletons at launch so their sessions/observers are registered
        // before any SwiftUI view appears.
        _ = PlayerViewModel.shared
        _ = DownloadManager.shared
        _ = AudiomuseManager.shared
        // ADDED: Task 7 — remove widget artwork files older than 60 days.
        NowPlayingWidgetStore.cleanupOldArtwork()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.roonAccent)
                .onChange(of: scenePhase) { _, newPhase in
                    let phaseName: String
                    switch newPhase {
                    case .active: phaseName = "active"
                    case .inactive: phaseName = "inactive"
                    case .background:
                        phaseName = "background"
                        PlaylistStore.shared.saveNow()
                        LikedTracksStore.shared.saveNow()
                        AppDelegate.scheduleLibraryRefresh() // ADDED: BGAppRefreshTask
                    @unknown default: phaseName = "unknown"
                    }
                    player.handleScenePhaseChange(phaseName)
                }
        }
    }

    // MARK: - UIKit appearance proxies

    private static func configureAppearance() {
        let surface = UIColor(Color.roonSurface)

        // Navigation bar — fully transparent.
        let transparentNav = UINavigationBarAppearance()
        transparentNav.configureWithTransparentBackground()
        transparentNav.backgroundColor          = .clear
        transparentNav.shadowColor              = .clear
        transparentNav.titleTextAttributes      = [.foregroundColor: UIColor.white]
        transparentNav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance   = transparentNav
        UINavigationBar.appearance().scrollEdgeAppearance = transparentNav
        UINavigationBar.appearance().compactAppearance    = transparentNav
        UINavigationBar.appearance().isTranslucent        = true

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = surface
        tab.shadowColor     = .clear
        UITabBar.appearance().standardAppearance   = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        UITableView.appearance().backgroundColor      = .clear
        UITableViewCell.appearance().backgroundColor  = .clear
        UICollectionView.appearance().backgroundColor = .clear
        UIScrollView.appearance().backgroundColor     = .clear
    }
}
