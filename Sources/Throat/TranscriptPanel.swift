import AppKit

/// Recording indicator. While dictating it is a black "island" that grows out of either side of the
/// camera notch, or hangs from the middle of the menu bar on screens without one.
/// Messages appear as a small card just below the menu bar.
final class TranscriptPanel: NSPanel {
    enum Mode: Equatable { case preparing, listening, finishing, copying, copied, message(String) }
    var onCancel: (() -> Void)?

    private let island = IslandView()
    private let card = NSVisualEffectView()
    private let border = BorderView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private lazy var cardStack = makeCard()
    private var collapsedFrame: NSRect?
    private var hideToken: UUID?
    private var recordingStart: Date?
    private var clock: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar and every app's windows, on every Space, without taking focus.
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.maskImage = Self.mask(radius: 16)
        for view in [cardStack, border] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                view.topAnchor.constraint(equalTo: card.topAnchor),
                view.bottomAnchor.constraint(equalTo: card.bottomAnchor)
            ])
        }
        border.layer?.cornerRadius = 16
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // macOS normally nudges windows down out of the menu bar; the island belongs up there beside the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    @objc private func cancelClicked() { onCancel?() }

    func show(_ mode: Mode, shortcut: String) {
        // A show during the hide animation cancels the hide and expands again.
        let wasHiding = hideToken != nil
        hideToken = nil
        switch mode {
        case .preparing: island.configure(dot: .systemGray, pulsing: true, live: false, text: "")
        case .listening:
            if recordingStart == nil { recordingStart = Date() }
            island.configure(dot: .systemRed, pulsing: true, live: true, text: elapsed)
            island.toolTip = "\(shortcut) to stop & paste · esc to stop & copy"
        case .finishing: island.configure(dot: .systemBlue, pulsing: false, live: false, text: "Pasting")
        case .copying: island.configure(dot: .systemBlue, pulsing: false, live: false, text: "Copying")
        case .copied: island.configure(dot: .systemGreen, pulsing: false, live: false, text: "Copied")
        case .message(let text):
            message.stringValue = text
            hint.stringValue = "Click away to dismiss · \(shortcut) to try again"
            showCard()
            return
        }
        showIsland(reopen: wasHiding)
    }

    func push(level: Float) { island.waveform.push(level) }

    override func orderOut(_ sender: Any?) {
        guard isVisible, contentView === island, let collapsedFrame else { return hide() }
        // Tuck the wings back into the notch (or shrink away) before disappearing.
        let token = UUID()
        hideToken = token
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(collapsedFrame, display: true)
            animator().alphaValue = island.hasNotch ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hide()
        })
    }

    private func hide() {
        hideToken = nil
        island.waveform.stop()
        clock?.invalidate()
        clock = nil
        recordingStart = nil
        super.orderOut(nil)
    }

    // MARK: Island

    private func showIsland(reopen: Bool) {
        island.waveform.start()
        startClock()
        guard contentView !== island || !isVisible || reopen else { return }
        let screen = activeScreen
        let geometry = IslandGeometry(screen: screen)
        island.hasNotch = geometry.notchWidth > 0
        island.wing = geometry.wing
        contentView = island
        hasShadow = false
        // Clicks go straight through to the menu bar; the shortcut and esc control recording.
        ignoresMouseEvents = true
        collapsedFrame = geometry.collapsed
        setFrame(geometry.collapsed, display: false)
        alphaValue = island.hasNotch ? 1 : 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.3, 1)
            animator().setFrame(geometry.expanded, display: true)
            animator().alphaValue = 1
        }
    }

    private var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(recordingStart ?? Date()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func startClock() {
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.island.waveform.isLive else { return }
            self.island.text = self.elapsed
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private var activeScreen: NSScreen {
        NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Card

    private func showCard() {
        island.waveform.stop()
        contentView = card
        hasShadow = true
        ignoresMouseEvents = false
        alphaValue = 1
        collapsedFrame = nil
        card.layoutSubtreeIfNeeded()
        let size = cardStack.fittingSize
        let visible = activeScreen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10,
                           width: size.width, height: size.height)
        // Through the animator, so it replaces any island animation still in flight.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().setFrame(frame, display: true)
        }
        invalidateShadow()
        orderFrontRegardless()
    }

    private func makeCard() -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .systemOrange
        message.font = .systemFont(ofSize: 13)
        message.textColor = .labelColor
        message.preferredMaxLayoutWidth = 320
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let text = NSStackView(views: [message, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        message.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                             target: self, action: #selector(cancelClicked))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        close.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, text, close])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 12)
        return stack
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Where the island sits: wings either side of the notch, or a centred pill under the top edge.
struct IslandGeometry {
    let notchWidth: CGFloat
    let wing: CGFloat
    let expanded: NSRect
    let collapsed: NSRect

    init(screen: NSScreen) {
        let frame = screen.frame
        var height = frame.maxY - screen.visibleFrame.maxY
        var notch: CGFloat = 0
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        }
        // Menu bar hidden or unusually thin: still leave room for the waveform.
        height = max(height, 28)
        wing = notch > 0 ? 80 : 76
        notchWidth = notch
        let width = notch + wing * 2
        expanded = NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        let small = max(notch, 40)
        collapsed = NSRect(x: frame.midX - small / 2, y: frame.maxY - height, width: small, height: height)
    }
}

/// Black shape flush with the top of the screen: status on the left wing, waveform on the right.
private final class IslandView: NSView {
    let waveform = WaveformView()
    private let dot = PulseDot()
    private let label = NSTextField(labelWithString: "")
    var hasNotch = false
    var wing: CGFloat = 80 { didSet { needsLayout = true } }
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        // Only the bottom corners round, so the shape reads as part of the notch / screen edge.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        for view in [dot, label, waveform] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(dot color: NSColor, pulsing: Bool, live: Bool, text: String) {
        dot.set(color: color, pulsing: pulsing)
        waveform.isLive = live
        self.text = text
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        layer?.cornerRadius = hasNotch ? 10 : height / 2
        let inset: CGFloat = hasNotch ? 14 : 12
        dot.frame = NSRect(x: inset, y: (height - 8) / 2, width: 8, height: 8)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: dot.frame.maxX + 7, y: (height - label.frame.height) / 2)
        // Anchored to the right edge so the wing slides out from behind the notch as it expands.
        let waveWidth = wing - inset - 6
        waveform.frame = NSRect(x: bounds.width - inset - waveWidth, y: height * 0.22,
                                width: waveWidth, height: height * 0.56)
    }
}

