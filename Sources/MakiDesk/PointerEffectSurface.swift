import AppKit
import QuartzCore

/// One display's click-through surface for the pointer effects (E1–E7).
///
/// This is a transparent, non-activating panel above app windows and below the
/// system pointer. All motion is in Core Animation layers: the controller
/// updates a few layer properties rather than redrawing a full-screen view.
@MainActor
final class PointerEffectPanel: FloatingPanel {
    override class var style: Style { .passive }

    /// The one place a surface's window is configured. Tests check the
    /// click-through invariant without depending on a real display.
    static func make(frame: CGRect, sharingType: NSWindow.SharingType) -> PointerEffectPanel {
        let panel = PointerEffectPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.sharingType = sharingType
        return panel
    }
}

/// Owns the panel and its layer-backed renderer for one display.
@MainActor
final class PointerEffectSurface {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect

    private let panel: PointerEffectPanel
    private let effectView: PointerEffectView
    private var ringVisible = false
    private var pulseLayers: [CAShapeLayer] = []

    var windowNumber: Int { panel.windowNumber }
    var isVisible: Bool { panel.isVisible }

    init(screen: NSScreen, sharingType: NSWindow.SharingType) {
        displayID = PaletteScreenLocation.displayID(screen) ?? 0
        displayFrame = screen.frame
        effectView = PointerEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel = PointerEffectPanel.make(frame: screen.frame, sharingType: sharingType)
        panel.contentView = effectView
        effectView.autoresizingMask = [.width, .height]
    }

    func setSharingType(_ sharingType: NSWindow.SharingType) {
        panel.sharingType = sharingType
    }

    func localPoint(_ screenPoint: CGPoint) -> CGPoint {
        PointerEffectGeometry.localPoint(screenPoint, in: displayFrame)
    }

    func update(style: PointerEffectStyle, at point: CGPoint, radius: CGFloat,
                intensity: Double, colour: NSColor, trail: PointerTrail,
                isMoving: Bool, reduceMotion: Bool) {
        ringVisible = true
        effectView.update(style: style, at: point, radius: radius,
                          intensity: intensity, colour: colour,
                          trail: trail, isMoving: isMoving,
                          reduceMotion: reduceMotion)
        if panel.isVisible == false {
            panel.orderFrontRegardless()
        }
    }

    func hideEffect() {
        ringVisible = false
        effectView.hideEffect()
        orderOutIfIdle()
    }

    func showPulse(at point: CGPoint, radius: CGFloat, intensity: Double,
                   duration: TimeInterval, reduceMotion: Bool, colour: NSColor) {
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers = effectView.makePulseLayers(at: point, radius: radius,
                                                 intensity: intensity,
                                                 duration: duration,
                                                 reduceMotion: reduceMotion,
                                                 colour: colour)
        if panel.isVisible == false { panel.orderFrontRegardless() }
    }

    func hidePulse() {
        guard pulseLayers.isEmpty == false else { return }
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()
        orderOutIfIdle()
    }

    func showRipple(at point: CGPoint, radius: CGFloat,
                    intensity: Double, reduceMotion: Bool, colour: NSColor) {
        effectView.showRipple(at: point, radius: radius,
                              intensity: intensity,
                              reduceMotion: reduceMotion, colour: colour)
        if panel.isVisible == false { panel.orderFrontRegardless() }
    }

    func close() {
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()
        effectView.removeAllAnimations()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func orderOutIfIdle() {
        guard ringVisible == false, pulseLayers.isEmpty else { return }
        panel.orderOut(nil)
    }
}

/// A full-display layer tree with small local effects. Spotlight is the only
/// full-screen layer; it is a static dim layer whose even-odd mask moves with
/// the pointer. Particles are emitted by Core Animation, and orbiting dots use
/// a single parent rotation animation.
@MainActor
final class PointerEffectView: NSView {
    private let dimLayer = CALayer()
    private let spotlightMask = CAShapeLayer()
    private let trailLayer = CAShapeLayer()
    private let trailCoreLayer = CAShapeLayer()
    private let emitterLayer = CAEmitterLayer()
    private let orbitLayer = CALayer()
    private let glowLayer = CAGradientLayer()
    private let ringLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()

    private var layerBounds: CGRect = .zero
    private var orbitRadius: CGFloat = -1
    private var particleImage: CGImage?
    private var particleColour: NSColor?
    private var currentStyle: PointerEffectStyle?

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    override func layout() {
        super.layout()
        guard bounds != layerBounds else { return }
        layerBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        spotlightMask.frame = bounds
        trailLayer.frame = bounds
        trailCoreLayer.frame = bounds
        emitterLayer.frame = bounds
        CATransaction.commit()
    }

