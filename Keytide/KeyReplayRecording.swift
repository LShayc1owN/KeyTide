import AppKit
import CryptoKit
import Security

extension Notification.Name {
    static let keyReplayRecordingChanged = Notification.Name("Keytide.keyReplayRecordingChanged")
    static let keyReplayRecordsDeleted = Notification.Name("Keytide.keyReplayRecordsDeleted")
}

/// Owns the opt-in boundary. This object never receives text and never sends
/// records to Analytics, exports, plugins, backups or a network API.
final class KeyReplayRecording {
    static let shared = KeyReplayRecording()
    private let preference = "keyReplay.explicitConsent.v1"
    private let defaults: UserDefaults
    private let directoryOverride: URL?
    private let keyProvider: (() throws -> SymmetricKey)?
    private let queue = DispatchQueue(label: "Keytide.LocalReplay", qos: .utility)
    private let gate = NSLock()
    private var accepting = false
    private var acceptsAfterNanoseconds: UInt64 = 0
    private var epoch = 0
    private var session: KeyReplaySession?
    private var sessionDay: String?
    private var sessionOrder: UInt64 = 0
    private var events: [KeyReplayEvent] = []
    private var pendingFlush: DispatchWorkItem?
    private var store: KeyReplayStore?
    private var observers: [NSObjectProtocol] = []
    private let dayFormatter: DateFormatter = {
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"
        return value
    }()
    private(set) var statusKey = "replay.recording.off"
    var isEnabled: Bool { defaults.bool(forKey: preference) }
    private var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keytide/LocalReplay", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, directory: URL? = nil, keyProvider: (() throws -> SymmetricKey)? = nil) {
        self.defaults = defaults; directoryOverride = directory; self.keyProvider = keyProvider
    }

    func startObserving() {
        observers.append(NotificationCenter.default.addObserver(forName: MonitoringStatus.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            switch MonitoringStatus.shared.state {
            case .monitoring: self.configure(enabled: true)
            case .failed, .installationFailed: self.stopAfterFailure()
            default: break
            }
        })
        HelperXPCClient.shared.addStateObserver { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .connected(let version, let authorized) = state, authorized, self.isEnabled {
                    if version >= 2 { self.configure(enabled: true) }
                    else { self.stopAfterFailure() }
                } else if case .disconnected = state {
                    self.closeGate(); self.statusKey = self.isEnabled ? "replay.recording.unavailable" : "replay.recording.off"
                    self.publish()
                }
            }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.closeGate()
                self?.statusKey = self?.isEnabled == true ? "replay.recording.suspended" : "replay.recording.off"
                self?.publish()
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isEnabled else { return }
                self.configure(enabled: true)
            })
        }
    }

    /// Call only after the explanatory consent alert was accepted by the user.
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: preference)
        configure(enabled: enabled)
    }

    private func configure(enabled: Bool) {
        closeGate()
        statusKey = enabled ? "replay.recording.starting" : "replay.recording.off"; publish()
        guard enabled else {
            HelperXPCClient.shared.setReplayRecordingEnabled(false) { _ in }
            return
        }
        gate.lock(); let token = epoch; gate.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.openStore(createKey: true)
                DispatchQueue.main.async {
                    self.configureHelperCapture(enabled: true, token: token)
                }
            } catch { DispatchQueue.main.async { self.stopAfterFailure() } }
        }
    }

    private func configureHelperCapture(enabled: Bool, token: Int) {
        gate.lock(); let current = epoch == token; gate.unlock()
        guard current, isEnabled else { return }
        HelperXPCClient.shared.setReplayRecordingEnabled(enabled) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gate.lock()
                let current = self.epoch == token
                if current && ok {
                    self.acceptsAfterNanoseconds = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                    self.accepting = true
                }
                self.gate.unlock()
                guard current else { return }
                if ok { self.statusKey = "replay.recording.on"; self.publish() }
                else { self.stopAfterFailure() }
            }
        }
    }

    private func closeGate() {
        gate.lock(); defer { gate.unlock() }
        accepting = false; epoch += 1
        // Queue insertion shares the ingress lock: all accepted events precede
        // this flush, and all later events are refused before enqueueing.
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.flush() } catch { /* Fail closed; no plaintext fallback. */ }
            self.session = nil; self.sessionDay = nil
        }
    }

    /// Only called for authenticated Helper events with capture metadata. The
    /// wire timestamp is the CGEvent timestamp, never its XPC arrival time.
    func receive(nanoseconds: UInt64, keyCode: UInt16, phase: KeyReplayEvent.Phase, growthKeys: [String]) {
        gate.lock(); defer { gate.unlock() }
        guard accepting, nanoseconds >= acceptsAfterNanoseconds else { return }
        let received = Date()
        let age = max(0, ProcessInfo.processInfo.systemUptime - Double(nanoseconds) / 1_000_000_000)
        let occurred = received.addingTimeInterval(-age)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.dayFormatter.timeZone = .current
                let day = self.dayFormatter.string(from: occurred)
                if self.session == nil || self.sessionDay != day {
                    try self.flush()
                    self.session = KeyReplaySession(startedAt: occurred, originNanoseconds: nanoseconds)
                    self.sessionDay = day
                    let previous = (self.defaults.object(forKey: "keyReplay.sessionOrder.v1") as? NSNumber)?.uint64Value ?? 0
                    self.sessionOrder = previous == UInt64.max ? previous : previous + 1
                    self.defaults.set(NSNumber(value: self.sessionOrder), forKey: "keyReplay.sessionOrder.v1")
                }
                guard let event = self.session?.event(nanoseconds: nanoseconds, keyCode: keyCode, phase: phase, growthKeys: growthKeys) else { return }
                self.events.append(event)
                if self.events.count >= 128 { try self.flush() }
                else if self.pendingFlush == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        do { try self.flush() }
                        catch { DispatchQueue.main.async { self.stopAfterFailure() } }
                    }
                    self.pendingFlush = work
                    self.queue.asyncAfter(deadline: .now() + 2, execute: work)
                }
            } catch { DispatchQueue.main.async { self.stopAfterFailure() } }
        }
    }

    /// A capture gap starts a new session; held keys cannot leak across a gap.
    func captureInterrupted() {
        gate.lock(); defer { gate.unlock() }
        guard accepting else { return }
        queue.async { [weak self] in
        guard let self else { return }
        do { try self.flush() } catch { DispatchQueue.main.async { self.stopAfterFailure() } }
        self.session = nil; self.sessionDay = nil
    } }

    func load(day: String, completion: @escaping (Result<KeyReplayDay, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> KeyReplayDay in
                try self.flush()
                // Merely opening Keyboard must not create a Keychain item.
                guard FileManager.default.fileExists(atPath: self.directory.path) else { return .empty }
                return try self.openStore().load(day: day)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        setEnabled(false)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.events.removeAll(); self.session = nil; self.sessionDay = nil
                // Deletion remains available if the real encryption key is lost.
                let deletionStore = try KeyReplayStore(directory: self.directory, key: SymmetricKey(size: .bits256))
                try deletionStore.deleteAll()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .keyReplayRecordsDeleted, object: nil)
                    completion(true)
                }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }

    func shutdown() {
        gate.lock(); accepting = false; epoch += 1; gate.unlock()
        queue.sync { try? flush() }
    }
    private func flush() throws {
        pendingFlush?.cancel(); pendingFlush = nil
        guard !events.isEmpty, let session, let day = sessionDay else { return }
        try openStore().append(KeyReplayBatch(version: 1, session: session.id, startedAt: session.startedAt, events: events, recordingOrder: sessionOrder), day: day)
        events.removeAll(keepingCapacity: true)
    }
    private func openStore(createKey: Bool = false) throws -> KeyReplayStore {
        if let store { return store }
        let hasRecords = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .contains(where: { ($0 as? URL)?.pathExtension == "ktr" }) ?? false
        let key = try keyProvider?() ?? Self.localKey(createIfMissing: createKey && !hasRecords)
        let value = try KeyReplayStore(directory: directory, key: key)
        store = value; return value
    }
    private func stopAfterFailure() {
        closeGate()
        defaults.set(false, forKey: preference)
        HelperXPCClient.shared.setReplayRecordingEnabled(false) { _ in }
        statusKey = "replay.recording.unavailable"; publish()
    }
    private func publish() { NotificationCenter.default.post(name: .keyReplayRecordingChanged, object: nil) }

    private static func localKey(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xuanlprk.KeyTide.LocalReplay.v1",
            kSecAttrAccount as String: "encryption", kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard result == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        guard createIfMissing else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound)) }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add.removeValue(forKey: kSecReturnData as String); add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}
