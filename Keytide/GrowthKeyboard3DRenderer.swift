import Cocoa
import QuartzCore

struct KeyboardViewportState {
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGSize.zero
    func frame(in viewport: CGSize) -> CGRect {
        CGRect(x: (viewport.width - viewport.width * scale) / 2 + offset.width,
            y: (viewport.height - viewport.height * scale) / 2 + offset.height,
            width: viewport.width * scale, height: viewport.height * scale)
    }
    mutating func zoom(by factor: CGFloat, at point: CGPoint, in viewport: CGSize) {
        guard factor.isFinite, factor > 0, viewport.width > 0, viewport.height > 0 else { return }
        let old = frame(in: viewport)
        let next = min(2.5, max(0.75, scale * factor))
        let ratio = next / scale
        let origin = CGPoint(x: point.x - (point.x - old.minX) * ratio,
            y: point.y - (point.y - old.minY) * ratio)
        scale = next
        offset = CGSize(width: origin.x - (viewport.width - viewport.width * scale) / 2,
            height: origin.y - (viewport.height - viewport.height * scale) / 2)
        constrain(in: viewport)
    }
    mutating func pan(by delta: CGSize, in viewport: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        offset.width += delta.width; offset.height += delta.height
        constrain(in: viewport)
    }
    mutating func constrain(in viewport: CGSize) {
        let horizontal = max(0, viewport.width * (scale - 1) / 2)
        let vertical = max(0, viewport.height * (scale - 1) / 2)
        offset.width = min(horizontal, max(-horizontal, offset.width))
        offset.height = min(vertical, max(-vertical, offset.height))
    }
    mutating func reset() { scale = 1; offset = .zero }
}

