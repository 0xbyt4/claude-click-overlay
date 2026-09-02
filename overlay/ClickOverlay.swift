import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// click-overlay: draws transparent, click-through markers on the primary display so the
// user can see where a Claude Code computer-use action is about to land, and plays a
// sound when the click actually happens.
//
// Subcommands:
//   show [--ttl SECONDS] [--style NAME] [--stroke halo|colour] [--sound SPEC] [--key-sound SPEC] [--scroll-sound SPEC] [--volume 0..1]
//        [--log FILE] [--state-dir DIR] [--ready-file FILE] [--banner TEXT ...] [--marker X,Y,LABEL,KIND ...]
//        X,Y are logical points with a top-left origin (CGWindowList convention).
//        KIND is one of: click, right, double, scroll, move, drag-start, drag-end.
//        STYLE is one of: reticle, ring, sonar, beacon, path, dot.
//        A banner line is shown at the top of the screen, used for upcoming keyboard input.
//        The ready file is created once the markers are visible and the event monitors are
//        installed; the hook waits for it before letting the action proceed.
//        Exits after TTL seconds or on SIGTERM/SIGINT (fades out first).
//   sounds            Lists the sound presets, system sounds, melodies, and modes.
//   play SPEC [--volume 0..1]
//                     Plays a sound spec once so you can preview it.
//   render SPEC FILE  Writes a preset or melody to a WAV file.
//   use SPEC [--volume 0..1] | use --clear
//                     Saves the sound choice to the config file the hook reads on every action.
//   type-human TEXT | --text-file FILE [--cps N] [--max-seconds N] [--sound SPEC] [--volume 0..1] [--log FILE]
//                     Types the text with human-like pacing, playing the key sound per keystroke.
//   cursor            Prints the current cursor position as JSON (logical points, top-left origin).
//   screen            Prints the primary display geometry as JSON.
//
// A sound SPEC is "none", a preset name, a macOS system sound, a path to an audio file,
// "random", "random:a,b,c", "melody:NAME", or "say:TEXT".

struct Marker {
    let x: CGFloat
    let y: CGFloat
    let label: String
    let kind: String
    /// Position in the batch, parsed from a leading number in the label ("3 left click").
    let number: Int?
    /// Label without the leading number.
    let text: String

    init(x: CGFloat, y: CGFloat, label: String, kind: String) {
        self.x = x
        self.y = y
        self.label = label
        self.kind = kind
        let parts = label.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = parts.first, let number = Int(first) {
            self.number = number
            self.text = parts.count > 1 ? String(parts[1]) : ""
        } else {
            self.number = nil
            self.text = label
        }
    }

    func samePlace(as other: Marker) -> Bool {
        abs(x - other.x) < 4 && abs(y - other.y) < 4 && kind == other.kind
    }
}

struct ShowOptions {
    var markers: [Marker] = []
    var banner: [String] = []
    var ttl: Double = 2.0
    var style = "reticle"
    var stroke = "halo"
    var sound = "mouse"
    var keySound = "mechkey"
    var scrollSound = "none"
    var volume: Float = 0.6
    var logPath: String?
    var stateDirectory: String?
    var readyFile: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(64)
}

func primaryScreen() -> NSScreen {
    guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
        fail("no display found")
    }
    return screen
}

func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// MARK: - Argument parsing