    private func setUp() {
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true

        // Ordered bottom-to-top. The hole leaves the desktop visible while the
        // ring, trail and click feedback remain legible above the dim surface.
        dimLayer.opacity = 0
        spotlightMask.fillColor = NSColor.white.cgColor
        spotlightMask.fillRule = .evenOdd
        dimLayer.mask = spotlightMask
        root.addSublayer(dimLayer)

        trailLayer.fillColor = NSColor.controlAccentColor.cgColor
        trailLayer.opacity = 0
        trailCoreLayer.fillColor = nil
        trailCoreLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        trailCoreLayer.lineWidth = 1
        trailCoreLayer.lineCap = .round
        trailCoreLayer.lineJoin = .round
        trailCoreLayer.opacity = 0
        root.addSublayer(trailLayer)
        root.addSublayer(trailCoreLayer)

        configureEmitter()
        emitterLayer.opacity = 0
        root.addSublayer(emitterLayer)

        orbitLayer.opacity = 0
        root.addSublayer(orbitLayer)

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)
        glowLayer.locations = [0, 0.55, 1].map { NSNumber(value: $0) }
        glowLayer.opacity = 0

        ringLayer.fillColor = nil
        ringLayer.lineWidth = 2.4
        ringLayer.lineCap = .round
        ringLayer.opacity = 0

        coreLayer.fillColor = nil
        coreLayer.lineWidth = 1
        coreLayer.strokeColor = NSColor.white.withAlphaComponent(0.38).cgColor
        coreLayer.opacity = 0

        root.addSublayer(glowLayer)
        root.addSublayer(ringLayer)
        root.addSublayer(coreLayer)
        layout()
    }

    private func configureEmitter() {
        emitterLayer.emitterShape = .point
        emitterLayer.emitterMode = .points
        emitterLayer.renderMode = .additive
        emitterLayer.emitterSize = CGSize(width: 1, height: 1)
        emitterLayer.emitterCells = [
            makeEmitterCell(scale: 0.06, birthRate: 80, lifetime: 0.72),
            makeEmitterCell(scale: 0.045, birthRate: 20, lifetime: 0.55),
        ]
    }