/// Static SceneKit images with a three-frame LRU. Hover/count layers never invoke
/// SceneKit. Date scrubbing is coalesced; hiding cancels work before it can render.
final class GrowthKeyboard3DRenderer: NSView {
    typealias RenderFrame = ([GrowthKeyboardKeyUsage], NSColor) -> GrowthKeyboard3DFrame
    typealias ReplayPress = (GrowthReplayPressPlan, [GrowthKeyboardKeyUsage], NSColor, @escaping () -> Void) -> (() -> Void)
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private struct CacheKey: Equatable {
        let values: [GrowthKeyboardKeyUsage]
        let background: NSColor
        let pixelScale: CGFloat
    }
    private struct CachedFrame {
        let key: CacheKey
        let frame: GrowthKeyboard3DFrame
    }
    let sceneLayout: EditorialKeyboardSceneLayout
    private let renderFrame: RenderFrame?
    private let renderDetailedFrame: (([GrowthKeyboardKeyUsage], NSColor, CGFloat) -> GrowthKeyboard3DFrame)?
    private var snapshotPixelScale: CGFloat = 2
    private let reduceMotion: () -> Bool
    private let replayPress: ReplayPress?
    private let replaySceneFactory: (() -> GrowthReplayPressScene)?
    private var replaySurface: GrowthReplayPressSurface?
    private var cancelPress: (() -> Void)?
    private var replayFrom: [GrowthKeyboardKeyUsage]?
    private var recordedReplay: GrowthReplayPressPlan?
    private var pressRects: [String: CGRect]?
    var isReplayingPress: Bool { cancelPress != nil }
    var replayDrawCount: Int { replaySurface?.drawCount ?? 0 }
    private let schedule: Schedule
    private let imageSize: CGSize
    private let bakesLegends: Bool
    private let usesTransparentCanvas: Bool
    private var scene: GrowthKeyboard3DScene?
    private var cache: [CachedFrame] = []
    private var currentKey: CacheKey?
    private var values: [GrowthKeyboardKeyUsage] = []
    private var requestedValues: [GrowthKeyboardKeyUsage] = []
    private var onPresented: (() -> Void)?
    private var animatesPresentation = false
    private var cancelPending: (() -> Void)?
    private var generation = 0
    private let overlay = CALayer()
    private let legendView: KeyboardLegendOverlay
    private var counts: [String: CATextLayer] = [:]
    private var tracking: NSTrackingArea?
    private var hoveredID: String?
    private(set) var selectedKeyID: String?
    private(set) var displayedFrame: GrowthKeyboard3DFrame?
    private(set) var isActive = false
    private(set) var renderCount = 0
    var cachedFrameCount: Int { cache.count }
    var hasScheduledRender: Bool { cancelPending != nil }
    var onSelectionChanged: ((GrowthKeyboardKeyUsage?) -> Void)?
    var onReplayProgress: (([GrowthKeyboardKeyUsage], Int) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(layout: EditorialKeyboardSceneLayout, renderFrame: RenderFrame? = nil,
         imageSize: CGSize = GrowthKeyboard3DScene.size, bakesLegends: Bool = false,
         usesTransparentCanvas: Bool = false,
         renderDetailedFrame: (([GrowthKeyboardKeyUsage], NSColor, CGFloat) -> GrowthKeyboard3DFrame)? = nil,
         replaySceneFactory: (() -> GrowthReplayPressScene)? = nil,
         replayPress: ReplayPress? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         schedule: @escaping Schedule = GrowthKeyboard3DRenderer.scheduleOnMain) {
        sceneLayout = layout
        self.renderFrame = renderFrame
        self.renderDetailedFrame = renderDetailedFrame
        legendView = KeyboardLegendOverlay(keys: layout.keys)
        self.replaySceneFactory = replaySceneFactory
        self.replayPress = replayPress
        self.reduceMotion = reduceMotion
        self.schedule = schedule
        self.imageSize = imageSize
        self.bakesLegends = bakesLegends
        self.usesTransparentCanvas = usesTransparentCanvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        overlay.zPosition = 10
        overlay.anchorPoint = .zero
        overlay.isHidden = true
        overlay.bounds = CGRect(origin: .zero, size: imageSize)
        layer?.addSublayer(overlay)
        addSubview(legendView)
        for key in layout.keys {
            let count = CATextLayer()
            count.contentsScale = 2; count.alignmentMode = .center
            count.opacity = 0
            overlay.addSublayer(count); counts[key.id] = count
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("growth.mode.3d.description", comment: "3D Growth"))
        setAccessibilityHelp(NSLocalizedString("growth.keyboard.help", comment: "Growth Keyboard"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { cancelPending?(); cancelPress?() }

    func apply(_ incoming: [GrowthKeyboardKeyUsage], animated: Bool = false, replayFrom: [GrowthKeyboardKeyUsage]? = nil,
               recordedReplay: GrowthReplayPressPlan? = nil, onPresented: (() -> Void)? = nil) {
        cancelRender()
        self.replayFrom = replayFrom
        self.recordedReplay = recordedReplay
        let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        requestedValues = sceneLayout.keys.map { byID[$0.id] ?? .init(id: $0.id, count: 0) }
        self.onPresented = onPresented
        animatesPresentation = animated
        requestFrame()
        if displayedFrame == nil { notifySelection() }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { requestFrame() }
        else {
            // Keep the latest snapshot acknowledgement for reactivation. Cancelling
            // work must not leave its date/details behind when that image resumes.
            replayFrom = nil
            recordedReplay = nil
            cancelRender()
            layer?.removeAnimation(forKey: "growthReplayFrame")
            // Core Animation stores CATransition under its reserved key.
            layer?.removeAnimation(forKey: kCATransition)
            clearHover()
        }
    }

    func refreshFrame() {
        currentKey = nil
        requestFrame()
    }

    private func cancelRender() {
        generation &+= 1
        cancelPending?(); cancelPending = nil
        cancelPress?(); cancelPress = nil
        replaySurface?.cancel(); pressRects = nil
        if let currentKey { values = currentKey.values }
        updateOverlay(); needsDisplay = true
    }

    func cancelReplayAnimation() {
        replayFrom = nil
        recordedReplay = nil
        cancelRender()
        layer?.removeAnimation(forKey: kCATransition)
    }

    private func requestFrame() {
        guard isActive, !requestedValues.isEmpty else { return }
        let background = usesTransparentCanvas ? NSColor.clear
            : KeyboardVisualizationCanvasView.backgroundColor(for: effectiveAppearance, showsGrowth: true)
        let key = CacheKey(values: requestedValues, background: background, pixelScale: snapshotPixelScale)
        cancelRender()
        guard key != currentKey || recordedReplay?.entries.isEmpty == false else { completePresentation(); return }
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let cached = cache.remove(at: index)
            cache.append(cached)
            presentAfterPress(cached.frame, key: key)
            return
        }
        // Replay keeps the previous image/counts until the next frame is ready;
        // the controller commits its date label in the same presentation callback.
        let token = generation
        cancelPending = schedule(0.08) { [weak self] in
            guard let self, self.isActive, self.generation == token else { return }
            self.cancelPending = nil
            let frame: GrowthKeyboard3DFrame
            if let renderDetailedFrame = self.renderDetailedFrame { frame = renderDetailedFrame(key.values, key.background, key.pixelScale) }
            else if let renderFrame = self.renderFrame { frame = renderFrame(key.values, key.background) }
            else {
                if self.scene == nil { self.scene = GrowthKeyboard3DScene(self.sceneLayout) }
                frame = self.scene!.render(values: key.values, backgroundColor: key.background, pixelScale: key.pixelScale)
            }
            self.renderCount += 1
            self.cache.append(CachedFrame(key: key, frame: frame))
            if self.cache.count > 3 { self.cache.removeFirst() }
            self.presentAfterPress(frame, key: key)
        }
    }

    private func presentAfterPress(_ frame: GrowthKeyboard3DFrame, key: CacheKey) {
        guard let from = replayFrom, let plan = recordedReplay, !plan.entries.isEmpty, animatesPresentation,
              !reduceMotion() else {
            present(frame, key: key); return
        }
        let token = generation
        var finishedSynchronously = false
        let finish: () -> Void = { [weak self] in
            guard !finishedSynchronously else { return }
            finishedSynchronously = true
            guard let self, self.isActive, self.generation == token else { return }
            self.cancelPress = nil
            self.replaySurface?.cancel(); self.pressRects = nil
            self.present(frame, key: key)
        }
        if let replayPress {
            let cancel = replayPress(plan, from, key.background, finish)
            if !finishedSynchronously { cancelPress = cancel }
        } else {
            if replaySurface == nil {
                let backend: GrowthReplayPressScene
                if let replaySceneFactory { backend = replaySceneFactory() }
                else {
                    guard renderFrame == nil else { present(frame, key: key); return }
                    if scene == nil { scene = GrowthKeyboard3DScene(sceneLayout) }
                    backend = GrowthReplayPressScene(mac: scene!)
                }
                let surface = GrowthReplayPressSurface(scene: backend, size: imageSize,
                    supported: Set(sceneLayout.keys.map(\.id)))
                surface.onRects = { [weak self] rects in self?.pressRects = rects; self?.updateOverlay() }
                surface.onProgress = { [weak self] values, events in
                    guard let self else { return }
                    self.values = values; self.updateOverlay(); self.notifySelection()
                    self.onReplayProgress?(values, events)
                }
                surface.frame = imageRect
                addSubview(surface, positioned: .below, relativeTo: legendView); replaySurface = surface
            }
            if displayedFrame == nil { displayedFrame = frame }
            values = from; overlay.isHidden = false
            cancelPress = { [weak self] in self?.replaySurface?.cancel() }
            replaySurface?.play(plan, values: from, target: key.values, background: key.background, completion: finish)
        }
        needsDisplay = true
    }

    private func present(_ frame: GrowthKeyboard3DFrame, key: CacheKey) {
        if animatesPresentation && displayedFrame != nil && !reduceMotion() {
            let transition = CATransition()
            transition.type = .fade; transition.duration = 0.12
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(transition, forKey: "growthReplayFrame")
        }
        replayFrom = nil
        recordedReplay = nil
        values = key.values
        displayedFrame = frame; currentKey = key
        overlay.isHidden = false
        hoveredID = nil
        updateOverlay()
        notifySelection()
        needsDisplay = true
        completePresentation()
        if key.pixelScale != snapshotPixelScale { requestFrame() }
    }

    private func completePresentation() {
        let completion = onPresented
        onPresented = nil
        completion?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        requestFrame()
    }

    private var imageRect: CGRect {
        let size = imageSize
        let scale = max(0.01, min((bounds.width - 24) / size.width, (bounds.height - 16) / size.height))
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    override func layout() {
        super.layout()
        let rect = imageRect, scale = rect.width / imageSize.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        replaySurface?.frame = rect
        legendView.frame = rect
        legendView.bounds = CGRect(origin: .zero, size: imageSize)
        overlay.position = rect.origin
        overlay.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        // Clear the previous snapshot when the visible key area changes size.
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard replaySurface?.isHidden != false else { return }
        displayedFrame?.image.draw(in: imageRect, from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Export the last fully presented frame, independent of hover/selection and view size.
    /// Does not request a new frame or modify the replay/cache state.
    func exportImage() -> NSImage? {
        guard let frame = displayedFrame else { return nil }
        guard let bitmap = KeyboardImageBitmap.make(size: imageSize, draw: {
            frame.image.draw(in: CGRect(origin: .zero, size: self.imageSize), from: .zero,
                             operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            guard !self.bakesLegends else { return }
            KeyboardLegendLayout.draw(keys: self.sceneLayout.keys, rects: frame.rects)
        }) else { return nil }
        return KeyboardImageBitmap.image(bitmap)
    }

    private func updateOverlay() {
        guard let frame = displayedFrame else { return }
        legendView.isHidden = bakesLegends
        legendView.rects = pressRects ?? frame.rects
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (key, usage) in zip(sceneLayout.keys, values) {
            guard let rect = (pressRects ?? frame.rects)[key.id], let count = counts[key.id] else { continue }
            let showCount = key.id == hoveredID || key.id == selectedKeyID
            count.frame = CGRect(x: rect.minX + 2, y: rect.minY + rect.height * 0.78,
                width: max(1, rect.width - 4), height: rect.height * 0.22)
            let text = NumberFormatter.localizedString(from: NSNumber(value: usage.count), number: .decimal)
            var font = min(11, count.frame.height * 0.80)
            let width = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font, weight: .regular)]).width
            font *= min(1, count.frame.width / max(1, width))
            count.string = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font, weight: .regular),
                .foregroundColor: KeyboardLegendLayout.ink])
            count.opacity = showCount ? 1 : 0
        }
        CATransaction.commit()
    }

    func updateDisplayResolution() {
        let pixels = window?.convertToBacking(convert(imageRect, to: nil)).width ?? imageRect.width * 2
        let scale = min(5, max(2, ceil(pixels / imageSize.width * 2) / 2))
        guard scale != snapshotPixelScale else { return }
        snapshotPixelScale = scale
        counts.values.forEach { $0.contentsScale = scale }
        legendView.layer?.contentsScale = window?.backingScaleFactor ?? 2
        if !isReplayingPress { requestFrame() }
    }

    func selectKey(_ id: String?) {
        selectedKeyID = id.flatMap { candidate in sceneLayout.keys.contains { $0.id == candidate } ? candidate : nil }
        updateOverlay(); notifySelection()
    }
    func clearHover() { hoveredID = nil; updateOverlay() }
    func selectedKeyFrame() -> CGRect? {
        guard let selectedKeyID, let frame = (pressRects ?? displayedFrame?.rects ?? [:])[selectedKeyID] else { return nil }
        let scale = imageRect.width / imageSize.width
        return CGRect(x: imageRect.minX + frame.minX * scale,
            y: imageRect.minY + frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale)
    }
    private func notifySelection() {
        let detailValues = displayedFrame == nil ? requestedValues : values
        let selected = selectedKeyID.flatMap { id in detailValues.first { $0.id == id } }
        onSelectionChanged?(selected)
    }
    func keyID(at point: CGPoint) -> String? {
        guard let frame = displayedFrame, imageRect.contains(point) else { return nil }
        let scale = imageRect.width / imageSize.width
        let local = CGPoint(x: (point.x - imageRect.minX) / scale, y: (point.y - imageRect.minY) / scale)
        return sceneLayout.keys.reversed().first { (pressRects ?? frame.rects)[$0.id]?.contains(local) == true }?.id
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let id = keyID(at: convert(event.locationInWindow, from: nil))
        if id != hoveredID { hoveredID = id; updateOverlay() }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectKey(keyID(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.performClose(nil) }
        else if [123, 124, 125, 126].contains(event.keyCode) {
            let keys = sceneLayout.keys
            let index = selectedKeyID.flatMap { id in keys.firstIndex { $0.id == id } } ?? 0
            let origin = keys[index].rect
            let target: Int
            if event.keyCode == 123 { target = max(0, index - 1) }
            else if event.keyCode == 124 { target = min(keys.count - 1, index + 1) }
            else {
                let candidates = keys.indices.filter {
                    event.keyCode == 125 ? keys[$0].rect.midY > origin.midY + 2 : keys[$0].rect.midY < origin.midY - 2
                }
                target = candidates.min {
                    let a = keys[$0].rect, b = keys[$1].rect
                    return abs(a.midY - origin.midY) * 100 + abs(a.midX - origin.midX) <
                        abs(b.midY - origin.midY) * 100 + abs(b.midX - origin.midX)
                } ?? index
            }
            selectKey(keys[target].id)
        } else { super.keyDown(with: event) }
    }
    private static func scheduleOnMain(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

/// Explicit pixels and flipped drawing coordinates, independent of the display's backing scale.
enum KeyboardImageBitmap {
    static func make(size: CGSize, scale: CGFloat = 2, draw: () -> Void) -> NSBitmapImageRep? {
        guard size.width > 0, size.height > 0, scale > 0,
              size.width * scale <= 8192, size.height * scale <= 8192,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        cg.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func image(_ bitmap: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