func parseShowOptions(_ args: [String]) -> ShowOptions {
    var options = ShowOptions()
    var index = 0
    func value(for flag: String) -> String {
        guard index + 1 < args.count else { fail("\(flag) needs a value") }
        index += 2
        return args[index - 1]
    }
    while index < args.count {
        switch args[index] {
        case "--ttl":
            guard let ttl = Double(value(for: "--ttl")) else { fail("--ttl needs a number") }
            options.ttl = ttl
        case "--style":
            let style = value(for: "--style").lowercased()
            guard markerStyles.contains(style) else { fail("--style must be one of: " + markerStyles.joined(separator: ", ")) }
            options.style = style
        case "--stroke":
            let stroke = value(for: "--stroke").lowercased()
            guard stroke == "halo" || stroke == "colour" || stroke == "color" else { fail("--stroke must be halo or colour") }
            options.stroke = stroke == "color" ? "colour" : stroke
        case "--sound":
            options.sound = value(for: "--sound")
        case "--key-sound":
            options.keySound = value(for: "--key-sound")
        case "--scroll-sound":
            options.scrollSound = value(for: "--scroll-sound")
        case "--banner":
            options.banner.append(value(for: "--banner"))
        case "--volume":
            guard let volume = Float(value(for: "--volume")) else { fail("--volume needs a number") }
            options.volume = volume
        case "--log":
            options.logPath = value(for: "--log")
        case "--state-dir":
            options.stateDirectory = value(for: "--state-dir")
        case "--ready-file":
            options.readyFile = value(for: "--ready-file")
        case "--marker":
            let raw = value(for: "--marker")
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                fail("bad marker: \(raw)")
            }
            let label = parts.count > 2 ? parts[2] : ""
            let kind = parts.count > 3 ? parts[3] : "click"
            options.markers.append(Marker(x: CGFloat(x), y: CGFloat(y), label: label, kind: kind))
        default:
            fail("unknown argument: \(args[index])")
        }
    }
    if options.markers.isEmpty && options.banner.isEmpty && options.keySound.lowercased() == "none" {
        fail("nothing to show: pass --marker, --banner, or a --key-sound")
    }
    return options
}

// MARK: - Drawing

let markerStyles = ["reticle", "ring", "sonar", "beacon", "path", "dot"]

final class MarkerView: NSView {
    let markers: [Marker]
    let banner: [String]
    let screenHeight: CGFloat
    let style: String
    let halo: Bool
    var phase: CGFloat = 0
    var alphaScale: CGFloat = 1
    var pressedAt: [Int: Date] = [:]
    var keyFlashAt: Date?
    var keystrokes = 0
    /// Index of the marker whose action comes next. Everything before it is done, everything
    /// after it is still to come; the overlay advances it as it observes clicks and scrolls.
    var current = 0