/// Hairline highlight around the card edge; never intercepts clicks.
private final class BorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PulseDot: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func set(color: NSColor, pulsing: Bool) {
        layer?.backgroundColor = color.cgColor
        layer?.removeAnimation(forKey: "pulse")
        guard pulsing else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }
}

/// Scrolling bar meter: newest audio enters on the right and older bars fade out to the left.
final class WaveformView: NSView {
    var isLive = false
    private var bars = [CGFloat](repeating: 0, count: 48)
    private var peak: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 2

    func push(_ level: Float) { peak = max(peak, CGFloat(level)) }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        // Common modes keep it animating while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bars = bars.map { _ in 0 }
        peak = 0
    }

    private func tick() {
        phase += 0.25
        let previous = bars.last ?? 0
        let next: CGFloat
        if isLive {
            // Rise quickly, fall gently, so speech reads as smooth swells rather than flicker.
            next = peak > previous ? previous + (peak - previous) * 0.75 : previous * 0.55 + peak * 0.45
        } else {
            next = 0.15 + 0.1 * sin(phase)
        }
        peak = 0
        bars.removeFirst()
        bars.append(next)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Show as many of the newest bars as fit, right-aligned.
        let count = min(bars.count, max(1, Int((bounds.width + gap) / (barWidth + gap))))
        let visible = bars.suffix(count)
        let start = bounds.width - CGFloat(count) * (barWidth + gap) + gap
        for (index, level) in visible.enumerated() {
            let height = max(barWidth, bounds.height * min(level, 1))
            let rect = NSRect(x: start + CGFloat(index) * (barWidth + gap), y: bounds.midY - height / 2,
                              width: barWidth, height: height)
            let fade = count > 1 ? 0.2 + 0.8 * CGFloat(index) / CGFloat(count - 1) : 1
            NSColor.white.withAlphaComponent(fade * (isLive ? 1 : 0.6)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
