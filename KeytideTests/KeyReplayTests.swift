import XCTest
import CryptoKit
@testable import KeytideCore

final class KeyReplayTests: XCTestCase {
    func testDailyPlaybackCompressesAWholeDayWithoutChangingSourceRecords() {
        let entries: [KeyReplayDay.Entry] = (0..<12_000).map { index in
            let time = Double(index) * 2
            return .init(seconds: time,
                event: .init(milliseconds: UInt64(index) * 2000, ordinal: UInt64(index),
                    keyCode: [UInt16(0), 38, 1, 34, 1, 4][(index / 2) % 6],
                    phase: index % 2 == 0 ? .down : .up,
                    growthKeys: index % 2 == 0 ? ["A"] : []), startsSession: index == 0)
        }
        let day = KeyReplayDay(entries: entries, hasUnreadableChunks: false)
        let plan = GrowthReplayPressPlan(day: day)
        XCTAssertTrue(plan.isAccelerated)
        XCTAssertEqual(plan.entries.last!.seconds, 8, accuracy: 0.000_001)
        XCTAssertLessThan(plan.duration(profile: .deep), 8.3)
        XCTAssertEqual(plan.entries.map(\.event), entries.map(\.event), "Keep every repeated press, release and original millisecond timestamp")
        XCTAssertEqual(plan.entries.map(\.startsSession), entries.map(\.startsSession))
        XCTAssertEqual(plan.entries.map(\.seconds), plan.entries.map(\.seconds).sorted())
        XCTAssertEqual(day.entries.last!.seconds, 23_998, "The source timeline is immutable")
    }

    func testLongIdleGapsAreShortenedAndSmallDaysNeverGetSlowedDown() {
        let events = batch([0, 1]).events
        let day = KeyReplayDay(entries: [
            .init(seconds: 0, event: events[0], startsSession: true),
            .init(seconds: 0.03, event: events[1], startsSession: false),
            .init(seconds: 3600, event: events[2], startsSession: true),
            .init(seconds: 3600.03, event: events[3], startsSession: false)
        ], hasUnreadableChunks: false)
        let plan = GrowthReplayPressPlan(day: day)
        XCTAssertEqual(plan.entries[2].seconds - plan.entries[1].seconds, 0.12, accuracy: 0.000_001)
        XCTAssertLessThan(plan.duration(profile: .deep), 1)
        let short = KeyReplayDay(entries: Array(day.entries.prefix(2)), hasUnreadableChunks: false)
        XCTAssertEqual(GrowthReplayPressPlan(day: short).entries.map(\.seconds), short.entries.map(\.seconds))
        XCTAssertFalse(GrowthReplayPressPlan(day: short).isAccelerated)
    }

    func testExamplePacingFitsFiveToSixSecondsAndKeepsRepeatedKeys() {
        let example = KeyReplayExample.make()
        let plan = GrowthReplayPressPlan(day: example.day)
        XCTAssertEqual(Array(plan.ids.prefix(6)), ["A", "J", "S", "I", "S", "H"])
        XCTAssertEqual(plan.entries.count, example.day.entries.count)
        XCTAssertGreaterThanOrEqual(plan.duration(profile: .light), 5)
        XCTAssertLessThan(plan.duration(profile: .deep), 6)
    }