    init(frame: NSRect, markers: [Marker], banner: [String], screenHeight: CGFloat, style: String, stroke: String) {
        self.markers = markers
        self.banner = banner
        self.screenHeight = screenHeight
        self.style = markerStyles.contains(style) ? style : "reticle"
        self.halo = stroke != "colour"
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: State

    /// Marks the next marker of the given kind as pressed, used for scroll feedback.
    @discardableResult
    func press(kind: String) -> Int? {
        let candidates = markers.indices.filter { markers[$0].kind == kind }
        guard let index = candidates.first(where: { $0 >= current }) ?? candidates.first(where: { pressedAt[$0] == nil }) ?? candidates.last else { return nil }
        complete(index)
        return index
    }

    /// Records a marker as done and moves the highlight to the one after it. A drag's start and
    /// end markers belong to one action, so both are completed together.
    func complete(_ index: Int) {
        pressedAt[index] = Date()
        var next = index + 1
        if markers[index].kind == "drag-start", next < markers.count, markers[next].kind == "drag-end" {
            pressedAt[next] = Date()
            next += 1
        }
        if next > current { current = next }
    }

    /// Consecutive markers at the same place (a key pressed three times) share one ring; this is
    /// the range of indices grouped with `index`.
    func group(of index: Int) -> ClosedRange<Int> {
        var low = index
        var high = index
        while low > 0 && markers[low - 1].samePlace(as: markers[index]) { low -= 1 }
        while high + 1 < markers.count && markers[high + 1].samePlace(as: markers[index]) { high += 1 }
        return low...high
    }

    /// Marks the marker hit by a click as pressed: the expected next marker if the click is near
    /// it, otherwise the nearest upcoming one, otherwise the nearest of all.
    @discardableResult
    func press(at location: NSPoint) -> Int? {
        func distance(_ index: Int) -> CGFloat {
            let center = point(markers[index])
            return hypot(center.x - location.x, center.y - location.y)
        }
        var chosen: Int?
        if current < markers.count, markers[current].kind != "scroll", distance(current) <= 60 {
            chosen = current
        } else {
            let upcoming = markers.indices.filter { $0 >= current && markers[$0].kind != "scroll" && distance($0) <= 60 }
            chosen = upcoming.min(by: { distance($0) < distance($1) })
                ?? markers.indices.filter { distance($0) <= 60 }.min(by: { distance($0) < distance($1) })
        }
        if let index = chosen { complete(index) }
        return chosen
    }

    // MARK: Geometry and colour

    func color(for kind: String) -> NSColor {
        switch kind {
        case "scroll": return NSColor.systemBlue
        case "move": return NSColor.systemGray
        case "drag-start", "drag-end", "double": return NSColor.systemOrange
        case "right": return NSColor.systemPurple
        default: return NSColor.systemRed
        }
    }

    /// Converts a marker's top-left-origin point to this view's bottom-left-origin space.
    func point(_ marker: Marker) -> NSPoint {
        NSPoint(x: marker.x, y: screenHeight - marker.y)
    }

    /// Strokes a shape either in the action colour or as a white line with a dark halo, which
    /// stays readable on light and dark surfaces alike.
    func stroke(_ path: NSBezierPath, tint: NSColor, width: CGFloat, alpha: CGFloat) {
        if halo {
            path.lineWidth = width + 2.5
            NSColor.black.withAlphaComponent(0.55 * alpha).setStroke()
            path.stroke()
            path.lineWidth = width
            NSColor.white.withAlphaComponent(alpha).setStroke()
            path.stroke()
        } else {
            path.lineWidth = width
            tint.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }

    func circle(_ center: NSPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func fillDot(_ center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        circle(center, radius).fill()
    }

    func drawText(_ text: String, at origin: NSPoint, size: CGFloat, alpha: CGFloat, outlined: Bool = false, centered: Bool = false) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        if outlined {
            attributes[.strokeColor] = NSColor.black.withAlphaComponent(alpha)
            attributes[.strokeWidth] = -28
        }
        let string = text as NSString
        let measured = string.size(withAttributes: attributes)
        let at = centered ? NSPoint(x: origin.x - measured.width / 2, y: origin.y - measured.height / 2) : origin
        string.draw(at: at, withAttributes: attributes)
    }

    /// Rounded label box, kept inside the screen near the right and top edges.
    func drawLabel(_ text: String, near origin: NSPoint, tint: NSColor, alpha: CGFloat, small: Bool) {
        guard !text.isEmpty else { return }
        let size: CGFloat = small ? 11 : 13
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size)]
        let measured = (text as NSString).size(withAttributes: attributes)
        var box = NSRect(x: origin.x, y: origin.y, width: measured.width + 12, height: measured.height + 6)
        if box.maxX > bounds.maxX - 8 { box.origin.x = bounds.maxX - 8 - box.width }
        if box.maxY > bounds.maxY - 8 { box.origin.y = bounds.maxY - 8 - box.height }
        if box.minY < 8 { box.origin.y = 8 }
        tint.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        drawText(text, at: NSPoint(x: box.minX + 6, y: box.minY + 3), size: size, alpha: alpha)
    }

