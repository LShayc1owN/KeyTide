import Foundation

final class HelperXPCClient {
    static let shared = HelperXPCClient()

    enum State: Equatable {
        case idle
        case connecting
        case connected(helperVersion: Int, accessibilityGranted: Bool)
        case disconnected(reason: String)
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionGeneration = 0
    private var _state: State = .idle
    private var eventSink: KeytideEventSinkProtocol?
    private var stateObservers: [(State) -> Void] = []
    private var pendingRequests: [UUID: (String) -> Void] = [:]
    private let makeConnection: () -> NSXPCConnection

    init(makeConnection: @escaping () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: HelperLocations.machServiceName)
    }) {
        self.makeConnection = makeConnection
    }

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    func setEventSink(_ sink: KeytideEventSinkProtocol) {
        lock.lock()
        self.eventSink = sink
        connection?.exportedObject = sink
        lock.unlock()
    }

    func addStateObserver(_ cb: @escaping (State) -> Void) {
        lock.lock(); stateObservers.append(cb); lock.unlock()
        cb(state)
    }

    func connect(completion: ((State) -> Void)? = nil) {
        lock.lock()
        if connection != nil {
            let s = _state
            lock.unlock()
            completion?(s)
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        let c = makeConnection()
        c.remoteObjectInterface = NSXPCInterface(with: KeytideHelperProtocol.self)

        let exported = NSXPCInterface(with: KeytideEventSinkProtocol.self)
        let classes = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        exported.setClasses(
            classes,
            for: #selector(KeytideEventSinkProtocol.receiveEvent(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        c.exportedInterface = exported
        if let sink = eventSink {
            c.exportedObject = sink
        }

        // Requests finish once even when invalidation precedes the proxy's error.
        // Ongoing connection loss is reported separately through state observers.
        let requestID = UUID()
        let completionLock = NSLock()
        var didFinish = false
        let finish: (State) -> Void = { [weak self] state in
            completionLock.lock()
            let already = didFinish
            didFinish = true
            completionLock.unlock()
            guard !already else { return }
            self?.removeRequest(requestID)
            completion?(state)
        }
        pendingRequests[requestID] = { reason in finish(.disconnected(reason: reason)) }

        c.invalidationHandler = { [weak self] in
            let reason = "invalidated"
            self?.transition(to: .disconnected(reason: reason), generation: generation)
            finish(.disconnected(reason: reason))
        }
        c.interruptionHandler = { [weak self] in
            let reason = "interrupted"
            self?.transition(to: .disconnected(reason: reason), generation: generation)
            finish(.disconnected(reason: reason))
        }
        c.resume()
        connection = c
        _state = .connecting
        lock.unlock()

        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            let reason = "\(err)"
            self?.transition(to: .disconnected(reason: reason), generation: generation)
            finish(.disconnected(reason: reason))
        } as? KeytideHelperProtocol

        guard let proxy = proxy else {
            transition(to: .disconnected(reason: "no proxy"), generation: generation)
            finish(.disconnected(reason: "no proxy"))
            return
        }

        proxy.handshake(clientInterfaceVersion: HelperLocations.interfaceVersion) { [weak self] helperVersion, granted in
            if helperVersion != HelperLocations.interfaceVersion {
                NSLog("[HelperXPCClient] interface version mismatch: client=\(HelperLocations.interfaceVersion) helper=\(helperVersion)")
            }
            let newState: State = .connected(helperVersion: helperVersion, accessibilityGranted: granted)
            guard self?.transition(to: newState, generation: generation) == true else {
                finish(.disconnected(reason: "connection changed")); return
            }
            finish(newState)
        }
    }

    func startMonitoring(completion: @escaping (Bool, Int) -> Void) {
        lock.lock()
        let c = connection
        let generation = connectionGeneration
        lock.unlock()
        let requestID = UUID()
        let completionLock = NSLock()
        var completed = false
        let finish: (Bool, Int) -> Void = { [weak self] ok, code in
            completionLock.lock()
            let already = completed
            completed = true
            completionLock.unlock()
            guard !already else { return }
            self?.removeRequest(requestID)
            completion(ok, code)
        }
        guard let c else { finish(false, HelperErrorCode.accessibilityDenied); return }
        guard trackRequest(requestID, generation: generation, cancel: { _ in
            finish(false, HelperErrorCode.tapCreateFailed)
        }) else { finish(false, HelperErrorCode.tapCreateFailed); return }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.transition(to: .disconnected(reason: error.localizedDescription), generation: generation)
            finish(false, HelperErrorCode.tapCreateFailed)
        } as? KeytideHelperProtocol
        guard let proxy else { finish(false, HelperErrorCode.tapCreateFailed); return }
        proxy.startMonitoring { [weak self] ok, code in
            guard let self else { finish(false, HelperErrorCode.tapCreateFailed); return }
            self.lock.lock()
            let current = self.connectionGeneration == generation
            self.lock.unlock()
            finish(current && ok, current ? code : HelperErrorCode.tapCreateFailed)
        }
    }

    /// 重发握手，获取 helper 最新的 accessibility 授权状态。
    /// 用于用户完成 System Settings 授权后刷新 UI。
    func refreshState(completion: @escaping (State) -> Void) {
        lock.lock()
        let c = connection
        let generation = connectionGeneration
        lock.unlock()
        guard let c = c else {
            connect(completion: completion)
            return
        }
        let requestID = UUID()
        let completionLock = NSLock()
        var didFinish = false
        let finish: (State) -> Void = { [weak self] state in
            completionLock.lock()
            let already = didFinish
            didFinish = true
            completionLock.unlock()
            guard !already else { return }
            self?.removeRequest(requestID)
            completion(state)
        }
        guard trackRequest(requestID, generation: generation, cancel: { reason in
            finish(.disconnected(reason: reason))
        }) else { finish(.disconnected(reason: "connection changed")); return }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            let reason = "\(err)"
            self?.transition(to: .disconnected(reason: reason), generation: generation)
            finish(.disconnected(reason: reason))
        } as? KeytideHelperProtocol
        guard let proxy = proxy else {
            transition(to: .disconnected(reason: "no proxy"), generation: generation)
            finish(.disconnected(reason: "no proxy"))
            return
        }
        proxy.handshake(clientInterfaceVersion: HelperLocations.interfaceVersion) { [weak self] v, g in
            if v != HelperLocations.interfaceVersion {
                NSLog("[HelperXPCClient] interface version mismatch: client=\(HelperLocations.interfaceVersion) helper=\(v)")
            }
            let newState: State = .connected(helperVersion: v, accessibilityGranted: g)
            guard self?.transition(to: newState, generation: generation) == true else {
                finish(.disconnected(reason: "connection changed")); return
            }
            finish(newState)
        }
    }

    func stopMonitoring() {
        withProxy({ $0.stopMonitoring() }, fallback: {})
    }

    func setReplayRecordingEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let c = connection, token = connectionGeneration
        let supported: Bool
        if case .connected(let version, _) = _state { supported = version >= 2 } else { supported = false }
        lock.unlock()
        guard supported, let c else { completion(false); return }
        let requestID = UUID()
        let once = NSLock(); var completed = false
        let finish: (Bool) -> Void = { [weak self] ok in
            once.lock(); let already = completed; completed = true; once.unlock()
            guard !already else { return }
            self?.removeRequest(requestID)
            completion(ok)
        }
        guard trackRequest(requestID, generation: token, cancel: { _ in finish(false) }) else { finish(false); return }
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in finish(false) } as? KeytideHelperProtocol
        guard let proxy else { finish(false); return }
        proxy.setReplayRecordingEnabled(enabled) { [weak self] ok in
            guard let self else { finish(false); return }
            self.lock.lock(); let valid = self.connectionGeneration == token; self.lock.unlock()
            finish(ok && valid)
        }
    }

    /// 让 helper 主动调一次 `AXIsProcessTrustedWithOptions(prompt: true)`，把自己注册进
    /// 系统设置的辅助功能列表。completion 回调发生在 XPC 队列，调用方自行切主队列。
    func promptAccessibility(completion: @escaping (Bool) -> Void) {
        lock.lock()
        let hasConnection = connection != nil
        lock.unlock()

        let sendPrompt: () -> Void = { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            self.sendPromptAccessibility(completion: completion)
        }

        guard !hasConnection else {
            sendPrompt()
            return
        }

        connect { state in
            guard case .connected = state else {
                completion(false)
                return
            }
            sendPrompt()
        }
    }

    func disconnect() {
        lock.lock()
        let c = connection
        connection = nil
        connectionGeneration += 1
        _state = .idle
        let cancellations = Array(pendingRequests.values)
        pendingRequests.removeAll()
        lock.unlock()
        c?.invalidate()
        cancellations.forEach { $0("disconnected") }
    }

    // MARK: - Private

    private func sendPromptAccessibility(completion: @escaping (Bool) -> Void) {
        lock.lock()
        let c = connection
        let generation = connectionGeneration
        lock.unlock()

        guard let c = c else {
            completion(false)
            return
        }

        let requestID = UUID()
        let completionLock = NSLock()
        var completed = false
        let finish: (Bool) -> Void = { [weak self] granted in
            completionLock.lock(); let already = completed; completed = true; completionLock.unlock()
            guard !already else { return }
            self?.removeRequest(requestID)
            completion(granted)
        }
        guard trackRequest(requestID, generation: generation, cancel: { _ in finish(false) }) else { finish(false); return }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.transition(to: .disconnected(reason: "\(err)"), generation: generation)
            finish(false)
        } as? KeytideHelperProtocol

        guard let proxy = proxy else {
            finish(false)
            return
        }

        proxy.promptAccessibility { [weak self] granted in
            guard let self else { finish(false); return }
            self.lock.lock(); let current = self.connectionGeneration == generation; self.lock.unlock()
            finish(current && granted)
        }
    }

    private func trackRequest(_ id: UUID, generation: Int, cancel: @escaping (String) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connection != nil, connectionGeneration == generation else { return false }
        pendingRequests[id] = cancel
        return true
    }

    private func removeRequest(_ id: UUID) {
        lock.lock(); pendingRequests.removeValue(forKey: id); lock.unlock()
    }

    private func withProxy<T>(_ fn: (KeytideHelperProtocol) -> T,
                              fallback: () -> T) -> T {
        lock.lock()
        let c = connection
        let generation = connectionGeneration
        lock.unlock()
        guard let c = c else { return fallback() }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            guard self?.transition(to: .disconnected(reason: "\(err)"), generation: generation) == true else { return }
        } as? KeytideHelperProtocol
        return proxy.map(fn) ?? fallback()
    }

    @discardableResult
    private func transition(to state: State, generation: Int? = nil) -> Bool {
        var observers: [(State) -> Void] = []
        var invalidatedConnection: NSXPCConnection?
        var cancellations: [(String) -> Void] = []
        lock.lock()
        if let generation, generation != connectionGeneration { lock.unlock(); return false }
        _state = state
        observers = stateObservers
        if case .disconnected = state {
            connectionGeneration += 1
            invalidatedConnection = connection
            connection = nil
            cancellations = Array(pendingRequests.values)
            pendingRequests.removeAll()
        }
        lock.unlock()
        invalidatedConnection?.invalidate()
        observers.forEach { $0(state) }
        if case .disconnected(let reason) = state { cancellations.forEach { $0(reason) } }
        return true
    }
}
