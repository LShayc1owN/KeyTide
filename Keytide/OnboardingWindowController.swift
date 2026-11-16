import AppKit
import QuartzCore

/// A stable three-step welcome. All installation and permission effects remain
/// in AppDelegate; this controller only presents their current state.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let progress: OnboardingProgress
    private let status: MonitoringStatus
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton()
    private let secondary = NSButton()
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let stepIndicator = WelcomeStepIndicator()
    private let welcomePage = NSStackView()
    private let setupPage = NSStackView()
    private let readyPage = NSStackView()
    private let serviceRow = WelcomeStateRow(title: NSLocalizedString("welcome.service", comment: ""))
    private let permissionRow = WelcomeStateRow(title: NSLocalizedString("welcome.permission", comment: ""))
    private let captureRow = WelcomeStateRow(title: NSLocalizedString("welcome.capture", comment: ""))
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let readySignal = WelcomeReadySignal()
    private let firstPressLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    private var statsObserver: UUID?
    private var setupRequested = false
    private var showingSetup: Bool
    private var didReceiveFirstInput = false
    private var inputBaseline: Int?
    private var lastPresentation = ""

    var onRecheck: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onAuthorize: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenStats: (() -> Void)?
    var onOpenKeyboard: (() -> Void)?
    var onOpenExample: (() -> Void)?
    var onClose: (() -> Void)?
    var setLogin: ((Bool) throws -> Void)?
    var loginEnabled: (() -> Bool)?

    init(progress: OnboardingProgress, status: MonitoringStatus = .shared) {
        self.progress = progress
        self.status = status
        showingSetup = progress.stage == .setup
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("welcome.window", comment: "")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        window.contentView = WelcomeBackgroundView()
        build()
        observer = NotificationCenter.default.addObserver(forName: MonitoringStatus.didChange, object: status, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.render()
        }
        HelperXPCClient.shared.addStateObserver { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.window?.isVisible == true else { return }
                self?.render()
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        stopObservingInput()
    }

    private func build() {
        guard let root = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 68).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 68).isActive = true
        root.addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        stepIndicator.translatesAutoresizingMaskIntoConstraints = false
        stepIndicator.widthAnchor.constraint(equalToConstant: 66).isActive = true
        stepIndicator.heightAnchor.constraint(equalToConstant: 8).isActive = true
        for item in [titleLabel, bodyLabel, stepIndicator] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }

        for page in [welcomePage, setupPage, readyPage] {
            page.orientation = .vertical
            page.alignment = .centerX
            page.spacing = 18
            page.wantsLayer = true
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
        }
        buildWelcome()
        buildSetup()
        buildReady()

        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.bezelColor = .controlAccentColor
        primary.contentTintColor = .white
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryAction)
        primary.widthAnchor.constraint(equalToConstant: 224).isActive = true
        secondary.isBordered = false
        secondary.font = .systemFont(ofSize: 12)
        secondary.contentTintColor = .secondaryLabelColor
        secondary.target = self
        secondary.action = #selector(secondaryAction)
        for item in [primary, secondary] as [NSView] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        login.title = NSLocalizedString("welcome.login", comment: "")
        login.font = .systemFont(ofSize: 12)
        login.target = self
        login.action = #selector(loginChanged)
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = .systemRed
        loginError.alignment = .center
        for item in [login, loginError] as [NSView] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stepIndicator.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            stepIndicator.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: stepIndicator.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -38),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            primary.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            primary.bottomAnchor.constraint(equalTo: secondary.topAnchor, constant: -8),
            secondary.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            secondary.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            login.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            login.bottomAnchor.constraint(equalTo: primary.topAnchor, constant: -15),
            loginError.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
            loginError.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -38),
            loginError.bottomAnchor.constraint(equalTo: login.topAnchor, constant: -6)
        ])
        for page in [welcomePage, setupPage, readyPage] {
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 24),
                page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 44),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -44),
                page.bottomAnchor.constraint(lessThanOrEqualTo: login.topAnchor, constant: -12)
            ])
        }
        render()
    }

    private func buildWelcome() {
        let preview = WelcomePreviewCard()
        welcomePage.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: welcomePage.widthAnchor).isActive = true
        let privacy = text("welcome.privacy", size: 11, secondary: true)
        welcomePage.addArrangedSubview(privacy)
        welcomePage.setCustomSpacing(15, after: preview)
    }

    private func buildSetup() {
        let card = WelcomeCardView()
        let stack = NSStackView(views: [serviceRow, permissionRow, captureRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 17, left: 18, bottom: 17, right: 18)
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        setupPage.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: setupPage.widthAnchor).isActive = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 3
        setupPage.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: setupPage.widthAnchor).isActive = true
    }

    private func buildReady() {
        readySignal.translatesAutoresizingMaskIntoConstraints = false
        readySignal.widthAnchor.constraint(equalToConstant: 68).isActive = true
        readySignal.heightAnchor.constraint(equalToConstant: 68).isActive = true
        readyPage.addArrangedSubview(readySignal)
        firstPressLabel.font = .systemFont(ofSize: 15, weight: .medium)
        readyPage.addArrangedSubview(firstPressLabel)
        let menuReminder = text("welcome.menuReminder", size: 12, secondary: true)
        readyPage.addArrangedSubview(menuReminder)
    }

    private func text(_ key: String, size: CGFloat, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: NSLocalizedString(key, comment: ""))
        label.font = .systemFont(ofSize: size)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.alignment = .center
        return label
    }

    func show(restart: Bool = false) {
        guard let window else { return }
        if restart {
            showingSetup = false
            setupRequested = false
            didReceiveFirstInput = false
            inputBaseline = nil
            stopObservingInput()
        }
        login.state = loginEnabled?() == true ? .on : .off
        render()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if showingSetup {
            if setupRequested { onRecheck?() } else { prepareOnce() }
        }
    }

    private var ready: Bool { showingSetup && status.state == .monitoring }

    private func render() {
        let stage = !showingSetup ? 0 : ready ? 2 : 1
        titleLabel.stringValue = NSLocalizedString(["welcome.title", "welcome.connect", "welcome.ready"][stage], comment: "")
        bodyLabel.stringValue = NSLocalizedString(["welcome.subtitle", "welcome.connectBody", "welcome.readyBody"][stage], comment: "")
        stepIndicator.step = stage
        welcomePage.isHidden = stage != 0
        setupPage.isHidden = stage != 1
        readyPage.isHidden = stage != 2
        login.isHidden = !ready
        loginError.isHidden = !ready || loginError.stringValue.isEmpty
        primary.title = NSLocalizedString(!showingSetup ? "welcome.start" : ready ? "welcome.openStats" : status.failureDescription != nil ? "monitoring.retry" : "welcome.openSettings", comment: "")
        primary.isEnabled = !showingSetup || status.state != .starting
        secondary.title = NSLocalizedString(ready ? "welcome.openKeyboard" : !showingSetup ? "welcome.preview" : "welcome.later", comment: "")
        // No implicit Return action while the user is invited to try a key.
        primary.keyEquivalent = ready ? "" : "\r"
        updateSetupState()
        firstPressLabel.stringValue = NSLocalizedString(didReceiveFirstInput ? "welcome.firstReceived" : "welcome.firstPress", comment: "")
        let signature = "\(stage)"
        if lastPresentation != signature {
            lastPresentation = signature
            animateStageChange()
        }
        if ready { startObservingInput() } else { stopObservingInput() }
    }

    private func updateSetupState() {
        let connection = HelperXPCClient.shared.state
        let connected = if case .connected = connection { true } else { false }
        let authorized = if case .connected(_, true) = connection { true } else { false }
        switch status.state {
        case .starting:
            serviceRow.update(state: .working, message: NSLocalizedString("welcome.servicePreparing", comment: ""))
            permissionRow.update(state: .pending, message: NSLocalizedString(authorized ? "welcome.permissionGranted" : "welcome.permissionWaiting", comment: ""))
            captureRow.update(state: .pending, message: NSLocalizedString("welcome.captureWaiting", comment: ""))
        case .monitoring:
            for row in [serviceRow, permissionRow, captureRow] { row.update(state: .complete, message: NSLocalizedString("welcome.stateReady", comment: "")) }
        case .installationFailed:
            serviceRow.update(state: .failed, message: NSLocalizedString("welcome.stateFailed", comment: ""))
            permissionRow.update(state: .pending, message: NSLocalizedString("welcome.statePending", comment: ""))
            captureRow.update(state: .pending, message: NSLocalizedString("welcome.statePending", comment: ""))
        case .failed(let code):
            serviceRow.update(state: connected ? .complete : .failed, message: NSLocalizedString(connected ? "welcome.stateReady" : "welcome.stateCheck", comment: ""))
            permissionRow.update(state: authorized ? .complete : .pending, message: NSLocalizedString(authorized ? "welcome.permissionGranted" : code == 1 ? "welcome.permissionWaiting" : "welcome.permissionCheck", comment: ""))
            captureRow.update(state: .failed, message: NSLocalizedString("welcome.captureFailed", comment: ""))
        case .idle:
            for row in [serviceRow, permissionRow, captureRow] { row.update(state: .pending, message: NSLocalizedString("welcome.statePending", comment: "")) }
        }
        errorLabel.stringValue = status.failureDescription ?? ""
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
    }

    private func animateStageChange() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for page in [welcomePage, setupPage, readyPage] where !page.isHidden {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.45
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            page.layer?.add(fade, forKey: "welcomeStage")
        }
        if ready { readySignal.playConfirmation() }
    }

    private func startObservingInput() {
        guard statsObserver == nil, !didReceiveFirstInput else { return }
        let initial = StatsManager.shared.displayCurrentStats()
        inputBaseline = initial.keyPresses
        statsObserver = StatsManager.shared.addStatsUpdateHandler { [weak self] in
            guard let self, self.window?.isVisible == true, self.ready else { return }
            let stats = StatsManager.shared.displayCurrentStats()
            let count = stats.keyPresses
            guard let baseline = self.inputBaseline else {
                self.inputBaseline = count
                return
            }
            guard count > baseline else { return }
            self.didReceiveFirstInput = true
            self.firstPressLabel.stringValue = NSLocalizedString("welcome.firstReceived", comment: "")
            self.readySignal.playConfirmation()
            self.stopObservingInput()
        }
    }

    private func stopObservingInput() {
        if let statsObserver { StatsManager.shared.removeStatsUpdateHandler(statsObserver) }
        statsObserver = nil
    }

    private func prepareOnce() {
        guard !setupRequested else { return }
        setupRequested = true
        onPrepare?()
    }

    @objc private func primaryAction() {
        if !showingSetup {
            showingSetup = true
            if progress.shouldPresentAutomatically { progress.beginSetup() }
            render()
            prepareOnce()
        } else if ready {
            finish(open: onOpenStats)
        } else if status.failureDescription != nil { onRetry?() }
        else { onAuthorize?() }
    }

    @objc private func secondaryAction() {
        if ready { finish(open: onOpenKeyboard) }
        else if !showingSetup { onOpenExample?() }
        else { close() }
    }

    private func finish(open: (() -> Void)?) {
        guard progress.complete(isMonitoring: status.state == .monitoring) else { return }
        close()
        open?()
    }

    @objc private func loginChanged() {
        do { try setLogin?(login.state == .on); loginError.stringValue = "" }
        catch {
            login.state = loginEnabled?() == true ? .on : .off
            loginError.stringValue = NSLocalizedString("launchAtLogin.error.message", comment: "")
        }
        render()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if showingSetup && setupRequested { onRecheck?() }
    }

    func windowWillClose(_ notification: Notification) {
        stopObservingInput()
        for page in [welcomePage, setupPage, readyPage] { page.layer?.removeAnimation(forKey: "welcomeStage") }
        readySignal.layer?.removeAllAnimations()
        readySignal.removeAnimations()
        if ready { _ = progress.complete(isMonitoring: true) }
        onClose?()
    }
}

