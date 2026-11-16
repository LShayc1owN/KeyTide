import Foundation
import CryptoKit

/// A separate, opt-in data format. Never part of DailyStats or statistics exports.
struct KeyReplayEvent: Codable, Equatable {
    enum Phase: String, Codable { case down, up, pulse }
    let milliseconds: UInt64
    let ordinal: UInt64
    let keyCode: UInt16
    let phase: Phase
    // Physical participation IDs only, using the existing statistics mapping.
    let growthKeys: [String]
}

struct KeyReplayBatch: Codable {
    let version: Int
    let session: UUID
    let startedAt: Date
    let events: [KeyReplayEvent]
    var recordingOrder: UInt64? = nil
}

struct KeyReplayDay {
    struct Entry {
        let seconds: Double
        let event: KeyReplayEvent
        let startsSession: Bool
    }
    let entries: [Entry]
    let hasUnreadableChunks: Bool
    static let empty = KeyReplayDay(entries: [], hasUnreadableChunks: false)

    init(batches: [KeyReplayBatch], hasUnreadableChunks: Bool = false) {
        let sessions = Dictionary(grouping: batches, by: \.session).values.sorted {
            let a = $0[0], b = $1[0]
            if a.recordingOrder != b.recordingOrder { return (a.recordingOrder ?? 0) < (b.recordingOrder ?? 0) }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.session.uuidString < b.session.uuidString
        }
        let origin = sessions.first?.first?.startedAt ?? .distantPast
        var result: [Entry] = []
        for batches in sessions {
            // A manual clock change must not reverse captured session order.
            let start = max(result.last?.seconds ?? 0, batches[0].startedAt.timeIntervalSince(origin))
            let events = batches.flatMap(\.events).sorted { $0.ordinal < $1.ordinal }
            for (index, event) in events.enumerated() {
                result.append(Entry(seconds: max(0, start + Double(event.milliseconds) / 1_000),
                    event: event, startsSession: index == 0))
            }
        }
        // Start at the first captured key; preserve all subsequent recorded gaps.
        let first = result.first?.seconds ?? 0
        entries = result.map { Entry(seconds: max(0, $0.seconds - first), event: $0.event, startsSession: $0.startsSession) }
        self.hasUnreadableChunks = hasUnreadableChunks
    }

    init(entries: [Entry], hasUnreadableChunks: Bool) {
        self.entries = entries; self.hasUnreadableChunks = hasUnreadableChunks
    }
}

/// Call on the recorder's serial queue. One file per capture session, containing
/// independently authenticated bounded chunks. A truncated tail never discards
/// earlier valid chunks. No plaintext journal or per-keystroke disk write.
final class KeyReplayStore {
    enum Failure: Error { case invalidDay, invalidBatch, oversizedChunk, unsafePath }
    let directory: URL
    private let key: SymmetricKey
    private let files: FileManager
    private let maxChunkSize = 1_048_576

    init(directory: URL, key: SymmetricKey, files: FileManager = .default) throws {
        self.directory = directory; self.key = key; self.files = files
        try makePrivateDirectory(directory)
    }

    func append(_ batch: KeyReplayBatch, day: String) throws {
        guard Self.valid(day) else { throw Failure.invalidDay }
        guard batch.version == 1, !batch.events.isEmpty, batch.events.count <= 128 else { throw Failure.invalidBatch }
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        try makePrivateDirectory(folder)
        let plaintext = try JSONEncoder().encode(batch)
        let aad = Data(("Keytide.KeyReplay.v1/" + day).utf8)
        let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined!
        guard encrypted.count <= maxChunkSize else { throw Failure.oversizedChunk }
        let url = folder.appendingPathComponent(batch.session.uuidString + ".ktr")
        var length = UInt32(encrypted.count).littleEndian
        var chunk = withUnsafeBytes(of: &length) { Data($0) }
        chunk.append(encrypted)
        if files.fileExists(atPath: url.path) {
            try rejectSymlink(url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: chunk)
        } else {
            try chunk.write(to: url, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func load(day: String) throws -> KeyReplayDay {
        guard Self.valid(day) else { throw Failure.invalidDay }
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        guard files.fileExists(atPath: folder.path) else { return .empty }
        try rejectSymlink(folder)
        var batches: [KeyReplayBatch] = [], damaged = false
        for url in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) where url.pathExtension == "ktr" {
            do {
                try rejectSymlink(url)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let prefix = try handle.read(upToCount: 4), !prefix.isEmpty {
                    guard prefix.count == 4 else { throw Failure.invalidBatch }
                    let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                    guard length > 0, length <= maxChunkSize,
                          let bytes = try handle.read(upToCount: Int(length)), bytes.count == Int(length) else { throw Failure.invalidBatch }
                    let box = try AES.GCM.SealedBox(combined: bytes)
                    let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(("Keytide.KeyReplay.v1/" + day).utf8))
                    let batch = try JSONDecoder().decode(KeyReplayBatch.self, from: plaintext)
                    guard batch.version == 1, batch.events.count <= 128,
                          batch.events.allSatisfy({ $0.keyCode <= 255 && $0.growthKeys.count <= 8 }) else { throw Failure.invalidBatch }
                    batches.append(batch)
                }
            } catch { damaged = true }
        }
        return KeyReplayDay(batches: batches, hasUnreadableChunks: damaged)
    }

    func deleteAll() throws {
        try rejectSymlink(directory)
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // Only this feature's ISO date folders; never touch statistics/Helper.
            if Self.valid(url.lastPathComponent) { try files.removeItem(at: url) }
        }
    }

