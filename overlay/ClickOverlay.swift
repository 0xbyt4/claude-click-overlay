import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// click-overlay: draws transparent, click-through markers on the primary display so the
// user can see where a Claude Code computer-use action is about to land, and plays a
// sound when the click actually happens.
//
// Subcommands:
//   show [--ttl SECONDS] [--sound SPEC] [--key-sound SPEC] [--scroll-sound SPEC] [--volume 0..1]
//        [--log FILE] [--state-dir DIR] [--ready-file FILE] [--banner TEXT ...] [--marker X,Y,LABEL,KIND ...]
//        X,Y are logical points with a top-left origin (CGWindowList convention).
//        KIND is one of: click, scroll, move, drag-start, drag-end.
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

final class MarkerView: NSView {
    let markers: [Marker]
    let banner: [String]
    let screenHeight: CGFloat
    var phase: CGFloat = 0
    var alphaScale: CGFloat = 1
    var pressedAt: [Int: Date] = [:]
    var keyFlashAt: Date?
    var keystrokes = 0
    /// Index of the marker whose action comes next. Everything before it is done, everything
    /// after it is still to come; the overlay advances it as it observes clicks and scrolls.
    var current = 0

    init(frame: NSRect, markers: [Marker], banner: [String], screenHeight: CGFloat) {
        self.markers = markers
        self.banner = banner
        self.screenHeight = screenHeight
        super.init(frame: frame)
    }

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

    required init?(coder: NSCoder) { nil }

    func color(for kind: String) -> NSColor {
        switch kind {
        case "scroll": return NSColor.systemBlue
        case "move": return NSColor.systemGray
        case "drag-start", "drag-end": return NSColor.systemOrange
        default: return NSColor.systemRed
        }
    }

    /// Converts a marker's top-left-origin point to this view's bottom-left-origin space.
    func point(_ marker: Marker) -> NSPoint {
        NSPoint(x: marker.x, y: screenHeight - marker.y)
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

    override func draw(_ dirtyRect: NSRect) {
        drawBanner()
        var dragStart: NSPoint?
        let sequential = markers.count > 1
        for (index, marker) in markers.enumerated() {
            let group = group(of: index)
            // One ring per place: the first marker of a group draws it while the group is
            // pending, and the label names the whole group.
            if sequential && group.lowerBound != index && pressedAt[index] == nil { continue }
            let isCurrent = !sequential || group.contains(current)
            let isDone = sequential && group.upperBound < current
            let emphasis: CGFloat = isCurrent ? 1 : (isDone ? 0.22 : 0.4)
            let center = point(marker)
            let tint = color(for: marker.kind).withAlphaComponent(alphaScale * emphasis)
            let pressProgress: CGFloat = {
                guard let pressed = pressedAt[index] else { return 0 }
                return CGFloat(min(1, Date().timeIntervalSince(pressed) / 0.35))
            }()
            let isPressed = pressedAt[index] != nil

            if marker.kind == "drag-start" { dragStart = center }
            if marker.kind == "drag-end", let start = dragStart {
                let line = NSBezierPath()
                line.move(to: start)
                line.line(to: center)
                line.lineWidth = 3
                line.setLineDash([8, 6], count: 2, phase: phase * 14)
                tint.setStroke()
                line.stroke()
            }

            let pulse = isCurrent ? 4 * sin(phase * .pi * 2) : 0
            let baseRadius: CGFloat = (marker.kind == "move" ? 14 : (isCurrent ? 22 : 16)) + pulse
            let radius = isPressed ? baseRadius * (1 - 0.35 * pressProgress) : baseRadius
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = marker.kind == "move" ? 2 : 4
            tint.setStroke()
            ring.stroke()
            if isPressed {
                tint.withAlphaComponent(alphaScale * 0.5 * (1 - pressProgress)).setFill()
                ring.fill()
                let ripple = baseRadius + 30 * pressProgress
                let ripplePath = NSBezierPath(ovalIn: NSRect(x: center.x - ripple, y: center.y - ripple, width: ripple * 2, height: ripple * 2))
                ripplePath.lineWidth = 2
                tint.withAlphaComponent(alphaScale * (1 - pressProgress)).setStroke()
                ripplePath.stroke()
            }

            let inner = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            tint.setFill()
            inner.fill()

            if marker.kind != "move" {
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: center.x - radius - 10, y: center.y))
                cross.line(to: NSPoint(x: center.x - radius + 2, y: center.y))
                cross.move(to: NSPoint(x: center.x + radius - 2, y: center.y))
                cross.line(to: NSPoint(x: center.x + radius + 10, y: center.y))
                cross.move(to: NSPoint(x: center.x, y: center.y - radius - 10))
                cross.line(to: NSPoint(x: center.x, y: center.y - radius + 2))
                cross.move(to: NSPoint(x: center.x, y: center.y + radius - 2))
                cross.line(to: NSPoint(x: center.x, y: center.y + radius + 10))
                cross.lineWidth = 2
                cross.stroke()
            }

            // Label: the current group gets its full text, upcoming groups only their numbers,
            // finished groups nothing.
            var labelText = marker.label
            if sequential {
                let numbers = group.compactMap { markers[$0].number }
                let range = numbers.count > 1 ? "\(numbers.first!)-\(numbers.last!)" : (numbers.first.map(String.init) ?? "")
                if isDone {
                    labelText = ""
                } else if isCurrent {
                    labelText = [range, marker.text].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    labelText = range
                }
            }
            if !labelText.isEmpty {
                let text = labelText as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: isCurrent ? 13 : 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(alphaScale * (isCurrent ? 1 : 0.85)),
                ]
                let size = text.size(withAttributes: attributes)
                var origin = NSPoint(x: center.x + baseRadius + 12, y: center.y + baseRadius - 2)
                // Keep the label on screen near the right and top edges.
                if origin.x + size.width + 12 > bounds.maxX { origin.x = center.x - baseRadius - size.width - 24 }
                if origin.y + size.height + 6 > bounds.maxY { origin.y = center.y - baseRadius - size.height - 8 }
                let box = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
                tint.setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
            }
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
        view = MarkerView(frame: NSRect(origin: .zero, size: screen.frame.size), markers: options.markers, banner: options.banner, screenHeight: screen.frame.height)
        window.contentView = view
        window.orderFrontRegardless()

        // Order matters: markers and monitors first, audio afterwards. A cold audio engine can take
        // seconds to start and the click must not land before the monitors exist.
        log("shown markers=\(options.markers.count) banner=\(options.banner.count) sound=\(options.sound) key=\(options.keySound) scroll=\(options.scrollSound) accessibilityTrusted=\(AXIsProcessTrusted())")

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