    /// Small numbered badge, centred on a point.
    func drawBadge(_ text: String, at center: NSPoint, tint: NSColor, alpha: CGFloat) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]
        let measured = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: center.x - measured.width / 2 - 5, y: center.y - 8, width: measured.width + 10, height: 16)
        tint.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(alpha).set()
        (text as NSString).draw(at: NSPoint(x: box.minX + 5, y: box.minY + 1.5), withAttributes: [.font: attributes[.font]!, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
    }

    func drawRipple(_ center: NSPoint, tint: NSColor, progress: CGFloat, alpha: CGFloat) {
        guard progress < 1 else { return }
        let ring = circle(center, 22 + 30 * progress)
        ring.lineWidth = 2
        (halo ? NSColor.white : tint).withAlphaComponent(alpha * (1 - progress)).setStroke()
        ring.stroke()
    }

    // MARK: Banner

    func drawBanner() {
        guard !banner.isEmpty else { return }
        let flash: CGFloat = {
            guard let at = keyFlashAt else { return 0 }
            return CGFloat(max(0, 1 - Date().timeIntervalSince(at) / 0.18))
        }()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alphaScale),
        ]
        let lines = banner.map { ("\u{2328}  " + $0) as NSString }
        let sizes = lines.map { $0.size(withAttributes: attributes) }
        let width = min(bounds.width - 80, (sizes.map { $0.width }.max() ?? 0) + 28)
        let lineHeight = (sizes.first?.height ?? 17) + 4
        let height = lineHeight * CGFloat(lines.count) + 16
        let box = NSRect(x: (bounds.width - width) / 2, y: bounds.height - 40 - height, width: width, height: height)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.08, alpha: 0.88 * alphaScale).setFill()
        path.fill()
        path.lineWidth = 2 + 2 * flash
        NSColor.systemRed.withAlphaComponent(alphaScale * (0.55 + 0.45 * flash)).setStroke()
        path.stroke()
        for (index, line) in lines.enumerated() {
            let y = box.maxY - 10 - lineHeight * CGFloat(index + 1) + 4
            let clip = NSRect(x: box.minX + 14, y: y, width: width - 28, height: lineHeight)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            line.draw(at: NSPoint(x: clip.minX, y: y), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Markers

    struct Frame {
        let index: Int
        let marker: Marker
        let center: NSPoint
        let tint: NSColor
        let isCurrent: Bool
        let isDone: Bool
        let isPressed: Bool
        let pressProgress: CGFloat
        let alpha: CGFloat
        let pulse: CGFloat
        let rangeText: String
        let labelText: String
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBanner()
        let sequential = markers.count > 1
        if style == "path" && sequential { drawRoute() }
        var frames: [Frame] = []
        for (index, marker) in markers.enumerated() {
            let group = group(of: index)
            // One shape per place: the first marker of a group draws it while the group is
            // pending, and the label names the whole group.
            if sequential && group.lowerBound != index && pressedAt[index] == nil { continue }
            let isCurrent = !sequential || group.contains(current)
            let isDone = sequential && group.upperBound < current
            let emphasis: CGFloat = isCurrent ? 1 : (isDone ? 0.22 : 0.4)
            let pressProgress: CGFloat = {
                guard let pressed = pressedAt[index] else { return 0 }
                return CGFloat(min(1, Date().timeIntervalSince(pressed) / 0.35))
            }()
            let numbers = group.compactMap { markers[$0].number }
            let range = numbers.count > 1 ? "\(numbers.first!)-\(numbers.last!)" : (numbers.first.map(String.init) ?? "")
            var labelText = marker.label
            if sequential {
                labelText = isDone ? "" : (isCurrent ? [range, marker.text].filter { !$0.isEmpty }.joined(separator: " ") : range)
            }
            frames.append(Frame(index: index, marker: marker, center: point(marker), tint: color(for: marker.kind),
                                isCurrent: isCurrent, isDone: isDone, isPressed: pressedAt[index] != nil, pressProgress: pressProgress,
                                alpha: alphaScale * emphasis, pulse: isCurrent ? sin(phase * .pi * 2) : 0,
                                rangeText: sequential ? range : "", labelText: labelText))
        }
        var dragStart: NSPoint?
        for frame in frames {
            if frame.marker.kind == "drag-start" { dragStart = frame.center }
            if frame.marker.kind == "drag-end", let start = dragStart {
                let line = NSBezierPath()
                line.move(to: start)
                line.line(to: frame.center)
                line.setLineDash([8, 6], count: 2, phase: phase * 14)
                stroke(line, tint: frame.tint, width: 3, alpha: frame.alpha)
            }
            switch style {
            case "ring": drawRing(frame)
            case "sonar": drawSonar(frame)
            case "beacon": drawBeacon(frame)
            case "path": drawStop(frame)
            case "dot": drawDot(frame)
            default: drawReticle(frame)
            }
        }
    }

    /// Reticle: four corner brackets framing the target, a badge on the corner, nothing across it.
    func drawReticle(_ f: Frame) {
        if f.isDone {
            fillDot(f.center, radius: 4, color: f.tint.withAlphaComponent(f.alpha))
            return
        }
        let base: CGFloat = f.isCurrent ? 22 : 15
        let half = f.isPressed ? base - 5 * (1 - f.pressProgress * 0.4) : base + base * 0.08 * f.pulse
        let arm: CGFloat = f.isCurrent ? 9 : 6
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for corner in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
            let cx = f.center.x + CGFloat(corner.0) * half
            let cy = f.center.y + CGFloat(corner.1) * half
            path.move(to: NSPoint(x: cx - CGFloat(corner.0) * arm, y: cy))
            path.line(to: NSPoint(x: cx, y: cy))
            path.line(to: NSPoint(x: cx, y: cy - CGFloat(corner.1) * arm))
        }
        if f.isPressed { drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha) }
        stroke(path, tint: f.tint, width: f.isCurrent ? 3 : 2, alpha: f.alpha)
        fillDot(f.center, radius: 3.5, color: f.tint.withAlphaComponent(f.alpha))
        if !f.rangeText.isEmpty {
            drawBadge(f.rangeText, at: NSPoint(x: f.center.x + half + 4, y: f.center.y + half + 4), tint: f.tint, alpha: f.alpha)
        }
        if f.isCurrent && !f.marker.text.isEmpty {
            // To the right of the frame, level with the centre, so it never lands on the next target below.
            drawLabel(f.marker.text, near: NSPoint(x: f.center.x + half + 12, y: f.center.y - 10), tint: f.tint, alpha: f.alpha, small: true)
        }
    }

    /// Ring and crosshair, the original look.
    func drawRing(_ f: Frame) {
        let radius: CGFloat = (f.isCurrent ? 22 : 16) + 4 * f.pulse
        let r = f.isPressed ? radius * (1 - 0.35 * f.pressProgress) : radius
        if f.isPressed {
            f.tint.withAlphaComponent(f.alpha * 0.5 * (1 - f.pressProgress)).setFill()
            circle(f.center, r).fill()
            drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha)
        }
        stroke(circle(f.center, r), tint: f.tint, width: f.isCurrent ? 4 : 3, alpha: f.alpha)
        fillDot(f.center, radius: 3, color: f.tint.withAlphaComponent(f.alpha))
        if f.isCurrent {
            let cross = NSBezierPath()
            for d in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                cross.move(to: NSPoint(x: f.center.x + CGFloat(d.0) * (r + 2), y: f.center.y + CGFloat(d.1) * (r + 2)))
                cross.line(to: NSPoint(x: f.center.x + CGFloat(d.0) * (r + 10), y: f.center.y + CGFloat(d.1) * (r + 10)))
            }
            stroke(cross, tint: f.tint, width: 2, alpha: f.alpha)
            drawLabel(f.labelText, near: NSPoint(x: f.center.x + radius + 12, y: f.center.y + radius - 2), tint: f.tint, alpha: f.alpha, small: false)
        } else if !f.isDone {
            drawBadge(f.rangeText, at: NSPoint(x: f.center.x + radius + 8, y: f.center.y + radius), tint: f.tint, alpha: f.alpha)
        }
    }

    /// Sonar: a thin ring with two pulses spreading outward.
    func drawSonar(_ f: Frame) {
        if f.isPressed {
            fillDot(f.center, radius: 10, color: f.tint.withAlphaComponent(f.alpha * 0.6))
            drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha)
        } else if f.isCurrent {
            let spread = CGFloat(phase)
            for (base, strength) in [(22.0, 0.5), (30.0, 0.25)] {
                let ring = circle(f.center, CGFloat(base) + 6 * spread)
                ring.lineWidth = 1.5
                f.tint.withAlphaComponent(f.alpha * CGFloat(strength) * (1 - spread * 0.6)).setStroke()
                ring.stroke()
            }
        }
        stroke(circle(f.center, f.isCurrent ? 14 : 11), tint: f.tint, width: 2, alpha: f.alpha)
        fillDot(f.center, radius: 3, color: f.tint.withAlphaComponent(f.alpha))
        if f.isCurrent {
            drawLabel(f.labelText, near: NSPoint(x: f.center.x + 20, y: f.center.y + 14), tint: f.tint, alpha: f.alpha, small: true)
        } else if !f.isDone {
            drawBadge(f.rangeText, at: NSPoint(x: f.center.x + 18, y: f.center.y + 14), tint: f.tint, alpha: f.alpha)
        }
    }

    /// Beacon: a translucent disc with the number inside.
    func drawBeacon(_ f: Frame) {
        let radius: CGFloat = (f.isCurrent ? 22 : 16) + 2 * f.pulse
        if f.isPressed { drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha) }
        fillDot(f.center, radius: radius, color: f.tint.withAlphaComponent(f.alpha * (f.isPressed ? 0.55 : 0.28)))
        let edge = circle(f.center, radius)
        edge.lineWidth = 2
        f.tint.withAlphaComponent(f.alpha * 0.85).setStroke()
        edge.stroke()
        if !f.rangeText.isEmpty {
            drawText(f.rangeText, at: f.center, size: f.isCurrent ? 15 : 12, alpha: f.alpha, centered: true)
        } else {
            fillDot(f.center, radius: 4, color: NSColor.white.withAlphaComponent(f.alpha))
        }
        if f.isCurrent && !f.marker.text.isEmpty {
            drawLabel(f.marker.text, near: NSPoint(x: f.center.x - 28, y: f.center.y - radius - 24), tint: f.tint, alpha: f.alpha, small: true)
        }
    }

    /// Path: the dashed route through every target, drawn once under the stops.
    func drawRoute() {
        guard markers.count > 1 else { return }
        let route = NSBezierPath()
        route.move(to: point(markers[0]))
        for marker in markers.dropFirst() { route.line(to: point(marker)) }
        route.lineWidth = 3
        NSColor.white.withAlphaComponent(alphaScale * 0.35).setStroke()
        route.stroke()
        route.lineWidth = 1.5
        route.setLineDash([6, 5], count: 2, phase: phase * 11)
        color(for: markers[0].kind).withAlphaComponent(alphaScale * 0.9).setStroke()
        route.stroke()
    }

    /// Path stop: a numbered disc on the route, the current one ringed.
    func drawStop(_ f: Frame) {
        if f.isPressed { drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha) }
        if f.isCurrent {
            let ring = circle(f.center, 19 + 2 * f.pulse)
            ring.lineWidth = 3
            f.tint.withAlphaComponent(f.alpha).setStroke()
            ring.stroke()
        }
        let fill = f.isDone ? NSColor(calibratedWhite: 0.55, alpha: 1) : (f.isCurrent ? f.tint : NSColor(calibratedWhite: 0.12, alpha: 1))
        fillDot(f.center, radius: 11, color: fill.withAlphaComponent(f.alpha))
        let edge = circle(f.center, 11)
        edge.lineWidth = 2
        (f.isCurrent ? f.tint : NSColor.white).withAlphaComponent(f.alpha).setStroke()
        edge.stroke()
        drawText(f.rangeText.isEmpty ? "\u{2022}" : f.rangeText, at: f.center, size: 11, alpha: f.isDone ? f.alpha : max(f.alpha, alphaScale * 0.9), centered: true)
        if f.isCurrent && !f.marker.text.isEmpty {
            drawLabel(f.marker.text, near: NSPoint(x: f.center.x + 24, y: f.center.y + 12), tint: f.tint, alpha: f.alpha, small: true)
        }
    }

    /// Dot: the quietest option, a dot and a hairline ring.
    func drawDot(_ f: Frame) {
        if f.isPressed { drawRipple(f.center, tint: f.tint, progress: f.pressProgress, alpha: f.alpha) }
        if f.isCurrent {
            stroke(circle(f.center, (f.isPressed ? 15 : 11) + 1.5 * f.pulse), tint: f.tint, width: 1.5, alpha: f.alpha)
        }
        fillDot(f.center, radius: f.isCurrent ? 5 : 4, color: f.tint.withAlphaComponent(f.alpha))
        let rim = circle(f.center, f.isCurrent ? 5 : 4)
        rim.lineWidth = 1.5
        NSColor.white.withAlphaComponent(f.alpha).setStroke()
        rim.stroke()
        if !f.rangeText.isEmpty {
            drawText(f.rangeText, at: NSPoint(x: f.center.x + 12, y: f.center.y + 10), size: 11, alpha: f.alpha, outlined: true, centered: true)
        }
        if f.isCurrent && !f.marker.text.isEmpty {
            drawLabel(f.marker.text, near: NSPoint(x: f.center.x + 16, y: f.center.y - 26), tint: f.tint, alpha: f.alpha, small: true)
        }
    }
}