    private static func valid(_ day: String) -> Bool {
        day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    private func rejectSymlink(_ url: URL) throws {
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.unsafePath }
    }
    private func makePrivateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymlink(url)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var resourceURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

/// Pure ingress policy and timestamp conversion. No text, app identity, network,
/// defaults or global listener. A new session is needed after a capture gap.
struct KeyReplaySession {
    let id = UUID()
    let startedAt: Date
    let originNanoseconds: UInt64
    private(set) var ordinal: UInt64 = 0
    private var lastNanoseconds: UInt64 = 0
    mutating func event(nanoseconds: UInt64, keyCode: UInt16, phase: KeyReplayEvent.Phase,
                        growthKeys: [String]) -> KeyReplayEvent? {
        guard keyCode <= 255, nanoseconds >= originNanoseconds,
              nanoseconds >= lastNanoseconds else { return nil }
        lastNanoseconds = nanoseconds
        defer { ordinal += 1 }
        return KeyReplayEvent(milliseconds: (nanoseconds - originNanoseconds) / 1_000_000,
            ordinal: ordinal, keyCode: keyCode, phase: phase, growthKeys: growthKeys)
    }
}

/// Built-in, explicitly synthetic replay. No manager, defaults, file or recorder
/// dependency. It uses the same event and presentation types as real playback.
struct KeyReplayExample {
    let presentation: GrowthKeyboardPresentation
    let recordedDayKey: String
    let day: KeyReplayDay

    static func make(now: Date = Date(), calendar: Calendar = .current) -> KeyReplayExample {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let firstKey = formatter.string(from: first), lastKey = formatter.string(from: today)
        // A seed makes the approved stable-growth model readable immediately;
        // each sample key-down still contributes exactly one participation.
        var seed = DailyStats(date: first)
        seed.keyPressCounts = ["A": 600, "J": 1200, "S": 1800, "I": 900, "H": 400,
            "Space": 2400, "K": 300, "E": 1500, "Y": 200, "T": 1000, "D": 500, "F": 700]
        seed.keyPresses = seed.keyPressCounts.values.reduce(0, +)
        var sample = DailyStats(date: today)
        // A J S I S H, Space, K E Y T I D E, Space, A S D F F D S A.
        let codes: [UInt16] = [0, 38, 1, 34, 1, 4, 49, 40, 14, 16, 17, 34, 2, 14, 49, 0, 1, 2, 3, 3, 2, 1, 0]
        var entries: [KeyReplayDay.Entry] = []
        var time: UInt64 = 0
        for (index, code) in codes.enumerated() {
            let id = MechanicalKeyboardView.physicalKeyID(code)!
            sample.keyPressCounts[id, default: 0] += 1; sample.keyPresses += 1
            entries.append(.init(seconds: Double(time) / 1000,
                event: .init(milliseconds: time, ordinal: UInt64(index * 2), keyCode: code,
                    phase: .down, growthKeys: [id]), startsSession: index == 0))
            let release = time + 130
            entries.append(.init(seconds: Double(release) / 1000,
                event: .init(milliseconds: release, ordinal: UInt64(index * 2 + 1), keyCode: code,
                    phase: .up, growthKeys: []), startsSession: false))
            time += [6, 14].contains(index) ? 600 : [300, 380, 340][index % 3]
        }
        let history = [firstKey: seed, lastKey: sample]
        let period = KeyboardTrackingPeriod(history: history, calendar: calendar, dateKeyFormatter: formatter)!
        let presentation = GrowthKeyboardPresentation(timeline: CumulativeKeyboardTimeline.build(history: history),
            period: period, now: now, calendar: calendar)!
        return KeyReplayExample(presentation: presentation, recordedDayKey: lastKey,
            day: KeyReplayDay(entries: entries, hasUnreadableChunks: false))
    }
}
