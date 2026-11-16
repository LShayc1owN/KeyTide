import AppKit
import Darwin

// ABI reference: Kyome22/OpenMultitouchSupport, OpenMTInternal.h
// b7ec25a56c3767d88800d9ca39137f89927d43db. No contact sequences are logged.
typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
typealias CreateDevice = @convention(c) () -> UnsafeMutableRawPointer?
typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
typealias StartDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
typealias StopDevice = @convention(c) (UnsafeMutableRawPointer) -> Int32
typealias ReleaseDevice = @convention(c) (UnsafeMutableRawPointer) -> Void

final class Probe {
    let lock = NSLock()
    var frames = 0, contacts = 0, invalid = 0, backwards = 0, maxTouches = 0
    var pressureMin = Double.infinity, pressureMax = -Double.infinity
    var firstTimestamp: Double?, lastTimestamp: Double?
    var states: [Int32: Int] = [:]
    var accepting = true
    var frameGaps = 0
    var lastFrame: Int32?
    var estimatedBytes = 0
    struct Previous { let time: Double; let x: Double; let y: Double }
    var previous: [Int32: Previous] = [:]
    var duplicateIDs = 0, contactTimeReversals = 0, equalContactTimes = 0
    var continuousSamples = 0, stationarySamples = 0, interruptedContacts = 0
    var maxSpeed = 0.0, normalizedDistance = 0.0
    var areaMin = Double.infinity, areaMax = -Double.infinity
    var longestFrameGap = 0.0
    func receive(_ data: UnsafeRawPointer?, count: Int32, timestamp: Double, frame: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard (0...32).contains(count), timestamp.isFinite, timestamp >= 0,
              count == 0 || data != nil else { invalid += 1; return }
        frames += 1
        if let lastTimestamp, timestamp < lastTimestamp { backwards += 1 }
        if let lastTimestamp {
            longestFrameGap = max(longestFrameGap, timestamp - lastTimestamp)
            if timestamp < lastTimestamp || timestamp - lastTimestamp > 0.25 {
                interruptedContacts += previous.count
                previous.removeAll()
            }
        }
        if let lastFrame, frame > lastFrame, Int64(frame) - Int64(lastFrame) > 1 { frameGaps += 1 }
        firstTimestamp = firstTimestamp ?? timestamp
        lastTimestamp = timestamp; lastFrame = frame
        maxTouches = max(maxTouches, Int(count))
        estimatedBytes += 24 + Int(count) * 96
        var seen = Set<Int32>()
        for index in 0..<Int(count) {
            let touch = data!.advanced(by: index * 96)
            let sourceTime = touch.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let identifier = touch.loadUnaligned(fromByteOffset: 16, as: Int32.self)
            let state = touch.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            let positionX = touch.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let positionY = touch.loadUnaligned(fromByteOffset: 36, as: Float.self)
            let pressure = touch.loadUnaligned(fromByteOffset: 52, as: Float.self)
            let area = touch.loadUnaligned(fromByteOffset: 48, as: Float.self)
            guard sourceTime.isFinite, sourceTime >= 0, (0...7).contains(state),
                  positionX.isFinite, positionY.isFinite,
                  (-0.05...1.05).contains(positionX), (-0.05...1.05).contains(positionY) else {
                invalid += 1; continue
            }
            contacts += 1; states[state, default: 0] += 1
            guard seen.insert(identifier).inserted else { duplicateIDs += 1; continue }
            // Contact transitions are not mechanical clicks. Derive motion only
            // within an uninterrupted touching interval, never across gaps.
            if state == 3 || state == 4 {
                if state == 4, let old = previous[identifier] {
                    let dt = sourceTime - old.time
                    if dt < 0 { contactTimeReversals += 1 }
                    if dt == 0 { equalContactTimes += 1 }
                    if dt > 0, dt <= 0.25 {
                        let distance = hypot(Double(positionX) - old.x, Double(positionY) - old.y)
                        continuousSamples += 1
                        if distance < 0.00001 { stationarySamples += 1 }
                        normalizedDistance += distance
                        maxSpeed = max(maxSpeed, distance / dt)
                    }
                }
                previous[identifier] = Previous(time: sourceTime, x: Double(positionX), y: Double(positionY))
            } else { previous.removeValue(forKey: identifier) }
            if area.isFinite { areaMin = min(areaMin, Double(area)); areaMax = max(areaMax, Double(area)) }
            if pressure.isFinite {
                pressureMin = min(pressureMin, Double(pressure))
                pressureMax = max(pressureMax, Double(pressure))
            }
        }
        for id in Array(previous.keys) where !seen.contains(id) {
            previous.removeValue(forKey: id); interruptedContacts += 1
        }
    }
}

