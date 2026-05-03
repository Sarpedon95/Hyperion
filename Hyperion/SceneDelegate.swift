import UIKit
import SwiftUI

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
