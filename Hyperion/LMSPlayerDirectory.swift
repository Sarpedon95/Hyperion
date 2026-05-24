import Foundation
import SwiftUI

// MARK: - LMSPlayerDirectory (audit phase 7)
//
// Discovers LMS hardware players (Squeezebox, piCorePlayer, SqueezeLite, etc.)
// on the connected server, tracks which one the user has selected as the
// "target" device, and exposes transport helpers that route commands to
// the selected device via slim.request.
//
// IMPORTANT — design boundary:
//   Hyperion's primary audio engine plays on-device via AVPlayer/Orpheus.
//   This directory is an additive *control* surface — when a remote player
//   is selected, transport commands additionally fire on that player so
//   the hardware in another room reacts. We do NOT redirect Hyperion's
//   local audio output away from the phone. Routing the local audio
//   pipeline to LMS is a much larger refactor and is left out of this
//   phase deliberately.
//
//   Sync-group support is not implemented yet; it requires the "sync"
//   slim.request command and a multi-select UI. Tracked as a follow-up.

@MainActor
final class LMSPlayerDirectory: ObservableObject {

    static let shared = LMSPlayerDirectory()

    @Published private(set) var players: [LMSPlayer] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published var lastError: String? = nil

    /// User-selected target player. `nil` means "phone only" (the default).
    @Published var selectedPlayerID: String? = {
        UserDefaults.standard.string(forKey: Keys.selectedPlayerID)
    }() {
        didSet {
            if let id = selectedPlayerID, !id.isEmpty {
                UserDefaults.standard.set(id, forKey: Keys.selectedPlayerID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedPlayerID)
            }
        }
    }

    private enum Keys {
        static let selectedPlayerID = "hyperion.lms.selectedPlayerID"
    }

    private var refreshTask: Task<Void, Never>?

    private init() {}

    var selectedPlayer: LMSPlayer? {
        guard let id = selectedPlayerID else { return nil }
        return players.first { $0.id == id }
    }

    var isRoutingToHardware: Bool { selectedPlayer != nil }

    // MARK: - Discovery

    /// Refresh the player list. Coalesces concurrent callers via refreshTask.
    func refresh() async {
        if let inFlight = refreshTask { await inFlight.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            let fetched = await LyrionAPI.shared.getPlayers()
            self.players = fetched
            // If the previously-selected player has vanished from the server
            // (renamed/removed), clear the selection so transport commands
            // don't silently target a phantom ID.
            if let id = self.selectedPlayerID,
               !fetched.contains(where: { $0.id == id }) {
                self.selectedPlayerID = nil
            }
            self.lastError = nil
        }
        refreshTask = task
        defer { refreshTask = nil }
        await task.value
    }

    // MARK: - Transport routing
    //
    // These helpers mirror the local player's transport surface. When
    // selectedPlayer is non-nil they fire the matching slim.request on the
    // remote device; otherwise they no-op (caller continues to use the
    // local AVPlayer/Orpheus path as before).

    @discardableResult
    func remotePlayPause() async -> Bool {
        guard let id = selectedPlayerID else { return false }
        // LMS has no toggle command; query status first would be nice but is
        // an extra round-trip. The "pause" command (without arg) acts as a
        // toggle on most LMS players, which is the desired behaviour here.
        return await LyrionAPI.shared.playerPause(playerID: id)
    }

    @discardableResult
    func remotePlay() async -> Bool {
        guard let id = selectedPlayerID else { return false }
        return await LyrionAPI.shared.playerPlay(playerID: id)
    }

    @discardableResult
    func remoteStop() async -> Bool {
        guard let id = selectedPlayerID else { return false }
        return await LyrionAPI.shared.playerStop(playerID: id)
    }

    @discardableResult
    func remoteNext() async -> Bool {
        guard let id = selectedPlayerID else { return false }
        return await LyrionAPI.shared.playerNext(playerID: id)
    }

    @discardableResult
    func remotePrevious() async -> Bool {
        guard let id = selectedPlayerID else { return false }
        return await LyrionAPI.shared.playerPrevious(playerID: id)
    }

    /// Volume in 0…1; converted to LMS's 0…100 scale.
    @discardableResult
    func remoteSetVolume(_ value: Float) async -> Bool {
        guard let id = selectedPlayerID else { return false }
        let v = Int((max(0, min(1, value)) * 100).rounded())
        return await LyrionAPI.shared.playerSetVolume(playerID: id, volume0to100: v)
    }

    @discardableResult
    func remoteSetPower(_ on: Bool) async -> Bool {
        guard let id = selectedPlayerID else { return false }
        return await LyrionAPI.shared.playerSetPower(playerID: id, on: on)
    }
}

// MARK: - LMSPlayerPickerView (Settings sheet UI)

struct LMSPlayerPickerView: View {

    @ObservedObject private var directory = LMSPlayerDirectory.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Haptics.light()
                        directory.selectedPlayerID = nil
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundColor(.roonAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("This iPhone")
                                    .font(.roonBody(15, weight: .medium))
                                    .foregroundColor(.roonPrimary)
                                Text("Play on-device with Orpheus DSP")
                                    .font(.roonBody(12))
                                    .foregroundColor(.roonSecondary)
                            }
                            Spacer()
                            if directory.selectedPlayerID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.roonAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }

                if !directory.players.isEmpty {
                    Section("LMS players") {
                        ForEach(directory.players) { player in
                            Button {
                                Haptics.light()
                                directory.selectedPlayerID = player.id
                            } label: {
                                HStack {
                                    Image(systemName: player.isConnected ? "hifispeaker.fill" : "hifispeaker")
                                        .foregroundColor(player.isConnected ? .roonAccent : .roonTertiary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(player.name)
                                            .font(.roonBody(15, weight: .medium))
                                            .foregroundColor(.roonPrimary)
                                        HStack(spacing: 6) {
                                            if let m = player.model { Text(m) }
                                            if !player.isConnected {
                                                Text("· offline").foregroundColor(.red.opacity(0.8))
                                            }
                                        }
                                        .font(.roonBody(12))
                                        .foregroundColor(.roonSecondary)
                                    }
                                    Spacer()
                                    if directory.selectedPlayerID == player.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.roonAccent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .disabled(!player.isConnected)
                        }
                    }
                }

                if directory.players.isEmpty && !directory.isRefreshing {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "hifispeaker.2")
                                .font(.system(size: 36))
                                .foregroundColor(.roonTertiary)
                            Text("No LMS players found")
                                .font(.roonBody(15, weight: .medium))
                                .foregroundColor(.roonPrimary)
                            Text("Connect a Squeezebox / piCorePlayer / SqueezeLite endpoint to your LMS server, then refresh.")
                                .font(.roonBody(12))
                                .foregroundColor(.roonSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase)
            .navigationTitle("Play to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.roonAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await directory.refresh() }
                    } label: {
                        if directory.isRefreshing {
                            ProgressView().tint(.roonAccent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.roonAccent)
                        }
                    }
                    .disabled(directory.isRefreshing)
                }
            }
            .task { await directory.refresh() }
        }
    }
}