    private func makeEmitterCell(scale: CGFloat, birthRate: Float,
                                 lifetime: Float) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = particleSprite()
        cell.birthRate = birthRate
        cell.lifetime = lifetime
        cell.lifetimeRange = 0.18
        cell.velocity = 25
        cell.velocityRange = 22
        cell.emissionRange = .pi * 2
        cell.scale = scale
        cell.scaleRange = 0.025
        cell.scaleSpeed = -0.045
        cell.alphaSpeed = -1.15
        cell.spinRange = .pi * 2
        return cell
    }

    private func particleSprite() -> CGImage? {
        if particleImage == nil {
            let side = 48
            let data = NSMutableData(length: side * side * 4)!
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: data.mutableBytes,
                                          width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let colours = [NSColor.white.withAlphaComponent(0.95).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colours,
                                            locations: [0, 1]) else { return nil }
            context.drawRadialGradient(gradient,
                                       startCenter: CGPoint(x: 24, y: 24), startRadius: 0,
                                       endCenter: CGPoint(x: 24, y: 24), endRadius: 23,
                                       options: [])
            particleImage = context.makeImage()
        }
        return particleImage
    }

    // MARK: - Style rendering

    func update(style: PointerEffectStyle, at point: CGPoint, radius: CGFloat,
                intensity: Double, colour: NSColor, trail: PointerTrail,
                isMoving: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if currentStyle != style {
            currentStyle = style
            resetStyles()
        }

        switch style {
        case .ring:
            updateRing(at: point, radius: radius, intensity: intensity, colour: colour)
        case .ribbon:
            if reduceMotion {
                resetStyles()
                updateRing(at: point, radius: radius, intensity: intensity, colour: colour)
            } else if trail.samples.count < 2 {
                resetStyles()
                let dot = max(3, min(8, radius * 0.18))
                updateRing(at: point, radius: dot, intensity: intensity, colour: colour)
            } else {
                updateRibbon(trail: trail, radius: radius, intensity: intensity, colour: colour)
            }
        case .particles:
            if reduceMotion {
                resetStyles()
                updateRing(at: point, radius: radius, intensity: intensity, colour: colour)
            } else {
                updateParticles(at: point, intensity: intensity, colour: colour,
                                isMoving: isMoving)
            }
        case .orbit:
            updateOrbit(at: point, radius: radius, intensity: intensity,
                        colour: colour, reduceMotion: reduceMotion)
        case .spotlight:
            updateSpotlight(at: point, radius: radius, intensity: intensity,
                            colour: colour, reduceMotion: reduceMotion)
        }
        CATransaction.commit()
    }

    private func resetStyles() {
        dimLayer.opacity = 0
        trailLayer.opacity = 0
        trailCoreLayer.opacity = 0
        emitterLayer.opacity = 0
        emitterLayer.birthRate = 0
        orbitLayer.opacity = 0
        orbitLayer.removeAnimation(forKey: "orbit-rotation")
        glowLayer.opacity = 0
        ringLayer.opacity = 0
        coreLayer.opacity = 0
    }

    private func updateRing(at point: CGPoint, radius: CGFloat,
                            intensity: Double, colour: NSColor) {
        let circle = CGRect(x: -radius, y: -radius,
                            width: radius * 2, height: radius * 2)
        let path = CGPath(ellipseIn: circle, transform: nil)
        ringLayer.path = path
        coreLayer.path = path
        ringLayer.position = point
        coreLayer.position = point
        ringLayer.lineWidth = 2.4
        ringLayer.strokeColor = colour.withAlphaComponent(0.55 + 0.35 * intensity).cgColor
        ringLayer.shadowColor = colour.cgColor
        ringLayer.shadowOpacity = 0.55
        ringLayer.shadowRadius = 12 * intensity + 4
        ringLayer.shadowOffset = .zero

        let side = radius * 3.8
        glowLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glowLayer.position = point
        glowLayer.colors = [
            colour.withAlphaComponent(0.22 * intensity).cgColor,
            colour.withAlphaComponent(0.10 * intensity).cgColor,
            colour.withAlphaComponent(0).cgColor,
        ]
        glowLayer.opacity = 1
        ringLayer.opacity = 1
        coreLayer.opacity = 1
    }

    private func updateRibbon(trail: PointerTrail, radius: CGFloat,
                              intensity: Double, colour: NSColor) {
        glowLayer.opacity = 0
        ringLayer.opacity = 0
        coreLayer.opacity = 0
        trailLayer.path = trail.ribbonPath(maxWidth: max(5, radius * 0.42))
        trailLayer.fillColor = colour.withAlphaComponent(0.5 + 0.35 * intensity).cgColor
        trailLayer.opacity = trail.samples.count > 1 ? 1 : 0
        trailCoreLayer.path = trail.corePath()
        trailCoreLayer.strokeColor = NSColor.white.withAlphaComponent(0.18 + 0.35 * intensity).cgColor
        trailCoreLayer.opacity = trail.samples.count > 1 ? 0.7 : 0
    }

    private func updateParticles(at point: CGPoint, intensity: Double,
                                colour: NSColor, isMoving: Bool) {
        glowLayer.opacity = 0
        ringLayer.opacity = 0
        coreLayer.opacity = 0
        emitterLayer.emitterPosition = point
        if particleColour != colour, let cells = emitterLayer.emitterCells, cells.count >= 2 {
            cells[0].color = colour.cgColor
            cells[1].color = NSColor.white.cgColor
            emitterLayer.emitterCells = cells
            particleColour = colour
        }
        emitterLayer.birthRate = isMoving ? Float(0.5 + intensity * 0.5) : 0.06
        emitterLayer.opacity = 1
    }

    private func updateOrbit(at point: CGPoint, radius: CGFloat,
                             intensity: Double, colour: NSColor,
                             reduceMotion: Bool) {
        let orbit = max(12, radius * 0.9)
        let extent = orbit + 8
        orbitLayer.position = point
        if orbitRadius != orbit || orbitLayer.sublayers?.isEmpty != false {
            orbitRadius = orbit
            orbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            orbitLayer.bounds = CGRect(origin: .zero,
                                       size: CGSize(width: extent * 2, height: extent * 2))
            orbitLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let count = 3
            for index in 0..<count {
                let dot = CAShapeLayer()
                let dotSize: CGFloat = index == 0 ? 7 : 5
                dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
                let angle = Double(index) * .pi * 2 / Double(count)
                dot.position = CGPoint(x: extent + cos(angle) * orbit,
                                       y: extent + sin(angle) * orbit)
                dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
                dot.fillColor = colour.withAlphaComponent(0.7 + 0.3 * intensity).cgColor
                dot.shadowColor = colour.cgColor
                dot.shadowOpacity = 0.8
                dot.shadowRadius = 7
                dot.shadowOffset = .zero
                orbitLayer.addSublayer(dot)
            }
        }
        for dot in orbitLayer.sublayers?.compactMap({ $0 as? CAShapeLayer }) ?? [] {
            dot.fillColor = colour.withAlphaComponent(0.7 + 0.3 * intensity).cgColor
            dot.shadowColor = colour.cgColor
        }
        if reduceMotion {
            orbitLayer.removeAnimation(forKey: "orbit-rotation")
        } else if orbitLayer.animation(forKey: "orbit-rotation") == nil {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 2.6
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            orbitLayer.add(rotation, forKey: "orbit-rotation")
        }
        orbitLayer.opacity = 1
    }

    private func updateSpotlight(at point: CGPoint, radius: CGFloat,
                                 intensity: Double, colour: NSColor,
                                 reduceMotion: Bool) {
        let hole = radius * 2.6
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: point.x - hole,
                                   y: point.y - hole,
                                   width: hole * 2,
                                   height: hole * 2))
        spotlightMask.path = path
        spotlightMask.fillRule = .evenOdd
        spotlightMask.frame = bounds
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = Float(reduceMotion ? 0.3 : 0.32 + intensity * 0.3)

        glowLayer.opacity = 0
        coreLayer.opacity = 0
        ringLayer.path = CGPath(ellipseIn: CGRect(x: -hole, y: -hole,
                                                  width: hole * 2, height: hole * 2),
                                transform: nil)
        ringLayer.position = point
        ringLayer.strokeColor = colour.withAlphaComponent(0.22 + 0.3 * intensity).cgColor
        ringLayer.lineWidth = 1.2
        ringLayer.shadowOpacity = 0
        ringLayer.opacity = 0.8
    }

    func hideEffect() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resetStyles()
        currentStyle = nil
        CATransaction.commit()
    }

    // MARK: - Pulse

    func makePulseLayers(at point: CGPoint, radius: CGFloat,
                         intensity: Double, duration: TimeInterval,
                         reduceMotion: Bool, colour: NSColor) -> [CAShapeLayer] {
        let base = max(9, radius * 0.35)
        let circle = CGRect(x: -base, y: -base,
                            width: base * 2, height: base * 2)
        let path = CGPath(ellipseIn: circle, transform: nil)
        let now = CACurrentMediaTime()
        var layers: [CAShapeLayer] = []

        for index in 0..<PointerPulse.ringCount {
            let ring = CAShapeLayer()
            ring.path = path
            ring.fillColor = nil
            ring.strokeColor = colour.withAlphaComponent(0.55 + 0.3 * intensity).cgColor
            ring.lineWidth = 2.2
            ring.position = point
            ring.opacity = 0
            ring.shadowColor = colour.cgColor
            ring.shadowOpacity = 0.5
            ring.shadowRadius = 8
            ring.shadowOffset = .zero
            layer?.addSublayer(ring)

            let begin = now + PointerPulse.stagger * Double(index)
            if reduceMotion {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.85, 0]
                fade.keyTimes = [0, 0.18, 1].map { NSNumber(value: $0) }
                fade.duration = duration
                fade.beginTime = begin
                fade.fillMode = .backwards
                fade.isRemovedOnCompletion = false
                ring.add(fade, forKey: "pulse-fade")
            } else {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.35
                scale.toValue = 2.6 + Double(index) * 0.25
                scale.duration = duration
                scale.beginTime = begin
                scale.fillMode = .backwards
                scale.isRemovedOnCompletion = false
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.95
                fade.toValue = 0
                fade.duration = duration
                fade.beginTime = begin
                fade.fillMode = .backwards
                fade.isRemovedOnCompletion = false
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

                ring.add(scale, forKey: "pulse-scale")
                ring.add(fade, forKey: "pulse-fade")
            }
            layers.append(ring)
        }
        return layers
    }

    // MARK: - Click ripple

    func showRipple(at point: CGPoint, radius: CGFloat,
                    intensity: Double, reduceMotion: Bool, colour: NSColor) {
        let base = max(10, radius * 0.28)
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -base, y: -base,
                                               width: base * 2, height: base * 2),
                             transform: nil)
        ripple.fillColor = nil
        ripple.strokeColor = colour.withAlphaComponent(0.5 + 0.35 * intensity).cgColor
        ripple.lineWidth = 1.8
        ripple.position = point
        ripple.opacity = 0
        layer?.addSublayer(ripple)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }

        if reduceMotion {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.8, 0]
            fade.keyTimes = [0, 0.2, 1].map { NSNumber(value: $0) }
            fade.duration = 0.45
            fade.isRemovedOnCompletion = false
            ripple.add(fade, forKey: "ripple-fade")
        } else {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.4
            scale.toValue = 3.1
            scale.duration = 0.62
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            fade.duration = 0.62
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

            ripple.add(scale, forKey: "ripple-scale")
            ripple.add(fade, forKey: "ripple-fade")
        }

        CATransaction.commit()
    }

    func removeAllAnimations() {
        layer?.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
        }
    }
}