// MARK: - Overlay application

final class OverlayDelegate: NSObject, NSApplicationDelegate {
    let options: ShowOptions
    var window: NSWindow!
    var view: MarkerView!
    var clickPlayer: SoundPlayer?
    var keyPlayer: SoundPlayer?
    var scrollPlayer: SoundPlayer?
    var startedAt = Date()
    var fadingOut = false
    var signalSources: [DispatchSourceSignal] = []
    var monitors: [Any] = []
    var lastScrollSound = Date.distantPast
    let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(options: ShowOptions) {
        self.options = options
    }

    let logQueue = DispatchQueue(label: "click-overlay.log")
    var lastKeySound = Date.distantPast

    /// Appends to the log file on a background queue so event monitors return immediately.
    func log(_ message: String) {
        guard let path = options.logPath else { return }
        let line = "\(dateFormatter.string(from: Date())) overlay[\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        logQueue.async {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = primaryScreen()
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view = MarkerView(frame: NSRect(origin: .zero, size: screen.frame.size), markers: options.markers, banner: options.banner, screenHeight: screen.frame.height, style: options.style, stroke: options.stroke)
        window.contentView = view
        window.orderFrontRegardless()

        // Order matters: markers and monitors first, audio afterwards. A cold audio engine can take
        // seconds to start and the click must not land before the monitors exist.
        log("shown markers=\(options.markers.count) banner=\(options.banner.count) style=\(options.style)/\(options.stroke) sound=\(options.sound) key=\(options.keySound) scroll=\(options.scrollSound) accessibilityTrusted=\(AXIsProcessTrusted())")

        // Synthetic events posted by computer use reach global monitors like real ones, so these
        // fire at the moment each click, keystroke, or scroll tick lands.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [self] event in
            let location = NSEvent.mouseLocation
            let hit = view.press(at: location)
            let played = clickPlayer?.play() ?? "audio-not-ready"
            log("mouse-down type=\(event.type.rawValue) at=(\(Int(location.x)),\(Int(screen.frame.height - location.y))) marker=\(hit.map { String($0 + 1) } ?? "none") next=\(view.current + 1) sound=\(played)")
        }) { monitors.append(monitor) } else { log("global mouse monitor unavailable") }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [self] event in
            // Keep this handler cheap: computer use types at roughly 100 keystrokes per second and
            // the monitor drops events when the handler cannot keep up. Every keystroke is counted;
            // the sound is rate-limited so rapid typing sounds like typing instead of a buzz.
            view.keystrokes += 1
            let now = Date()
            view.keyFlashAt = now
            var played = "throttled"
            if now.timeIntervalSince(lastKeySound) >= 0.03 {
                lastKeySound = now
                played = keyPlayer?.play() ?? "audio-not-ready"
            }
            let characters = event.characters ?? ""
            log("key-down keyCode=\(event.keyCode) chars=\(characters.count) count=\(view.keystrokes) sound=\(played)")
        }) { monitors.append(monitor) } else { log("global key monitor unavailable") }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [self] event in
            let hit = view.press(kind: "scroll")
            var played = "throttled"
            if Date().timeIntervalSince(lastScrollSound) > 0.12 {
                lastScrollSound = Date()
                played = scrollPlayer?.play() ?? "audio-not-ready"
            }
            log("scroll dy=\(Int(event.scrollingDeltaY)) dx=\(Int(event.scrollingDeltaX)) marker=\(hit.map { String($0 + 1) } ?? "none") sound=\(played)")
        }) { monitors.append(monitor) } else { log("global scroll monitor unavailable") }

        if let readyFile = options.readyFile {
            FileManager.default.createFile(atPath: readyFile, contents: Data())
        }

        let audioStart = Date()
        let options = self.options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let click = SoundPlayer(spec: options.sound, volume: options.volume, stateDirectory: options.stateDirectory)
            let key = SoundPlayer(spec: options.keySound, volume: options.volume, stateDirectory: options.stateDirectory)
            let scroll = SoundPlayer(spec: options.scrollSound, volume: options.volume, stateDirectory: options.stateDirectory)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.clickPlayer = click
                self.keyPlayer = key
                self.scrollPlayer = scroll
                for (label, player) in [("click", click), ("key", key), ("scroll", scroll)] {
                    if let problem = player.problem { self.log("\(label) sound problem: \(problem), staying silent") }
                }
                self.log("audio ready in \(Int(Date().timeIntervalSince(audioStart) * 1000)) ms")
            }
        }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [self] _ in
            let elapsed = Date().timeIntervalSince(startedAt)
            view.phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.0))
            if fadingOut || elapsed > options.ttl - 0.3 {
                view.alphaScale = max(0, view.alphaScale - 0.12)
                let playing = [clickPlayer, keyPlayer, scrollPlayer].contains { $0?.isPlaying ?? false }
                if view.alphaScale <= 0 && !playing { finish() }
            }
            view.needsDisplay = true
        }

        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [self] in fadingOut = true }
            source.resume()
            signalSources.append(source)
        }
    }

    func finish() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        log("exit keystrokes=\(view.keystrokes)")
        logQueue.sync {}
        NSApp.terminate(nil)
    }
}
