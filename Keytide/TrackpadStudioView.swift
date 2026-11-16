import Cocoa
import Darwin
import CryptoKit
import Security

// Private ABI adapted from OpenMultitouchSupport (MIT).
// See scripts/trackpad-probe/THIRD_PARTY_NOTICES.md. Private input adapter; persistence is separately opt-in.
struct TrackpadContact: Codable {
    let identity: Int32
    let state: Int32
    let sourceTime: Double
    let position: CGPoint
    let rawPressure: Float?
}
struct TrackpadFrame: Codable {
    let sourceTime: Double
    let ordinal: Int32
    let contacts: [TrackpadContact]
}

private typealias TrackpadCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
private enum TrackpadBridge {
    static let lock = NSLock()
    static var receive: ((TrackpadFrame) -> Void)?
    // Keep the framework loaded until process exit: late private callbacks must
    // never return into unloaded code.
    static let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL)
    static let callback: TrackpadCallback = { _, data, count, time, ordinal in
        guard (0...32).contains(count), time.isFinite, time >= 0, count == 0 || data != nil else { return }
        var contacts: [TrackpadContact] = []
        for index in 0..<Int(count) {
            let p = data!.advanced(by: index * 96)
            let sourceTime = p.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let identity = p.loadUnaligned(fromByteOffset: 16, as: Int32.self)
            let state = p.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            let x = p.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let y = p.loadUnaligned(fromByteOffset: 36, as: Float.self)
            let pressure = p.loadUnaligned(fromByteOffset: 52, as: Float.self)
            guard sourceTime.isFinite, sourceTime >= 0, (0...7).contains(state),
                  x.isFinite, y.isFinite, (-0.05...1.05).contains(x), (-0.05...1.05).contains(y) else { return }
            contacts.append(TrackpadContact(identity: identity, state: state, sourceTime: sourceTime,
                position: CGPoint(x: CGFloat(x), y: CGFloat(y)), rawPressure: pressure.isFinite ? pressure : nil))
        }
        lock.lock(); let handler = receive; lock.unlock()
        handler?(TrackpadFrame(sourceTime: time, ordinal: ordinal, contacts: contacts))
    }
}

/// Bounded callback delivery. Overflow emits an empty boundary before the next
/// frame. Raw surface positions never enter logs or aggregate statistics.
final class TrackpadPreviewCapture {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, TrackpadCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Void
    private var device: UnsafeMutableRawPointer?
    private var unregister: Register?, stopDevice: Stop?, releaseDevice: Release?
    private let lock = NSLock()
    private var pending: [TrackpadFrame] = []
    private var scheduled = false
    private var generation = 0
    private var accepting = false
    var onFrame: ((TrackpadFrame) -> Void)?
    deinit { stop() }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library = TrackpadBridge.library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    func start() -> Bool {
        if device != nil { return true }
        guard let create = symbol("MTDeviceCreateDefault", Create.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self),
              let stop = symbol("MTDeviceStop", Stop.self),
              let release = symbol("MTDeviceRelease", Release.self) else { return false }
        TrackpadBridge.lock.lock()
        guard TrackpadBridge.receive == nil else { TrackpadBridge.lock.unlock(); return false }
        lock.lock(); generation &+= 1; let token = generation; lock.unlock()
        TrackpadBridge.receive = { [weak self] frame in self?.enqueue(frame, generation: token) }
        TrackpadBridge.lock.unlock()
        guard let device = create() else {
            TrackpadBridge.lock.lock(); TrackpadBridge.receive = nil; TrackpadBridge.lock.unlock()
            return false
        }
        self.device = device; self.unregister = unregister; stopDevice = stop; releaseDevice = release
        lock.lock(); accepting = true; lock.unlock()
        register(device, TrackpadBridge.callback)
        guard start(device, 0) == 0 else { self.stop(); return false }
        return true
    }
    func stop() {
        lock.lock(); accepting = false; generation &+= 1; pending.removeAll(); scheduled = false; lock.unlock()
        guard let device else { return }
        self.device = nil
        TrackpadBridge.lock.lock(); TrackpadBridge.receive = nil; TrackpadBridge.lock.unlock()
        unregister?(device, TrackpadBridge.callback); _ = stopDevice?(device); releaseDevice?(device)
    }
    private func enqueue(_ frame: TrackpadFrame, generation token: Int) {
        lock.lock()
        guard accepting, token == generation else { lock.unlock(); return }
        // Preserve every callback between UI deliveries, rather than dropping
        // all intermediate positions. Overflow starts a new visible segment.
        if pending.count >= 256 { pending.removeAll(); pending.append(TrackpadFrame(sourceTime: frame.sourceTime, ordinal: frame.ordinal, contacts: [])) }
        pending.append(frame)
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.accepting, token == self.generation else { self.lock.unlock(); return }
            let values = self.pending; self.pending.removeAll(keepingCapacity: true); self.scheduled = false
            self.lock.unlock()
            for value in values { self.onFrame?(value) }
        }
    }
}

