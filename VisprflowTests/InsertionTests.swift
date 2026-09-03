import XCTest
@testable import Visprflow

final class KeycodeResolverTests: XCTestCase {
    func testResolvesVOnTheActiveLayout() throws {
        // On a US QWERTY layout this is 0x09. On Dvorak or AZERTY it is a different keycode,
        // which is the whole point: hardcoding 0x09 pastes the wrong thing on those layouts.
        let code = try XCTUnwrap(KeycodeResolver.keyCode(for: "v"),
                                 "the active layout should expose a keycode for v")
        XCTAssertLessThanOrEqual(code, 50, "letters live in the main alphanumeric block")
    }

    func testResolvesDistinctKeycodesForDistinctLetters() throws {
        let v = try XCTUnwrap(KeycodeResolver.keyCode(for: "v"))
        let a = try XCTUnwrap(KeycodeResolver.keyCode(for: "a"))
        XCTAssertNotEqual(v, a)
    }

    func testUnmappedCharacterReturnsNil() {
        // No standard layout produces this from an unmodified key press.
        XCTAssertNil(KeycodeResolver.keyCode(for: "☃"))
    }

    func testFallbackConstantIsTheQwertyValue() {
        XCTAssertEqual(KeycodeResolver.qwertyV, 0x09)
    }
}

final class UTF16ChunkingTests: XCTestCase {
    func testShortStringIsOneChunk() {
        let chunks = "hello".chunkedUTF16(maxUnits: 16)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(String(utf16CodeUnits: chunks[0], count: chunks[0].count), "hello")
    }

    func testLongStringSplitsAndRejoinsExactly() {
        let text = String(repeating: "abcdefghij", count: 5)
        let chunks = text.chunkedUTF16(maxUnits: 16)
        XCTAssertGreaterThan(chunks.count, 1)
        let rejoined = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
        XCTAssertEqual(rejoined, text)
    }

    func testSurrogatePairsAreNeverSplit() {
        // Each emoji is two UTF-16 units; a naive split would corrupt them.
        let text = String(repeating: "👋🏽", count: 12)
        let chunks = text.chunkedUTF16(maxUnits: 16)
        for chunk in chunks {
            let decoded = String(utf16CodeUnits: chunk, count: chunk.count)
            XCTAssertFalse(decoded.unicodeScalars.contains { $0.value >= 0xD800 && $0.value <= 0xDFFF },
                           "a chunk must never end mid-surrogate")
        }
        let rejoined = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
        XCTAssertEqual(rejoined, text)
    }

    func testChunksRespectTheLimitUnlessOneCharacterExceedsIt() {
        let chunks = "héllo wörld, this is a longer line".chunkedUTF16(maxUnits: 8)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 8)
        }
    }

    func testEmptyStringYieldsNoChunks() {
        XCTAssertTrue("".chunkedUTF16(maxUnits: 16).isEmpty)
    }
}

final class EditLevelTests: XCTestCase {
    func testOrdering() {
        XCTAssertTrue(EditLevel.verbatim < .light)
        XCTAssertTrue(EditLevel.light < .medium)
        XCTAssertTrue(EditLevel.medium < .full)
    }

    func testLoweredStepsDownAndStopsAtVerbatim() {
        XCTAssertEqual(EditLevel.full.lowered, .medium)
        XCTAssertEqual(EditLevel.medium.lowered, .light)
        XCTAssertEqual(EditLevel.light.lowered, .verbatim)
        XCTAssertEqual(EditLevel.verbatim.lowered, .verbatim)
    }

    func testCycleVisitsEveryLevelAndReturns() {
        var level = EditLevel.verbatim
        var seen: [EditLevel] = [level]
        for _ in 0..<3 {
            level = level.cycled
            seen.append(level)
        }
        XCTAssertEqual(seen, [.verbatim, .light, .medium, .full])
        XCTAssertEqual(level.cycled, .verbatim, "the dial wraps around")
    }
}
