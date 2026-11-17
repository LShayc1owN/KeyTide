import AppKit
import MetalKit
import SceneKit

/// Adapters reuse the production Growth scenes, including their cameras/materials.
struct GrowthReplayPressScene {
    let device: MTLDevice
    let profile: MechanicalPressProfile
    let prepare: ([GrowthKeyboardKeyUsage], NSColor) -> Void
    let draw: (MTKView, MTLCommandQueue, [String: CGFloat]) -> [String: CGRect]
    let reset: () -> Void
    let makeLegends: (() -> KeyboardLegendOverlay)?

    init(mac scene: GrowthKeyboard3DScene) {
        device = scene.metalDevice; profile = .light
        prepare = scene.prepareLive
        draw = scene.drawLive
        reset = { scene.applyLivePress([:]) }
        makeLegends = nil
    }
    init(mechanical scene: MechanicalKeyboardScene) {
        device = scene.metalDevice; profile = .deep
        prepare = scene.prepareLive
        draw = scene.drawLive
        reset = { scene.applyFullPress([:]) }
        makeLegends = nil
    }
}

/// The MTKView is paused. Only playback transitions request frames; a long
/// recorded idle gap schedules its next event directly, without a render loop.
final class GrowthReplayPressSurface: NSView, MTKViewDelegate {
    private let scene: GrowthReplayPressScene
    private let metal: MTKView
    private let queue: MTLCommandQueue
    private let legends: KeyboardLegendOverlay?
    private let imageSize: CGSize
    private let supported: Set<String>
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var offsets: [String: CGFloat] = [:]
    private var held: [String: (time: Double, initial: CGFloat)] = [:]
    private var released: [String: (time: Double, initial: CGFloat)] = [:]
    private var plan = GrowthReplayPressPlan(day: .empty)
    private var cursor = 0
    private var began: Double = 0
    private var values: [GrowthKeyboardKeyUsage] = []
    private var target: [String: Int] = [:]
    private var background = NSColor.clear
    private var participated = 0
    private var completion: (() -> Void)?
    var onFailure: (() -> Void)?
    var onProgress: (([GrowthKeyboardKeyUsage], Int) -> Void)?
    var onRects: (([String: CGRect]) -> Void)?
    private(set) var isAnimating = false
    private(set) var drawCount = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(scene: GrowthReplayPressScene, size: CGSize, supported: Set<String>) {
        self.scene = scene; self.imageSize = size; self.supported = supported
        metal = MTKView(frame: CGRect(origin: .zero, size: size), device: scene.device)
        queue = scene.device.makeCommandQueue()!
        legends = scene.makeLegends?()
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.isOpaque = false
        metal.isPaused = true; metal.enableSetNeedsDisplay = false
        metal.colorPixelFormat = .bgra8Unorm_srgb; metal.depthStencilPixelFormat = .depth32Float_stencil8
        metal.sampleCount = 4; metal.delegate = self; metal.layer?.isOpaque = false
        addSubview(metal)
        if let legends { addSubview(legends) }
        isHidden = true; setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pending?.cancel() }
    override func layout() {
        super.layout()
        // Native view coordinates follow the displayed frame. Canonical scene
        // coordinates belong only to the legend view, never the MTKView frame.
        metal.frame = bounds
        if let window {
            let pixels = window.convertToBacking(convert(bounds, to: nil)).size
            if pixels.width > 0, pixels.height > 0, metal.drawableSize != pixels {
                metal.autoResizeDrawable = false
                metal.drawableSize = pixels
            }
        }
        if let legends {
            legends.frame = bounds
            legends.bounds = CGRect(origin: .zero, size: imageSize)
        }
    }
    func play(_ plan: GrowthReplayPressPlan, values: [GrowthKeyboardKeyUsage],
              target: [GrowthKeyboardKeyUsage], background: NSColor, completion: @escaping () -> Void) {
        cancel()
        self.plan = plan; self.completion = completion; self.values = values
        self.target = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0.count) })
        self.background = background; participated = 0
        cursor = 0; began = ProcessInfo.processInfo.systemUptime
        scene.prepare(values, background)
        isAnimating = true; isHidden = false
        needsLayout = true; layoutSubtreeIfNeeded()
        tick()
    }
    private func tick() {
        pending = nil
        guard isAnimating, !isHiddenOrHasHiddenAncestor else { cancel(); return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        if let stream = plan.stream {
            let token = generation
            stream.take(through: elapsed) { [weak self] slice in
                guard let self, self.generation == token, self.isAnimating else { return }
                if slice.failed { self.cancel(); self.onFailure?(); return }
                self.consume(slice.entries, elapsed: elapsed, nextSeconds: slice.nextSeconds,
                    nextStartsSession: slice.nextStartsSession)
            }
        } else {
            let start = cursor
            while cursor < plan.entries.count && elapsed >= plan.entries[cursor].seconds { cursor += 1 }
            let next = cursor < plan.entries.count ? plan.entries[cursor] : nil
            consume(Array(plan.entries[start..<cursor]), elapsed: elapsed,
                nextSeconds: next?.seconds, nextStartsSession: next?.startsSession ?? false)
        }
    }
    private func consume(_ entries: [KeyReplayDay.Entry], elapsed: Double,
                         nextSeconds: Double?, nextStartsSession: Bool) {
        var changed = false
        var additions: [String: Int] = [:]
        let attack = min(0.055, scene.profile.duration / 3)
        let release = min(0.13, scene.profile.duration * 0.6)
        for item in entries {
            if item.startsSession { held.removeAll(); released.removeAll(); offsets = [:] }
            let event = item.event
            if let id = MechanicalKeyboardView.physicalKeyID(event.keyCode), supported.contains(id) {
                if event.phase == .up {
                    if let press = held[id] {
                        let reached = press.initial + (scene.profile.travel - press.initial)
                            * min(1, max(0, (item.seconds - press.time) / attack))
                        // A compressed tap can begin and end within one screen
                        // frame. Keep its existing press effect visible briefly.
                        let minimum = plan.isAccelerated ? scene.profile.travel * 0.65 : 0
                        released[id] = (item.seconds, max(minimum, reached))
                    }
                    held.removeValue(forKey: id)
                } else {
                    held[id] = (item.seconds, offsets[id] ?? 0)
                    released.removeValue(forKey: id)
                    if event.phase == .pulse {
                        held.removeValue(forKey: id)
                        released[id] = (item.seconds, scene.profile.travel)
                    }
                }
            }
            if !event.growthKeys.isEmpty {
                participated += 1
                for id in Set(event.growthKeys) { additions[id, default: 0] += 1 }
                changed = true
            }
        }
        var moving = false
        offsets = [:]
        for (id, press) in held {
            let t = min(1, max(0, (elapsed - press.time) / attack))
            offsets[id] = press.initial + (scene.profile.travel - press.initial) * t
            if t < 1 { moving = true }
        }
        released = released.filter { elapsed - $0.value.time < release }
        for (id, press) in released {
            let t = min(1, max(0, (elapsed - press.time) / release))
            offsets[id] = press.initial * (1 - t) * (1 - t)
            moving = true
        }
        if changed {
            // Every captured event is consumed in order. Update the 77-key
            // geometry once per visible frame, even for a dense full-day replay.
            values = values.map { usage in
                let remaining = max(0, (target[usage.id] ?? usage.count) - usage.count)
                return .init(id: usage.id, count: usage.count + min(remaining, additions[usage.id] ?? 0))
            }
            scene.prepare(values, background); onProgress?(values, participated)
        }
        // Missing key-up at the end of an interrupted capture is released here.
        if (nextSeconds == nil || nextStartsSession) && !held.isEmpty {
            for (id, _) in held {
                let minimum = plan.isAccelerated ? scene.profile.travel * 0.65 : 0
                released[id] = (elapsed, max(minimum, offsets[id] ?? scene.profile.travel))
            }
            held.removeAll(); moving = true
        }
        metal.draw()
        guard nextSeconds != nil || moving else {
            isAnimating = false
            releaseReplayData()
            let finish = completion; completion = nil; finish?(); return
        }
        let untilNext = nextSeconds.map { max(0, $0 - elapsed) } ?? 1.0 / 60
        // Compressed events may be microseconds apart. Consume them together at
        // the next display frame instead of scheduling a draw for each event.
        let delay = moving ? 1.0 / 60 : max(1.0 / 60, untilNext)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }; self.tick()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, delay), execute: work)
    }
    func draw(in view: MTKView) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let rects = scene.draw(view, queue, offsets)
        drawCount += 1
        legends?.pixelScale = view.drawableSize.width / imageSize.width
        legends?.needsDisplay = true
        onRects?(rects)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if isAnimating { metal.draw() }
    }
    func cancel() {
        generation += 1; pending?.cancel(); pending = nil
        held.removeAll(); released.removeAll(); offsets = [:]
        completion = nil; isAnimating = false; cursor = 0
        releaseReplayData()
        scene.reset(); isHidden = true
    }

    private func releaseReplayData() {
        plan.stream?.cancel()
        plan = GrowthReplayPressPlan(day: .empty)
        values = []
        target = [:]
        cursor = 0
    }
}
