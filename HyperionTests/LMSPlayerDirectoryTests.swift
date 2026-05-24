import XCTest
@testable import Hyperion

// Tests for the LMS hardware-player surface added in audit phase 7.
// Covers the LMSPlayer model + the directory's selection persistence and
// "phantom player" guard. Network discovery is not exercised here (it
// requires a live LMS server); LyrionAPI.getPlayers parsing is left for a
// dedicated integration test.

final class LMSPlayerTests: XCTestCase {

    func testLMSPlayerIsCodableRoundTrip() throws {
        let original = LMSPlayer(
            id: "00:04:20:aa:bb:cc",
            name: "Living Room",
            model: "squeezelite",
            isConnected: true,
            isPoweredOn: true,
            canPowerOff: false,
            ip: "192.168.1.50"
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LMSPlayer.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.isConnected, original.isConnected)
    }

    func testLMSPlayerIdentityHash() {
        let a = LMSPlayer(id: "a", name: "A", model: nil, isConnected: true,
                          isPoweredOn: true, canPowerOff: false, ip: nil)
        let b = LMSPlayer(id: "a", name: "A", model: nil, isConnected: true,
                          isPoweredOn: true, canPowerOff: false, ip: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}

@MainActor
final class LMSPlayerDirectoryTests: XCTestCase {

    override func setUp() async throws {
        // Clear any persisted selection from prior test runs so each test
        // starts with "This iPhone" selected.
        UserDefaults.standard.removeObject(forKey: "hyperion.lms.selectedPlayerID")
        LMSPlayerDirectory.shared.selectedPlayerID = nil
    }

    func testDefaultsToPhoneOnly() {
        XCTAssertNil(LMSPlayerDirectory.shared.selectedPlayerID)
        XCTAssertFalse(LMSPlayerDirectory.shared.isRoutingToHardware)
        XCTAssertNil(LMSPlayerDirectory.shared.selectedPlayer)
    }

    func testSelectingPlayerPersistsToUserDefaults() {
        LMSPlayerDirectory.shared.selectedPlayerID = "00:11:22:33:44:55"
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "hyperion.lms.selectedPlayerID"),
            "00:11:22:33:44:55"
        )
    }

    func testClearingSelectionRemovesFromUserDefaults() {
        LMSPlayerDirectory.shared.selectedPlayerID = "abc"
        LMSPlayerDirectory.shared.selectedPlayerID = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: "hyperion.lms.selectedPlayerID"))
    }

    func testRemoteCommandsNoOpWhenPhoneSelected() async {
        LMSPlayerDirectory.shared.selectedPlayerID = nil
        // All transport helpers must return false (no-op) when no remote
        // player is selected — i.e., they never silently fire on a
        // previously-selected device after the user picked "This iPhone".
        let results = await [
            LMSPlayerDirectory.shared.remotePlayPause(),
            LMSPlayerDirectory.shared.remotePlay(),
            LMSPlayerDirectory.shared.remoteStop(),
            LMSPlayerDirectory.shared.remoteNext(),
            LMSPlayerDirectory.shared.remotePrevious(),
            LMSPlayerDirectory.shared.remoteSetVolume(0.5),
            LMSPlayerDirectory.shared.remoteSetPower(true),
        ]
        for r in results { XCTAssertFalse(r) }
    }
}
