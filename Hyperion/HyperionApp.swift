import SwiftUI
import UIKit

@main
struct HyperionApp: App {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var connection = ConnectionManager.shared
    @StateObject private var player     = PlayerViewModel.shared
    @StateObject private var library    = LibraryViewModel.shared

    init() {
        HyperionApp.configureAppearance()
        // Touch the shared player at app launch so the persistent AVPlayer,
        // playback audio session, remote commands, and lifecycle observers are
        // registered before any SwiftUI view can be refreshed or dismissed.
        _ = PlayerViewModel.shared
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
                    case .background: phaseName = "background"
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
