import XCTest
@testable import Hyperion

// Tests for HyperionServerURL — the URL normalisation + candidate generator
// that underpins every connection mode. These exercise the "user pastes
// something approximate" paths users actually hit.

final class HyperionServerURLTests: XCTestCase {

    // MARK: - sanitizedBase

    func testSanitizedBaseAddsScheme() {
        XCTAssertEqual(HyperionServerURL.sanitizedBase("192.168.1.100:9000"),
                       "http://192.168.1.100:9000")
    }

    func testSanitizedBaseStripsJsonrpcEndpoint() {
        // Users often paste the full /jsonrpc.js URL from a Lyrion error message.
        XCTAssertEqual(HyperionServerURL.sanitizedBase("http://10.0.0.5:9000/jsonrpc.js"),
                       "http://10.0.0.5:9000")
    }

    func testSanitizedBaseTrimsWhitespace() {
        XCTAssertEqual(HyperionServerURL.sanitizedBase("  http://10.0.0.5:9000  "),
                       "http://10.0.0.5:9000")
    }

    func testSanitizedBaseEmptyStaysEmpty() {
        XCTAssertEqual(HyperionServerURL.sanitizedBase(""), "")
        XCTAssertEqual(HyperionServerURL.sanitizedBase("   "), "")
    }

    func testSanitizedBaseHTTPSPreserved() {
        XCTAssertEqual(HyperionServerURL.sanitizedBase("https://lyrion.example.com"),
                       "https://lyrion.example.com")
    }

    // MARK: - candidateBases

    func testCandidatesForBareLANHost() {
        let cands = HyperionServerURL.candidateBases(for: "192.168.1.100", mode: .local)
        // Should include http://host:9000 and http://host (in some order).
        XCTAssertTrue(cands.contains("http://192.168.1.100:9000"))
        XCTAssertTrue(cands.contains("http://192.168.1.100"))
    }

    func testCandidatesForBareTailscaleHost() {
        let cands = HyperionServerURL.candidateBases(for: "100.64.1.1", mode: .tailscale)
        XCTAssertTrue(cands.contains("http://100.64.1.1:9000"))
    }

    func testCandidatesForProxyDomainPrefersHTTPS() {
        let cands = HyperionServerURL.candidateBases(for: "lyrion.example.com", mode: .proxy)
        XCTAssertEqual(cands.first, "https://lyrion.example.com")
    }

    func testCandidatesPreserveExplicitScheme() {
        let cands = HyperionServerURL.candidateBases(for: "http://10.0.0.5:9000")
        // First candidate must be the exact user input (stripped of any
        // trailing /jsonrpc.js, none here).
        XCTAssertEqual(cands.first, "http://10.0.0.5:9000")
    }

    func testCandidatesEmptyForEmptyInput() {
        XCTAssertEqual(HyperionServerURL.candidateBases(for: ""), [])
        XCTAssertEqual(HyperionServerURL.candidateBases(for: "   "), [])
    }

    func testCandidatesAreUnique() {
        let cands = HyperionServerURL.candidateBases(for: "192.168.1.1:9000")
        XCTAssertEqual(cands, Array(NSOrderedSet(array: cands)) as? [String])
    }

    // MARK: - connectionKind

    func testConnectionKindLocalRFC1918() {
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "192.168.1.5"), .local)
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "10.0.0.1"),    .local)
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "172.16.0.1"),  .local)
    }

    func testConnectionKindLocalMDNS() {
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "squeezebox.local"), .local)
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "lyrion.local"),     .local)
    }

    func testConnectionKindTailscale() {
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "100.64.1.5"), .tailscale)
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "100.127.0.1"), .tailscale)
    }

    func testConnectionKindRemote() {
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "lyrion.example.com"), .remote)
        XCTAssertEqual(HyperionServerURL.connectionKind(for: "https://music.tld"),  .remote)
    }

    // MARK: - redactedDisplay

    func testRedactedDisplayNoSet() {
        XCTAssertEqual(HyperionServerURL.redactedDisplay(""), "not set")
    }
}
