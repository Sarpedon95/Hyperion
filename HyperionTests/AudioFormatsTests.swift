import XCTest
@testable import Hyperion

// Tests for AudioFormats — the codec/extension classifier that determines
// quality-pill colour, bit-perfect verification, and signal-path display.
// The lmsCodecExtensionMap is the crown jewel: it stops the "FLAC source +
// FLAC stream" path from being mis-flagged as transcoded just because LMS
// reports the codec as "flc" while the stream URL uses ".flac".

final class AudioFormatsTests: XCTestCase {

    // MARK: - canonicalExtension(forLMSCodec:)

    func testCanonicalExtensionMapsFlcToFlac() {
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "flc"),  "flac")
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "FLC"),  "flac")
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "  flc  "), "flac")
    }

    func testCanonicalExtensionMapsAlcToAlac() {
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "alc"), "alac")
    }

    func testCanonicalExtensionMapsAifToAiff() {
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "aif"), "aiff")
    }

    func testCanonicalExtensionMapsPcmToWav() {
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "pcm"), "wav")
    }

    func testCanonicalExtensionPassesThroughUnknown() {
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "mp3"),  "mp3")
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "FLAC"), "flac")
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: "abc"),  "abc")
        XCTAssertEqual(AudioFormats.canonicalExtension(forLMSCodec: ""),     "")
    }

    // MARK: - isLossless(_:)

    func testIsLosslessExtension() {
        XCTAssertTrue(AudioFormats.isLossless("FLAC"))
        XCTAssertTrue(AudioFormats.isLossless("flac"))   // case-insensitive
        XCTAssertTrue(AudioFormats.isLossless("WAV"))
        XCTAssertTrue(AudioFormats.isLossless("AIF"))
        XCTAssertTrue(AudioFormats.isLossless("ALAC"))
        XCTAssertFalse(AudioFormats.isLossless("MP3"))
        XCTAssertFalse(AudioFormats.isLossless("AAC"))
        XCTAssertFalse(AudioFormats.isLossless(""))
    }

    // MARK: - isLosslessCodec(_:) / isLossyCodec(_:)

    func testIsLosslessCodecAcceptsLMSAbbreviations() {
        XCTAssertTrue(AudioFormats.isLosslessCodec("flc"))   // FLAC's LMS code
        XCTAssertTrue(AudioFormats.isLosslessCodec("alc"))   // ALAC's LMS code
        XCTAssertTrue(AudioFormats.isLosslessCodec("flac"))
        XCTAssertTrue(AudioFormats.isLosslessCodec("WAV"))   // case-insensitive
    }

    func testIsLossyCodecCommon() {
        XCTAssertTrue(AudioFormats.isLossyCodec("mp3"))
        XCTAssertTrue(AudioFormats.isLossyCodec("aac"))
        XCTAssertTrue(AudioFormats.isLossyCodec("ogg"))
        XCTAssertTrue(AudioFormats.isLossyCodec("opus"))
        XCTAssertFalse(AudioFormats.isLossyCodec("flac"))
        XCTAssertFalse(AudioFormats.isLossyCodec(""))
    }

    func testLosslessAndLossySetsDisjoint() {
        for codec in ["flac", "flc", "wav", "alac", "alc", "aiff"] {
            XCTAssertTrue(AudioFormats.isLosslessCodec(codec))
            XCTAssertFalse(AudioFormats.isLossyCodec(codec), "\(codec) should not be lossy")
        }
        for codec in ["mp3", "aac", "m4a", "ogg", "opus"] {
            XCTAssertTrue(AudioFormats.isLossyCodec(codec))
            XCTAssertFalse(AudioFormats.isLosslessCodec(codec), "\(codec) should not be lossless")
        }
    }
}

// MARK: - TimeFormatting

final class TimeFormattingTests: XCTestCase {

    func testNilReturnsPlaceholder() {
        XCTAssertEqual(TimeFormatting.formatDuration(nil), "")
        XCTAssertEqual(TimeFormatting.formatDuration(nil, placeholder: "—"), "—")
    }

    func testNegativeReturnsPlaceholder() {
        XCTAssertEqual(TimeFormatting.formatDuration(-1), "")
    }

    func testInfiniteReturnsPlaceholder() {
        XCTAssertEqual(TimeFormatting.formatDuration(.infinity), "")
        XCTAssertEqual(TimeFormatting.formatDuration(.nan), "")
    }

    func testUnderOneHour() {
        XCTAssertEqual(TimeFormatting.formatDuration(0),    "0:00")
        XCTAssertEqual(TimeFormatting.formatDuration(5),    "0:05")
        XCTAssertEqual(TimeFormatting.formatDuration(65),   "1:05")
        XCTAssertEqual(TimeFormatting.formatDuration(599),  "9:59")
        XCTAssertEqual(TimeFormatting.formatDuration(3599), "59:59")
    }

    func testOneHourAndAbove() {
        XCTAssertEqual(TimeFormatting.formatDuration(3600),  "1:00:00")
        XCTAssertEqual(TimeFormatting.formatDuration(3661),  "1:01:01")
        XCTAssertEqual(TimeFormatting.formatDuration(7200),  "2:00:00")
        XCTAssertEqual(TimeFormatting.formatDuration(36000), "10:00:00")
    }
}