/// Replaceable brush; receives normalized contacts, independent of private API.
private final class TrackpadInkView: NSView {
    struct Point { let position: CGPoint; let time: Double; let pressure: CGFloat }
    private var trails: [Int32: [Point]] = [:]
    private var lastSourceTime: Double?
    private var touching = Set<Int32>()
    private var cursorHidden = false
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard window?.isKeyWindow == true, NSApp.isActive else { return }
        if !cursorHidden {
            // Freeze the pointer at the click inside the canvas. Hiding alone
            // still lets physical motion send clicks to other applications.
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { NSSound.beep(); return }
            NSCursor.hide(); cursorHidden = true
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { restoreCursor(); window?.makeFirstResponder(nil) }
        else { super.keyDown(with: event) }
    }
    private func restoreCursor() {
        if cursorHidden { _ = CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide(); cursorHidden = false }
    }
    var stardust = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(NSLocalizedString("trackpad.canvas", comment: ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if cursorHidden { _ = CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() } }
    override func resignFirstResponder() -> Bool { restoreCursor(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        restoreCursor(); super.viewWillMove(toWindow: newWindow)
    }
    func clear() {
        restoreCursor(); trails.removeAll(); touching.removeAll(); lastSourceTime = nil; needsDisplay = true
    }
    func accept(_ frame: TrackpadFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSourceTime, frame.sourceTime < lastSourceTime || frame.sourceTime - lastSourceTime > 0.25 { trails.removeAll(); touching.removeAll() }
        lastSourceTime = frame.sourceTime
        for contact in frame.contacts {
            if contact.state == 3 || !touching.contains(contact.identity) { trails[contact.identity] = [] }
            guard contact.state == 3 || contact.state == 4 else { continue }
            var points = trails[contact.identity, default: []]
            let raw = max(0, Double(contact.rawPressure ?? 0))
            // Bounded relative response; not calibrated force or a click detector.
            let pressure = CGFloat(raw / (raw + 60))
            points.append(Point(position: contact.position, time: now, pressure: pressure))
            if points.count > 4096 {
                points = points.enumerated().filter { $0.offset % 2 == 0 || $0.offset == points.count - 1 }.map(\.element)
            }
            trails[contact.identity] = points
        }
        touching = Set(frame.contacts.filter { $0.state == 3 || $0.state == 4 }.map(\.identity))
        trails = trails.filter { touching.contains($0.key) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let surface = bounds.insetBy(dx: 16, dy: 16)
        NSColor.white.withAlphaComponent(0.035).setFill()
        let outline = NSBezierPath(roundedRect: surface, xRadius: 24, yRadius: 24)
        outline.fill(); NSColor.white.withAlphaComponent(0.2).setStroke(); outline.lineWidth = 1; outline.stroke()
        NSGraphicsContext.saveGraphicsState(); outline.addClip()
        func position(_ p: CGPoint) -> CGPoint { CGPoint(x: surface.minX + p.x * surface.width, y: surface.minY + p.y * surface.height) }
        for points in trails.values where !points.isEmpty {
            let alpha: CGFloat = 0.55 + points.last!.pressure * 0.45
            let color = NSColor.systemCyan.withAlphaComponent(alpha)
            color.setStroke(); color.setFill()
            // One continuous quadratic path avoids overdraw at every sample joint.
            let path = NSBezierPath()
            // A short moving average responds to current pressure instead of
            // diluting it over the entire stroke. Keep one joined path.
            let recent = points.suffix(8)
            let pressure = recent.reduce(CGFloat(0)) { $0 + $1.pressure } / CGFloat(recent.count)
            path.lineWidth = 2.0 + pressure * 3.5
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: position(points[0].position))
            var start = position(points[0].position)
            for index in 1..<points.count {
                let control = position(points[index - 1].position), next = position(points[index].position)
                let end = index == points.count - 1 ? next : CGPoint(x: (control.x + next.x)/2, y: (control.y + next.y)/2)
                path.curve(to: end, controlPoint1: CGPoint(x: start.x + (control.x-start.x)*2/3, y: start.y + (control.y-start.y)*2/3),
                    controlPoint2: CGPoint(x: end.x + (control.x-end.x)*2/3, y: end.y + (control.y-end.y)*2/3))
                start = end
            }
            NSColor.systemCyan.withAlphaComponent(0.78 + pressure * 0.18).setStroke(); path.stroke()
            if stardust && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (index, point) in points.enumerated() where index % 4 == 0 {
                    let p = position(point.position), angle = Double(index) * 2.4
                    NSColor.systemYellow.withAlphaComponent(alpha * 0.65).setFill()
                    NSBezierPath(ovalIn: NSRect(x: p.x + cos(angle) * 9, y: p.y + sin(angle) * 9, width: 2.5, height: 2.5)).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class TrackpadStudioView: NSView {
    private let service = TrackpadRecording.shared
    private let ink = TrackpadInkView()
    private let toggle = NSButton()
    private let replay = NSButton()
    private let day = NSDatePicker()
    private var playback: DispatchWorkItem?
    private var replayGeneration = 0
    private var replayReader: TrackpadReplayReader?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let help = NSTextField(wrappingLabelWithString: "")
    private let haptics = NSButton(checkboxWithTitle: NSLocalizedString("trackpad.haptics", comment: ""), target: nil, action: nil)
    private var running = false
    private var visible = false
    private var lastHaptic = -Double.infinity
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "Trackpad preview") }
    override init(frame: NSRect) {
        super.init(frame: frame)
        toggle.title = text("trackpad.record.always"); toggle.setButtonType(.switch)
        toggle.state = service.recording ? .on : .off
        toggle.target = self; toggle.action = #selector(togglePreview)
        let brush = NSSegmentedControl(labels: [text("trackpad.ink"), text("trackpad.stardust")], trackingMode: .selectOne, target: self, action: #selector(changeBrush(_:)))
        brush.selectedSegment = 0; brush.setAccessibilityLabel(text("trackpad.brush"))
        let clear = NSButton(title: text("trackpad.clear"), target: self, action: #selector(clearInk)); clear.bezelStyle = .rounded
        replay.title = text("trackpad.replay"); replay.bezelStyle = .rounded
        replay.target = self; replay.action = #selector(playDay)
        day.datePickerElements = [.yearMonthDay]; day.datePickerStyle = .textFieldAndStepper
        day.dateValue = Date(); day.maxDate = Date()
        let delete = NSButton(title: text("trackpad.delete"), target: self, action: #selector(deleteRecords))
        delete.bezelStyle = .rounded
        let toolbar = NSStackView(views: [toggle, brush, clear, haptics, day, replay, delete]); toolbar.spacing = 8
        help.stringValue = text("trackpad.preview.help"); help.font = .systemFont(ofSize: 12)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.stringValue = text("trackpad.ready")
        for child in [toolbar, help, ink, status] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor), toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            help.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), help.centerXAnchor.constraint(equalTo: centerXAnchor),
            help.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        ink.translatesAutoresizingMaskIntoConstraints = true
        service.onFrame = { [weak self] frame in
            guard let self, self.playback == nil, self.visible, self.window?.isVisible == true, self.window?.occlusionState.contains(.visible) == true, !self.window!.isMiniaturized, NSApp.isActive else { return }
            self.ink.accept(frame)
            self.status.stringValue = self.service.recording ? self.text("trackpad.recording") : String(format: self.text("trackpad.live"), frame.contacts.filter { $0.state == 3 || $0.state == 4 }.count, frame.sourceTime)
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() }))
        }
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.ink.clear() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach { $0.0.removeObserver($0.1) }; playback?.cancel(); replayReader?.cancel() }
    override func layout() {
        super.layout()
        let bottom = status.frame.maxY + 8
        let available = max(0, help.frame.minY - 12 - bottom)
        let width = min(850, bounds.width * 0.90, available / 0.62)
        let height = width * 0.62
        ink.frame = NSRect(x: (bounds.width - width) / 2, y: bottom + (available - height) / 2,
                           width: width, height: height)
    }
    func setPresented(_ value: Bool) { visible = value; service.preview = value; if !value { stop() } else { service.updateCapture(); toggle.state = service.recording ? .on : .off } }
    func suspendRendering() { ink.clear() }
    func stop() {
        service.preview = false; service.updateCapture(); replayReader?.cancel(); replayReader = nil; replayGeneration += 1; playback?.cancel(); playback = nil; running = false; ink.clear()
        toggle.state = service.recording ? .on : .off; status.stringValue = text(service.recording ? "trackpad.recording" : "trackpad.ready")
    }
    @objc private func togglePreview() {
        if service.recording { service.setRecording(false) }
        else {
            let alert = NSAlert(); alert.messageText = text("trackpad.record")
            alert.informativeText = text("trackpad.consent")
            alert.addButton(withTitle: text("trackpad.record")); alert.addButton(withTitle: text("trackpad.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { toggle.state = .off; return }
            service.setRecording(true)
        }
        toggle.state = service.recording ? .on : .off
        status.stringValue = text(service.failed ? "trackpad.failed" : service.recording ? "trackpad.recording" : "trackpad.ready")
    }
    @objc private func deleteRecords() {
        let alert = NSAlert(); alert.messageText = text("trackpad.delete.confirm")
        alert.addButton(withTitle: text("trackpad.delete")); alert.addButton(withTitle: text("trackpad.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stop(); service.deleteAll { [weak self] ok in self?.status.stringValue = self?.text(ok ? "trackpad.ready" : "trackpad.failed") ?? "" }
    }
    @objc private func playDay() {
        replayReader?.cancel(); replayReader = nil; replayGeneration += 1; let token = replayGeneration
        playback?.cancel(); playback = DispatchWorkItem {}; ink.clear()
        service.load(day: day.dateValue) { [weak self] reader in
            guard let self, token == self.replayGeneration, self.visible else { reader?.cancel(); return }
            guard let reader else { self.playback = nil; self.status.stringValue = self.text("trackpad.replay.empty"); return }
            self.replayReader = reader
            let start = ProcessInfo.processInfo.systemUptime
            func tick() {
                guard token == self.replayGeneration, self.visible else { reader.cancel(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                reader.take(through: elapsed) { [weak self] frames, done, failed in
                    guard let self, token == self.replayGeneration, self.visible else { reader.cancel(); return }
                    for frame in frames { self.ink.accept(frame) }
                    if done || failed {
                        self.playback = nil; self.replayReader = nil
                        if failed { self.status.stringValue = self.text("trackpad.failed") }
                        return
                    }
                    let work = DispatchWorkItem(block: tick); self.playback = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (frames.count >= 128 ? 0 : 1.0/60), execute: work)
                }
            }
            tick()
        }
    }
    @objc private func changeBrush(_ sender: NSSegmentedControl) { ink.stardust = sender.selectedSegment == 1; feedback() }
    @objc private func clearInk() { ink.clear(); feedback() }
    private func feedback() {
        let now = ProcessInfo.processInfo.systemUptime
        guard haptics.state == .on, NSApp.isActive, window?.isKeyWindow == true, now - lastHaptic >= 0.25 else { return }
        lastHaptic = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Local-only opt-in recorder. Main-thread ingress, bounded queued encrypted
/// batches; the serial I/O queue also orders loads and deletion after writes.
final class TrackpadRecording {
    static let shared = TrackpadRecording()
    private let capture = TrackpadPreviewCapture()
    private let queue = DispatchQueue(label: "Keytide.TrackpadRecords", qos: .utility)
    private let gate = NSLock()
    private var outstanding = 0
    private var activeReader: TrackpadReplayReader?
    private var batch: [TrackpadFrame] = []
    private var flushTask: DispatchWorkItem?
    private var key: SymmetricKey?
    private var session = UUID().uuidString
    private var chunk = 0
    private var recordingOrder = 0
    private var batchDay = ""
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private let preference = "trackpad.recording.consent.v1"
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keytide/TrackpadReplay")
    private(set) var recording = false
    private(set) var failed = false
    var preview = false
    var onFrame: ((TrackpadFrame) -> Void)?
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private init() {
        capture.onFrame = { [weak self] frame in
            guard let self else { return }
            if self.recording {
                let day = self.formatter.string(from: Date())
                if day != self.batchDay { self.flush(); self.batchDay = day }
                guard self.recording else { return }
                self.batch.append(frame)
                if self.batch.count >= 128 { self.flush() }
                else if self.flushTask == nil {
                    let task = DispatchWorkItem { [weak self] in self?.flushTask = nil; self?.flush() }
                    self.flushTask = task; DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: task)
                }
            }
            if self.preview { self.onFrame?(frame) }
        }
    }
    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }; self.suspended = true; self.flush(); self.capture.stop()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }; self.suspended = false; if self.recording { self.setRecording(true) } else { self.updateCapture() }
            })
        }
        if UserDefaults.standard.bool(forKey: preference) { setRecording(true) }
    }
    func updateCapture() {
        if !suspended && (preview || recording) {
            if !capture.start() { fail() }
        } else { capture.stop() }
    }
    func setRecording(_ enabled: Bool) {
        flush(); recording = false
        if enabled {
            do { key = try localKey(create: true); session = UUID().uuidString; chunk = 0; recordingOrder = UserDefaults.standard.integer(forKey: "trackpad.recording.order.v1") + 1; UserDefaults.standard.set(recordingOrder, forKey: "trackpad.recording.order.v1"); recording = true; failed = false }
            catch { failed = true }
        }
        UserDefaults.standard.set(recording, forKey: preference)
        updateCapture()
    }
    private func fail() {
        recording = false; failed = true; batch.removeAll(); flushTask?.cancel(); flushTask = nil
        UserDefaults.standard.set(false, forKey: preference)
    }
    func finish() { flush(); capture.stop(); queue.sync {} }
    private func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !batch.isEmpty, let key else { return }
        gate.lock()
        guard outstanding < 8 else { gate.unlock(); fail(); return }
        outstanding += 1; gate.unlock()
        let frames = batch; let order = recordingOrder; batch.removeAll(keepingCapacity: true)
        let day = batchDay, filename = String(format: "%020d", recordingOrder) + "-" + session + String(format: "-%08d", chunk) + ".ktp"
        chunk += 1
        queue.async {
            defer { self.gate.lock(); self.outstanding -= 1; self.gate.unlock() }
            do {
                try self.prepare(self.directory)
                let folder = self.directory.appendingPathComponent(day); try self.prepare(folder)
                let data = try JSONEncoder().encode(frames)
                let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(("Keytide.Trackpad.v1/"+day).utf8)).combined!
                let file = folder.appendingPathComponent(filename)
                try sealed.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { DispatchQueue.main.async { if self.recordingOrder == order { self.fail() } } }
        }
    }
    private func prepare(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var value = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try value.setResourceValues(flags)
    }
    func load(day: Date, completion: @escaping (TrackpadReplayReader?) -> Void) {
        flush(); let dayKey = formatter.string(from: day)
        // Snapshot file names after preceding writes, then decrypt on a separate
        // reader queue. A long replay scan must never starve live recording I/O.
        queue.async {
            do {
                let folder = self.directory.appendingPathComponent(dayKey)
                guard FileManager.default.fileExists(atPath: folder.path) else { DispatchQueue.main.async { completion(nil) }; return }
                guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
                let key = try self.localKey(create: false)
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "ktp" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                self.activeReader?.cancel()
                let reader = TrackpadReplayReader(files: files, key: key, day: dayKey)
                self.activeReader = reader
                reader.prepare { ok in completion(ok ? reader : nil) }
            } catch { DispatchQueue.main.async { completion(nil) } }
        }
    }
    func deleteAll(completion: @escaping (Bool) -> Void) {
        setRecording(false)
        queue.async {
            do {
                self.activeReader?.cancel(); self.activeReader = nil
                if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
                DispatchQueue.main.async { completion(true) }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    private func localKey(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xuanlprk.KeyTide.TrackpadReplay.v1", kSecAttrAccount as String: "encryption",
            kSecAttrSynchronizable as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard result == errSecItemNotFound, create else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        let key = SymmetricKey(size: .bits256); var add = query
        add.removeValue(forKey: kSecReturnData as String); add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}

/// Two-pass bounded decryption. Only file names and one authenticated chunk are
/// retained; there is no whole-day frame array or plaintext replay cache.
final class TrackpadReplayReader {
    private let files: [URL]
    private let key: SymmetricKey
    private let aad: Data
    private let queue = DispatchQueue(label: "Keytide.TrackpadReplayReader", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var fileIndex = 0, frameIndex = 0
    private var frames: [TrackpadFrame] = []
    private var previousFile: String?
    private var previousTime: Double?
    private var elapsed = 0.0, scale = 1.0
    private var pending: (TrackpadFrame, Double)?
    init(files: [URL], key: SymmetricKey, day: String) {
        self.files = files; self.key = key; aad = Data(("Keytide.Trackpad.v1/" + day).utf8)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func decode(_ file: URL) throws -> [TrackpadFrame] {
        let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key, authenticating: aad)
        let values = try JSONDecoder().decode([TrackpadFrame].self, from: bytes)
        guard !values.isEmpty, values.count <= 128,
              values.allSatisfy({ frame in
                  frame.sourceTime.isFinite && frame.sourceTime >= 0 && frame.contacts.count <= 32 &&
                  Set(frame.contacts.map(\.identity)).count == frame.contacts.count &&
                  frame.contacts.allSatisfy { c in c.sourceTime.isFinite && (0...7).contains(c.state) &&
                      c.position.x.isFinite && c.position.y.isFinite &&
                      (-0.05...1.05).contains(c.position.x) && (-0.05...1.05).contains(c.position.y) &&
                      (c.rawPressure?.isFinite ?? true) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    private func next() throws -> TrackpadFrame? {
        if frameIndex < frames.count { defer { frameIndex += 1 }; return frames[frameIndex] }
        guard fileIndex < files.count else { return nil }
        let file = files[fileIndex]; fileIndex += 1
        frames = try decode(file); frameIndex = 0
        let name = file.lastPathComponent
        let identity = String(name.dropLast(13))
        let number = Int(name.dropLast(4).suffix(8))
        let previousNumber = previousFile.flatMap { Int($0.dropLast(4).suffix(8)) }
        let contiguous = previousFile.map { String($0.dropLast(13)) == identity } == true &&
            number != nil && previousNumber != nil && number! == previousNumber! + 1
        previousFile = name
        if !contiguous, let first = frames.first {
            previousTime = nil
            return TrackpadFrame(sourceTime: first.sourceTime, ordinal: first.ordinal, contacts: [])
        }
        return try next()
    }
    func prepare(completion: @escaping (Bool) -> Void) {
        queue.async {
            do {
                var total = 0.0, last: Double?
                while !self.isCancelled, let frame = try self.next() {
                    if let last { total += min(0.12, max(0, frame.sourceTime - last)) }
                    last = frame.sourceTime
                }
                self.scale = min(1, 9.5 / max(0.001, total))
                self.fileIndex = 0; self.frameIndex = 0; self.frames = []
                self.previousFile = nil; self.previousTime = nil
                DispatchQueue.main.async { completion(!self.isCancelled && !self.files.isEmpty) }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    func take(through time: Double, completion: @escaping ([TrackpadFrame], Bool, Bool) -> Void) {
        queue.async {
            var output: [TrackpadFrame] = [], done = false
            do {
                while output.count < 128 && !self.isCancelled {
                    if self.pending == nil {
                        guard let frame = try self.next() else { done = true; break }
                        if let previous = self.previousTime { self.elapsed += min(0.12, max(0, frame.sourceTime - previous)) * self.scale }
                        self.previousTime = frame.sourceTime
                        self.pending = (frame, self.elapsed)
                    }
                    guard let pending = self.pending, pending.1 <= time else { break }
                    output.append(pending.0); self.pending = nil
                }
                DispatchQueue.main.async { completion(output, done || self.isCancelled, false) }
            } catch { DispatchQueue.main.async { completion([], true, true) } }
        }
    }
}
