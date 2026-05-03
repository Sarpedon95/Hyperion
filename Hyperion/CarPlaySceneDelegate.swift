import CarPlay
import MediaPlayer

// MARK: - CarPlay Scene Delegate
//
// Hyperion presents a simple two-level CarPlay UI:
//
//   Now Playing tab  ──  CPNowPlayingTemplate (always visible)
//   Browse tab       ──  CPListTemplate
//                          └─ Queue (CPListTemplate)
//
// The CPNowPlayingTemplate is registered as the "now playing" template
// so CarPlay's built-in playback controls (play/pause, next, previous,
// scrubber) wire up automatically via MPRemoteCommandCenter – which
// PlayerViewModel already configures.  We don't need to implement any
// button handlers here for those.
//
// CarPlay entitlement requirement:
//   The Xcode target needs the "com.apple.developer.carplay-audio" entitlement
//   (add it in Signing & Capabilities → + Capability → CarPlay → Audio App).
//   Without it the CarPlaySceneDelegate is never instantiated.

@MainActor
final class CarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Register the global Now Playing template so CarPlay knows which
        // app is the active audio source and shows the playback bar.
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled    = true
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
        CPNowPlayingTemplate.shared.add(self)

        // Build the tab bar: Now Playing + Browse
        let tabBar = CPTabBarTemplate(templates: [
            makeNowPlayingTab(),
            makeBrowseTab()
        ])

        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        // Subscribe to player changes so we can refresh the queue list.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerStateChanged),
            name: .hyperionQueueChanged,
            object: nil
        )
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CPNowPlayingTemplate.shared.remove(self)
        NotificationCenter.default.removeObserver(self)
        self.interfaceController = nil
    }

    // MARK: - Template construction

    private func makeNowPlayingTab() -> CPNowPlayingTemplate {
        CPNowPlayingTemplate.shared
    }

    private func makeBrowseTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: "Queue",
            sections: buildQueueSections()
        )
        template.tabTitle  = "Queue"
        template.tabImage  = UIImage(systemName: "list.bullet")
        template.emptyViewTitleVariants       = ["Queue is empty"]
        template.emptyViewSubtitleVariants    = ["Browse your library on your phone to add works."]
        return template
    }

    // MARK: - Queue sections

    private func buildQueueSections() -> [CPListSection] {
        let player = PlayerViewModel.shared

        // Now Playing row
        var sections: [CPListSection] = []

        if let current = player.currentTrack {
            let row = CPListItem(
                text: current.title,
                detailText: current.composer ?? current.albumartist ?? ""
            )
            row.handler = { [weak self] _, completion in
                // Tapping Now Playing switches CarPlay to the Now Playing template.
                self?.interfaceController?.pushTemplate(
                    CPNowPlayingTemplate.shared,
                    animated: true,
                    completion: nil
                )
                completion()
            }
            sections.append(CPListSection(items: [row], header: "Now Playing", sectionIndexTitle: nil))
        }

        // Upcoming work groups
        let upcoming = player.upcomingWorkGroups
        if !upcoming.isEmpty {
            var rows: [CPListItem] = []
            for group in upcoming {
                for item in group.tracks {
                    // POLISH: prefer "Composer · Work" as the detail line so
                    // classical queues show attribution. Fall back to workTitle
                    // alone when no composer is tagged (non-classical albums).
                    let detail: String
                    if let composer = group.composer, !composer.isEmpty {
                        detail = "\(composer) · \(group.workTitle)"
                    } else {
                        detail = group.workTitle
                    }
                    let row = CPListItem(
                        text: item.track.title,
                        detailText: detail
                    )
                    let idx = item.index
                    row.handler = { _, completion in
                        Task { @MainActor in PlayerViewModel.shared.playTrack(at: idx) }
                        completion()
                    }
                    rows.append(row)
                }
            }
            sections.append(CPListSection(items: rows, header: "Up Next", sectionIndexTitle: nil))
        }

        return sections
    }

    // MARK: - Refresh

    @objc private func playerStateChanged() {
        // Find the Browse tab's CPListTemplate and refresh its sections.
        guard let tabBar = interfaceController?.rootTemplate as? CPTabBarTemplate,
              let listTemplate = tabBar.templates.compactMap({ $0 as? CPListTemplate }).first
        else { return }

        listTemplate.updateSections(buildQueueSections())
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Push the queue list when the user taps "Up Next" in the Now Playing template.
        let queue = CPListTemplate(
            title: "Queue",
            sections: buildQueueSections()
        )
        interfaceController?.pushTemplate(queue, animated: true, completion: nil)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by PlayerViewModel when the queue or current track changes.
    static let hyperionQueueChanged = Notification.Name("hyperionQueueChanged")
}
