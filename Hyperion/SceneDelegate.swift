import UIKit
import SwiftUI
import BackgroundTasks

// MARK: - App delegate (background URL session handling + BGAppRefreshTask)

final class AppDelegate: NSObject, UIApplicationDelegate {

    // ADDED: BGAppRefreshTask identifier — must be listed in Info.plist under
    // BGTaskSchedulerPermittedIdentifiers for the system to allow scheduling.
    static let libraryRefreshTaskID = "com.sarpedon.hyperion.libraryRefresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // ADDED: register BGAppRefreshTask handler before the app finishes launching.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.libraryRefreshTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                await AppDelegate.handleLibraryRefresh(refreshTask)
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.backgroundSessionID else {
            completionHandler()
            return
        }
        // Store the handler; DownloadManager calls it after all background events are processed.
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }

    // ADDED: schedule a BGAppRefreshTask to fire ~15 minutes after the user backgrounds the app.
    static func scheduleLibraryRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: libraryRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // ADDED: perform a lightweight refresh (recentAlbums + recentlyPlayed only) in the background.
    @MainActor
    private static func handleLibraryRefresh(_ task: BGAppRefreshTask) async {
        // Re-schedule for the next background wake-up before starting work.
        scheduleLibraryRefresh()

        let workTask = Task { @MainActor in
            await LibraryViewModel.shared.loadRecentAlbums(force: true)
            await LibraryViewModel.shared.loadRecentlyPlayed(force: true)
        }
        task.expirationHandler = { workTask.cancel() }
        await workTask.value
        task.setTaskCompleted(success: !workTask.isCancelled)
    }
}

// MARK: - Scene delegate

// SceneDelegate is required when UIApplicationSceneManifest lists a
// UISceneDelegateClassName. SwiftUI's @main App struct handles the
// WindowGroup automatically; this delegate exists only to paint the
// window background so there's never a white flash on launch.

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let ws = scene as? UIWindowScene else { return }
        // SwiftUI already created the window via the App struct.
        // We just ensure the background matches our design tokens
        // so no white strip appears during launch or rotation.
        ws.windows.forEach { $0.backgroundColor = UIColor(Color.roonBase) }
    }
}