let probe = Probe()
let callback: FrameCallback = { _, data, count, timestamp, frame in
    probe.receive(data, count: count, timestamp: timestamp, frame: frame)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL)
else { fail("MultitouchSupport unavailable") }
func symbol<Value>(_ name: String, as type: Value.Type) -> Value {
    guard let address = dlsym(library, name) else { fail("Required symbol unavailable: " + name) }
    return unsafeBitCast(address, to: type)
}
let create = symbol("MTDeviceCreateDefault", as: CreateDevice.self)
let register = symbol("MTRegisterContactFrameCallback", as: RegisterCallback.self)
let unregister = symbol("MTUnregisterContactFrameCallback", as: RegisterCallback.self)
let start = symbol("MTDeviceStart", as: StartDevice.self)
let stop = symbol("MTDeviceStop", as: StopDevice.self)
let release = symbol("MTDeviceRelease", as: ReleaseDevice.self)
guard let device = create() else { fail("No default multitouch device") }
let duration = min(60, max(5, Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30))
var before = rusage(); getrusage(RUSAGE_SELF, &before)
let began = ProcessInfo.processInfo.systemUptime
register(device, callback)
let status = start(device, 0)
guard status == 0 else {
    unregister(device, callback); release(device); fail("Device start failed: \(status)")
}
FileHandle.standardError.write(Data("Probe active for \(duration) seconds; no raw touches saved.\n".utf8))
RunLoop.main.run(until: Date().addingTimeInterval(duration))
probe.lock.lock(); probe.accepting = false; probe.lock.unlock()
unregister(device, callback)
let stopStatus = stop(device)
release(device)
var after = rusage(); getrusage(RUSAGE_SELF, &after)
func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
let elapsed = ProcessInfo.processInfo.systemUptime - began
let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
probe.lock.lock()
let report: [String: Any] = [
    "durationSeconds": elapsed, "frames": probe.frames, "contactSamples": probe.contacts,
    "maxSimultaneousContacts": probe.maxTouches, "invalidSamples": probe.invalid,
    "duplicateIDsWithinFrame": probe.duplicateIDs,
    "backwardsContactTimestamps": probe.contactTimeReversals,
    "equalContactTimestamps": probe.equalContactTimes,
    "continuousContactSamples": probe.continuousSamples,
    "stationaryContactSamples": probe.stationarySamples,
    "interruptedContacts": probe.interruptedContacts,
    "longestFrameGapSeconds": probe.longestFrameGap,
    "derivedNormalizedDistance": probe.normalizedDistance,
    "maxNormalizedUnitsPerSecond": probe.maxSpeed,
    "areaFieldMin": probe.areaMin.isFinite ? probe.areaMin as Any : NSNull(),
    "areaFieldMax": probe.areaMax.isFinite ? probe.areaMax as Any : NSNull(),
    "backwardsFrameTimestamps": probe.backwards, "frameNumberGaps": probe.frameGaps,
    "states": Dictionary(uniqueKeysWithValues: probe.states.map { (String($0.key), $0.value) }),
    "pressureFieldMin": probe.pressureMin.isFinite ? probe.pressureMin as Any : NSNull(),
    "pressureFieldMax": probe.pressureMax.isFinite ? probe.pressureMax as Any : NSNull(),
    "sourceTimeSpanSeconds": (probe.lastTimestamp ?? 0) - (probe.firstTimestamp ?? 0),
    "cpuSeconds": cpu, "averageCPUPercent": cpu / elapsed * 100,
    "maxResidentBytes": after.ru_maxrss,
    "uncompressedABIBytesPerMinuteEstimate": Double(probe.estimatedBytes) / elapsed * 60,
    "stopStatus": stopStatus,
    "rawDataPersisted": false,
    "pressureCalibrated": false,
    "scope": "default device only; aggregate probe, not production recorder",
    "unmeasured": ["idle wakeups", "energy", "production disk writes", "physical click attribution"]
]
probe.lock.unlock()
let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data("\n".utf8))
