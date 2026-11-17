import XCTest
@testable import KeytideCore

final class PhysicalKeyMappingTests: XCTestCase {
    func testPhysicalAndUnsupportedParticipationsSaturateAcrossChords() {
        let result = PhysicalKeyMapping.map(["A": Int.max, "Cmd+A": 1,
            "Key160": Int.max, "Cmd+Key160": 1])
        XCTAssertEqual(result.counts["A"], Int.max)
        XCTAssertEqual(result.counts["Cmd"], 2)
        XCTAssertEqual(result.unsupported["Key160"], Int.max)
    }

    func testMediaDisplayCombinesCountsWithoutChangingPhysicalMappingOrHistory() {
        let input = ["F2": 3, "BrightnessUp": 7, "VolumeUp": 4, "PlayPause": 2,
                     "PreviousTrack": 5, "Rewind": 1, "KeyboardBrightnessUp": 9, "Key160": 2]
        let display = PhysicalKeyMapping.mapForDisplay(input)
        XCTAssertEqual(display.counts, ["F2": 10, "F12": 4, "F8": 2, "F7": 6])
        XCTAssertEqual(display.mediaCounts, ["F2": 7, "F12": 4, "F8": 2, "F7": 6])
        XCTAssertEqual(display.unsupported, ["KeyboardBrightnessUp": 9, "Key160": 2])
        XCTAssertEqual(PhysicalKeyMapping.map(input).counts, ["F2": 3])
        XCTAssertEqual(input["F2"], 3)
        for id in ["F3", "F4", "F5", "F6"] {
            XCTAssertNil(display.counts[id])
            XCTAssertFalse(PhysicalKeyMapping.hasMediaDisplayKey(id))
        }
    }

    func testMediaDisplaySaturatesAndDoesNotAssignUnsupportedSystemActions() {
        let display = PhysicalKeyMapping.mapForDisplay(["F12": Int.max, "VolumeUp": 1,
            "MissionControl": 5, "Dictation": 2, "Spotlight": 8, "Focus": 3])
        XCTAssertEqual(display.counts["F12"], Int.max)
        XCTAssertEqual(display.mediaCounts["F12"], 1)
        XCTAssertEqual(display.unsupported, ["MissionControl": 5, "Dictation": 2, "Spotlight": 8, "Focus": 3])
    }

    func testOrdinaryKeysAndPunctuation() {
        let keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)
            + ["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
               "Space", "Return", "Delete", "Esc", "Tab", "CapsLock",
               "Left", "Right", "Up", "Down", "Fn", "Ctrl"]
            + (1...12).map { "F\($0)" }
        let input = Dictionary(uniqueKeysWithValues: keys.map { ($0, 3) })
        XCTAssertEqual(PhysicalKeyMapping.map(input),
                       PhysicalKeyMappingResult(counts: input, unsupported: [:]))
    }

    func testCombinationsPreserveSidesAndGenericModifiers() {
        for modifier in ["Shift", "Cmd", "LeftCmd", "RightCmd", "LeftShift",
                         "RightShift", "Option", "LeftOption", "RightOption", "Ctrl", "Fn"] {
            let result = PhysicalKeyMapping.map(["\(modifier)+C": 4])
            XCTAssertEqual(result.counts, [modifier: 4, "C": 4])
            XCTAssertTrue(result.unsupported.isEmpty)
        }
        XCTAssertEqual(PhysicalKeyMapping.map(["Shift+A": 2]).counts, ["Shift": 2, "A": 2])
        XCTAssertEqual(PhysicalKeyMapping.map(["Cmd+C": 1, "LeftCmd+C": 2, "RightCmd+C": 3]).counts,
                       ["Cmd": 1, "LeftCmd": 2, "RightCmd": 3, "C": 6])
    }

    func testPlusAndCombinationParticipationDoNotChangeInput() {
        let input = ["+": 1, "Cmd++": 2, "Shift++": 3, "Cmd+Shift++": 4]
        XCTAssertEqual(PhysicalKeyMapping.map(input).counts, ["=": 10, "Cmd": 6, "Shift": 7])
        XCTAssertEqual(input["Cmd++"], 2)
        XCTAssertEqual(keyBreakdownDisplayCounts(from: input), input)
    }

    func testUnsupportedComponentsAreRetainedWithoutGuessing() {
        let keys = (13...19).map { "F\($0)" }
            + ["Home", "End", "PageUp", "PageDown", "ForwardDelete", "Enter",
               "BrightnessUp", "VolumeUp", "PlayPause", "Key160"]
        let input = Dictionary(uniqueKeysWithValues: keys.map { ($0, 2) })
        XCTAssertEqual(PhysicalKeyMapping.map(input),
                       PhysicalKeyMappingResult(counts: [:], unsupported: input))
        let mixed = PhysicalKeyMapping.map(["Cmd+Key160": 3, "F2": 1, "BrightnessUp": 2])
        XCTAssertEqual(mixed.counts, ["Cmd": 3, "F2": 1])
        XCTAssertEqual(mixed.unsupported, ["Key160": 3, "BrightnessUp": 2])
    }

    func testNonpositiveCountsAreIgnored() {
        let result = PhysicalKeyMapping.map(["A": -1, "C": 0, "Cmd+C": 2,
                                             "Key160": -3, "VolumeUp": 0])
        XCTAssertEqual(result.counts, ["Cmd": 2, "C": 2])
        XCTAssertTrue(result.unsupported.isEmpty)
    }

    func testAliasesAndInsertionOrderAreStable() {
        let pairs = [("Function+A", 2), ("LeftCommand+C", 3), ("Cmd++", 4),
                     ("Spacebar", 1), ("Backspace", 2), ("ArrowLeft", 3), ("Key160", 2)]
        let forward = Dictionary(uniqueKeysWithValues: pairs)
        let reverse = Dictionary(uniqueKeysWithValues: pairs.reversed())
        let expected = PhysicalKeyMappingResult(
            counts: ["Fn": 2, "A": 2, "LeftCmd": 3, "C": 3, "Cmd": 4,
                     "=": 4, "Space": 1, "Delete": 2, "Left": 3],
            unsupported: ["Key160": 2])
        XCTAssertEqual(PhysicalKeyMapping.map(forward), expected)
        XCTAssertEqual(PhysicalKeyMapping.map(reverse), expected)
        XCTAssertEqual(keyboardHeatmapCounts(from: forward), expected.counts)
    }
}