private class WelcomeCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    fileprivate func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        }
    }
}

private final class WelcomePreviewCard: WelcomeCardView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let image = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .controlAccentColor
        image.symbolConfiguration = .init(pointSize: 28, weight: .light)
        let title = NSTextField(labelWithString: NSLocalizedString("welcome.previewTitle", comment: ""))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: NSLocalizedString("welcome.previewBody", comment: ""))
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, body])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let stack = NSStackView(views: [image, labels])
        stack.alignment = .centerY
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class WelcomeStateRow: NSView {
    enum State { case pending, working, complete, failed }
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, stateLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        symbol.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [symbol, labels, NSView()])
        stack.alignment = .centerY
        stack.spacing = 11
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            symbol.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(state: State, message: String) {
        let name: String
        switch state {
        case .pending: name = "circle"; symbol.contentTintColor = .tertiaryLabelColor
        case .working: name = "ellipsis.circle"; symbol.contentTintColor = .controlAccentColor
        case .complete: name = "checkmark.circle.fill"; symbol.contentTintColor = .systemGreen
        case .failed: name = "exclamationmark.circle"; symbol.contentTintColor = .systemOrange
        }
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        stateLabel.stringValue = message
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityValue(message)
    }
}

private final class WelcomeStepIndicator: NSView {
    var step = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityElement(true)
            setAccessibilityRole(.valueIndicator)
            setAccessibilityValue("\(step + 1) / 3")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<3 {
            let active = index == step
            (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            let rect = NSRect(x: CGFloat(index) * 22, y: 0, width: active ? 20 : 8, height: 3)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

private final class WelcomeReadySignal: NSView {
    private let mark = CAShapeLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(mark)
        mark.strokeColor = NSColor.controlAccentColor.cgColor
        mark.fillColor = nil
        mark.lineWidth = 2.5
        mark.lineCap = .round
        mark.lineJoin = .round
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            mark.strokeColor = NSColor.controlAccentColor.cgColor
        }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX - 13, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.midX - 3, y: bounds.midY - 10))
        path.addLine(to: CGPoint(x: bounds.midX + 15, y: bounds.midY + 12))
        mark.path = path
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
    }
    func playConfirmation() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        mark.removeAnimation(forKey: "confirmation")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.28
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mark.add(draw, forKey: "confirmation")
    }
    fileprivate func removeAnimations() { mark.removeAnimation(forKey: "confirmation") }
}

private final class WelcomeBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
