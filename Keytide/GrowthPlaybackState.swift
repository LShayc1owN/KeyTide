import Foundation

struct GrowthPlaybackState {
    let lastOffset: Int
    private(set) var offset: Int
    private(set) var isPlaying = false

    init(dayCount: Int, selectedOffset: Int? = nil) {
        precondition(dayCount > 0)
        lastOffset = dayCount - 1
        offset = min(lastOffset, max(0, selectedOffset ?? lastOffset))
    }
    mutating func select(_ offset: Int) {
        self.offset = min(lastOffset, max(0, offset))
        isPlaying = false
    }
    mutating func start() { offset = 0; isPlaying = lastOffset > 0 }
    mutating func pause() { isPlaying = false }
    mutating func advance() {
        guard isPlaying else { return }
        offset = min(lastOffset, offset + 1)
        if offset == lastOffset { isPlaying = false }
    }
}

/// Bounded, cancellable one-shot playback. Scheduling is injectable for tests;
/// the same driver is used by the production page. No repeating timer.
final class GrowthPlaybackDriver {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let schedule: Schedule
    private var cancelPending: (() -> Void)?
    private var generation = 0
    private var awaitingPresentation = false
    var waitsForPresentation = false
    var replaysSingleDay = false
    var stepInterval: TimeInterval = 0.15
    var presentationGeneration: Int { generation }
    var isPresentingPlaybackFrame: Bool { waitsForPresentation && (state.isPlaying || awaitingPresentation) }
    private(set) var state = GrowthPlaybackState(dayCount: 1)
    private(set) var isActive = false
    var onChange: ((Int) -> Void)?
    var hasScheduledStep: Bool { cancelPending != nil }

    init(schedule: @escaping Schedule = GrowthPlaybackDriver.scheduleOnMain) {
        self.schedule = schedule
    }
    deinit { cancelPending?() }

    func reset(dayCount: Int, selectedOffset: Int? = nil) {
        pause()
        state = GrowthPlaybackState(dayCount: dayCount, selectedOffset: selectedOffset)
        onChange?(state.offset)
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { pause() }
    }

    func select(_ offset: Int) {
        pause()
        state.select(offset)
        onChange?(state.offset)
    }

    func start() {
        guard isActive else { return }
        pause()
        state.start()
        awaitingPresentation = waitsForPresentation && (state.isPlaying || replaysSingleDay)
        onChange?(state.offset)
        enqueue()
    }

    func playSelection() {
        guard isActive else { return }
        pause()
        awaitingPresentation = waitsForPresentation
        onChange?(state.offset)
    }

    func pause() {
        generation &+= 1
        cancelPending?()
        cancelPending = nil
        state.pause()
        awaitingPresentation = false
    }

    /// 3D advances only after the requested image is ready. Cold shaders and slower
    /// machines cannot make the calendar outrun the displayed keyboard.
    func framePresented(at offset: Int, generation token: Int) {
        guard generation == token, state.offset == offset, isActive, awaitingPresentation else { return }
        awaitingPresentation = false
        enqueue()
    }

    private func enqueue() {
        guard isActive && state.isPlaying && !awaitingPresentation && cancelPending == nil else { return }
        let token = generation
        cancelPending = schedule(stepInterval) { [weak self] in
            guard let self, self.generation == token, self.isActive, self.state.isPlaying else { return }
            self.cancelPending = nil
            self.state.advance()
            self.awaitingPresentation = self.waitsForPresentation
            self.onChange?(self.state.offset)
            self.enqueue()
        }
    }

    private static func scheduleOnMain(after delay: TimeInterval, action: @escaping () -> Void) -> (() -> Void) {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}

/// Real order with a bounded presentation clock. The source event's millisecond
/// timestamp is untouched; only Entry.seconds is compressed for viewing.
/// An empty day never synthesizes input from daily totals.
struct GrowthReplayPressPlan {
    let entries: [KeyReplayDay.Entry]
    let isAccelerated: Bool
    let stream: KeyReplayStream?
    let hasUnreadableChunks: Bool
    var hasEvents: Bool { stream.map { $0.eventCount > 0 } ?? !entries.isEmpty }

    init(stream: KeyReplayStream) {
        self.stream = stream; entries = []; isAccelerated = stream.isAccelerated
        hasUnreadableChunks = stream.hasUnreadableChunks
    }
    static let maximumDaySeconds = 8.0
    static let maximumGapSeconds = 0.12

    init(day: KeyReplayDay) {
        stream = nil; hasUnreadableChunks = day.hasUnreadableChunks
        var previous = day.entries.first?.seconds ?? 0
        var time = 0.0
        let clipped = day.entries.map { entry -> KeyReplayDay.Entry in
            let delta = max(0, entry.seconds - previous)
            time += min(Self.maximumGapSeconds, delta)
            previous = entry.seconds
            return .init(seconds: time, event: entry.event, startsSession: entry.startsSession)
        }
        let scale = time > 0 ? min(1, Self.maximumDaySeconds / time) : 1
        entries = clipped.map { .init(seconds: $0.seconds * scale, event: $0.event, startsSession: $0.startsSession) }
        isAccelerated = (entries.last?.seconds ?? 0) + 0.000_001 < (day.entries.last?.seconds ?? 0)
    }
    var ids: [String] { entries.filter { $0.event.phase != .up }.compactMap { MechanicalKeyboardView.physicalKeyID($0.event.keyCode) } }
    func duration(profile: MechanicalPressProfile) -> Double {
        (stream?.duration ?? entries.last?.seconds ?? 0) + (hasEvents ? profile.duration : 0)
    }
}