    func testBuiltInExampleHasRealEventOrderAndMatchingSyntheticCounts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_794_700_800)
        let example = KeyReplayExample.make(now: now, calendar: calendar)
        let plan = GrowthReplayPressPlan(day: example.day)
        XCTAssertEqual(Array(plan.ids.prefix(6)), ["A", "J", "S", "I", "S", "H"])
        XCTAssertEqual(plan.ids.count, 23)
        XCTAssertEqual(example.day.entries.count, 46)
        XCTAssertLessThan(plan.duration(profile: .deep), 10)
        XCTAssertEqual(example.day.entries.map(\.seconds), example.day.entries.map(\.seconds).sorted())
        let before = example.presentation.frame(at: 0), after = example.presentation.frame(at: 1)
        XCTAssertEqual(after.snapshot.totalKeyPresses - before.snapshot.totalKeyPresses, 23)
        let frequencies = Dictionary(plan.ids.map { ($0, 1) }, uniquingKeysWith: +)
        for (key, count) in frequencies {
            XCTAssertEqual((after.snapshot.keyPressCounts[key] ?? 0) - (before.snapshot.keyPressCounts[key] ?? 0), count)
        }
        XCTAssertEqual(example.recordedDayKey, after.dayKey)
        XCTAssertEqual(example.presentation.dayCount, 2)
    }

    private func batch(_ codes: [UInt16] = [0, 38, 1, 34, 1, 4]) -> KeyReplayBatch {
        var session = KeyReplaySession(startedAt: Date(timeIntervalSince1970: 100), originNanoseconds: 1_000_000_000)
        let events = codes.enumerated().flatMap { index, code -> [KeyReplayEvent] in
            let time = UInt64(index) * 100_000_000 + 1_000_000_000
            return [session.event(nanoseconds: time, keyCode: code, phase: .down, growthKeys: [])!,
                    session.event(nanoseconds: time + 30_000_000, keyCode: code, phase: .up, growthKeys: [])!]
        }
        return KeyReplayBatch(version: 1, session: session.id, startedAt: session.startedAt, events: events)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keytide-ReplayTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPreservesActualOrderRepeatedKeysAndMillisecondSpacing() {
        let day = KeyReplayDay(batches: [batch()])
        let plan = GrowthReplayPressPlan(day: day)
        XCTAssertEqual(plan.ids, ["A", "J", "S", "I", "S", "H"])
        XCTAssertEqual(day.entries.map(\.event.phase), Array(repeating: [KeyReplayEvent.Phase.down, .up], count: 6).flatMap { $0 })
        XCTAssertEqual(day.entries[3].seconds, 0.130, accuracy: 0.000_001)
        XCTAssertEqual(day.entries.last!.seconds, 0.530, accuracy: 0.000_001)
    }
    func testTimestampUsesSourceClockAndOrdinalBreaksSameMillisecondTies() {
        var session = KeyReplaySession(startedAt: Date(), originNanoseconds: 1_000_000)
        let a = session.event(nanoseconds: 1_000_001, keyCode: 0, phase: .down, growthKeys: ["A"])!
        let b = session.event(nanoseconds: 1_000_002, keyCode: 38, phase: .down, growthKeys: ["J"])!
        XCTAssertEqual(a.milliseconds, b.milliseconds)
        XCTAssertLessThan(a.ordinal, b.ordinal)
        XCTAssertNil(session.event(nanoseconds: 1, keyCode: 0, phase: .up, growthKeys: []))
        XCTAssertNil(session.event(nanoseconds: 1_000_003, keyCode: 900, phase: .down, growthKeys: []))
    }
    func testEncryptionRoundTripReopenAndNoPlaintextOnDisk() throws {
        let dir = try directory(), key = SymmetricKey(size: .bits256), value = batch()
        try KeyReplayStore(directory: dir, key: key).append(value, day: "2026-11-15")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("2026-11-15"), includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(String(data: bytes, encoding: .utf8))
        XCTAssertNil(bytes.range(of: Data("keyCode".utf8)))
        let day = try KeyReplayStore(directory: dir, key: key).load(day: "2026-11-15")
        XCTAssertEqual(day.entries.map(\.event), value.events)
        XCTAssertFalse(day.hasUnreadableChunks)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testAuthenticationRejectsTamperingWrongKeyAndMovingChunkToOtherDay() throws {
        let dir = try directory(), key = SymmetricKey(size: .bits256)
        let store = try KeyReplayStore(directory: dir, key: key)
        try store.append(batch(), day: "2026-11-15")
        XCTAssertTrue(try KeyReplayStore(directory: dir, key: SymmetricKey(size: .bits256)).load(day: "2026-11-15").hasUnreadableChunks)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("2026-11-15"), includingPropertiesForKeys: nil).first)
        let other = dir.appendingPathComponent("2026-11-16")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: other.appendingPathComponent(file.lastPathComponent))
        XCTAssertTrue(try store.load(day: "2026-11-16").hasUnreadableChunks)
        var bytes = try Data(contentsOf: file); bytes[20] ^= 1; try bytes.write(to: file)
        let result = try store.load(day: "2026-11-15")
        XCTAssertTrue(result.hasUnreadableChunks); XCTAssertTrue(result.entries.isEmpty)
    }
    func testDeleteOnlyReplayDaysAndNoAutomaticRetention() throws {
        let dir = try directory(), key = SymmetricKey(size: .bits256)
        let store = try KeyReplayStore(directory: dir, key: key)
        try store.append(batch(), day: "2001-01-01")
        XCTAssertFalse(try store.load(day: "2001-01-01").entries.isEmpty)
        let sentinel = dir.appendingPathComponent("aggregate-sentinel.json")
        try Data("unchanged".utf8).write(to: sentinel)
        try store.deleteAll()
        XCTAssertTrue(try store.load(day: "2001-01-01").entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: sentinel), "unchanged")
        XCTAssertThrowsError(try store.load(day: "../Helper"))
    }
    func testChunksAppendToOneSessionAndTruncatedTailKeepsEarlierEvents() throws {
        let dir = try directory(), key = SymmetricKey(size: .bits256), all = batch()
        let store = try KeyReplayStore(directory: dir, key: key)
        try store.append(KeyReplayBatch(version: 1, session: all.session, startedAt: all.startedAt,
            events: Array(all.events.prefix(6))), day: "2026-11-15")
        try store.append(KeyReplayBatch(version: 1, session: all.session, startedAt: all.startedAt,
            events: Array(all.events.suffix(6))), day: "2026-11-15")
        let files = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("2026-11-15"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "Do not create thousands of files per day")
        XCTAssertEqual(try store.load(day: "2026-11-15").entries.map(\.event), all.events)
        let handle = try FileHandle(forWritingTo: files[0]); try handle.seekToEnd()
        try handle.write(contentsOf: Data([4, 0])); try handle.close()
        let recovered = try store.load(day: "2026-11-15")
        XCTAssertTrue(recovered.hasUnreadableChunks)
        XCTAssertEqual(recovered.entries.map(\.event), all.events)
    }
    func testBatchOrderDoesNotDependOnRandomFilenamesAndSessionsResetHeldKeys() {
        let all = batch(), a = KeyReplayBatch(version: 1, session: all.session, startedAt: all.startedAt, events: Array(all.events.prefix(6)))
        let b = KeyReplayBatch(version: 1, session: all.session, startedAt: all.startedAt, events: Array(all.events.suffix(6)))
        let next = KeyReplayBatch(version: 1, session: UUID(), startedAt: all.startedAt.addingTimeInterval(10), events: Array(all.events.prefix(2)))
        let result = KeyReplayDay(batches: [next, b, a])
        XCTAssertEqual(Array(result.entries.prefix(12)).map(\.event), all.events)
        XCTAssertTrue(result.entries[12].startsSession)
        XCTAssertEqual(result.entries[12].seconds, 10)
    }
    func testOneDayPlaybackWaitsForPresentationAndDoesNotRepeat() {
        let driver = GrowthPlaybackDriver(schedule: { _,_ in XCTFail("One day must not loop"); return {} })
        driver.waitsForPresentation = true; driver.replaysSingleDay = true
        driver.reset(dayCount: 1); driver.setActive(true); driver.start()
        XCTAssertTrue(driver.isPresentingPlaybackFrame)
        driver.framePresented(at: 0, generation: driver.presentationGeneration)
        XCTAssertFalse(driver.isPresentingPlaybackFrame)
        driver.playSelection(); XCTAssertTrue(driver.isPresentingPlaybackFrame)
        driver.setActive(false); XCTAssertFalse(driver.isPresentingPlaybackFrame)
    }
    func testClockChangeCannotReverseRecordedSessionOrder() {
        let a = batch([0]), b = batch([38])
        let first = KeyReplayBatch(version: 1, session: a.session, startedAt: Date(timeIntervalSince1970: 200), events: a.events, recordingOrder: 1)
        let second = KeyReplayBatch(version: 1, session: b.session, startedAt: Date(timeIntervalSince1970: 100), events: b.events, recordingOrder: 2)
        let day = KeyReplayDay(batches: [second, first])
        XCTAssertEqual(GrowthReplayPressPlan(day: day).ids, ["A", "J"])
        XCTAssertEqual(day.entries.map(\.seconds), day.entries.map(\.seconds).sorted())
    }
}
