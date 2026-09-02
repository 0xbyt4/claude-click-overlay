import AppKit
import CoreGraphics
import Foundation

// click-overlay: draws transparent, click-through markers on the primary display so the
// user can see where a Claude Code computer-use action is about to land, and plays a
// sound when the click actually happens.
//
// Subcommands:
//   show [--ttl SECONDS] [--sound NAME] [--volume 0..1] [--log FILE] --marker X,Y,LABEL,KIND ...
//        X,Y are logical points with a top-left origin (CGWindowList convention).
//        KIND is one of: click, scroll, move, drag-start, drag-end.
//        Exits after TTL seconds or on SIGTERM/SIGINT (fades out first).
//   sounds            Lists the available sound names.
//   play NAME [--volume 0..1]
//                     Plays a sound once so you can preview it.
//   cursor            Prints the current cursor position as JSON (logical points, top-left origin).
//   screen            Prints the primary display geometry as JSON.

struct Marker {
    let x: CGFloat
    let y: CGFloat
    let label: String
    let kind: String
}

struct ShowOptions {
    var markers: [Marker] = []
    var ttl: Double = 2.0
    var sound = "tick"
    var volume: Float = 0.6
    var logPath: String?
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

// MARK: - Sounds

let systemSoundsDirectory = "/System/Library/Sounds"

func systemSoundNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDirectory)) ?? []
    return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
}

/// A short synthesized click: a decaying two-tone burst with a touch of noise, as 16-bit mono WAV.
func tickWaveData() -> Data {
    let sampleRate = 44_100
    let sampleCount = Int(Double(sampleRate) * 0.045)
    var samples = [Int16](repeating: 0, count: sampleCount)
    var seed: UInt32 = 12_345
    for index in 0..<sampleCount {
        let t = Double(index) / Double(sampleRate)
        let envelope = exp(-t * 90)
        let tone = sin(2 * .pi * 1_800 * t) * 0.7 + sin(2 * .pi * 3_600 * t) * 0.2
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = (Double(seed >> 8) / Double(1 << 24) * 2 - 1) * 0.25 * exp(-t * 400)
        let value = max(-1, min(1, (tone + noise) * envelope))
        samples[index] = Int16(value * 32_767 * 0.9)
    }
    var data = Data()
    func append<T>(_ value: T) {
        var copy = value
        withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
    }
    let byteCount = UInt32(sampleCount * 2)
    data.append("RIFF".data(using: .ascii)!)
    append(UInt32(36 + byteCount))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append("data".data(using: .ascii)!)
    append(byteCount)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// Resolves a sound name to an NSSound. Names: "none", "tick", a macOS system sound such as
/// "Tink" or "Pop" (case-insensitive), or a path to an audio file.
func makeSound(named name: String, volume: Float) -> NSSound? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.lowercased() == "none" { return nil }
    var sound: NSSound?
    if trimmed.lowercased() == "tick" {
        sound = NSSound(data: tickWaveData())
    } else if trimmed.contains("/") {
        sound = NSSound(contentsOfFile: (trimmed as NSString).expandingTildeInPath, byReference: false)
    } else if let match = systemSoundNames().first(where: { $0.lowercased() == trimmed.lowercased() }) {
        sound = NSSound(contentsOfFile: "\(systemSoundsDirectory)/\(match).aiff", byReference: false)
    }
    sound?.volume = max(0, min(1, volume))
    return sound
}

func playAndWait(_ sound: NSSound, timeout: Double = 5) {
    sound.play()
    let deadline = Date().addingTimeInterval(timeout)
    while sound.isPlaying && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
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
        case "--volume":
            guard let volume = Float(value(for: "--volume")) else { fail("--volume needs a number") }
            options.volume = volume
        case "--log":
            options.logPath = value(for: "--log")
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
    if options.markers.isEmpty { fail("at least one --marker is required") }
    return options
}

// MARK: - Drawing

final class MarkerView: NSView {
    let markers: [Marker]
    let screenHeight: CGFloat
    var phase: CGFloat = 0
    var alphaScale: CGFloat = 1
    var pressedAt: [Int: Date] = [:]

    init(frame: NSRect, markers: [Marker], screenHeight: CGFloat) {
        self.markers = markers
        self.screenHeight = screenHeight
        super.init(frame: frame)
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

    /// Marks the marker nearest to a screen location (AppKit coordinates) as pressed.
    func press(at location: NSPoint) {
        var best: (index: Int, distance: CGFloat)?
        for (index, marker) in markers.enumerated() {
            let center = point(marker)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= 60 && (best == nil || distance < best!.distance) {
                best = (index, distance)
            }
        }
        if let best = best { pressedAt[best.index] = Date() }
    }

    override func draw(_ dirtyRect: NSRect) {
        var dragStart: NSPoint?
        for (index, marker) in markers.enumerated() {
            let center = point(marker)
            let tint = color(for: marker.kind).withAlphaComponent(alphaScale)
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

            let pulse = 4 * sin(phase * .pi * 2)
            let baseRadius: CGFloat = (marker.kind == "move" ? 14 : 22) + pulse
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

            if !marker.label.isEmpty {
                let text = marker.label as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.white.withAlphaComponent(alphaScale),
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
    var sound: NSSound?
    var startedAt = Date()
    var fadingOut = false
    var signalSources: [DispatchSourceSignal] = []
    var clickMonitor: Any?
    let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(options: ShowOptions) {
        self.options = options
    }

    func log(_ message: String) {
        guard let path = options.logPath else { return }
        let line = "\(dateFormatter.string(from: Date())) overlay[\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
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
        view = MarkerView(frame: NSRect(origin: .zero, size: screen.frame.size), markers: options.markers, screenHeight: screen.frame.height)
        window.contentView = view
        window.orderFrontRegardless()

        sound = makeSound(named: options.sound, volume: options.volume)
        if sound == nil && options.sound.lowercased() != "none" && !options.sound.isEmpty {
            log("sound '\(options.sound)' not found, staying silent")
        }
        log("shown markers=\(options.markers.count) sound=\(sound == nil ? "none" : options.sound)")

        // Synthetic clicks posted by computer use reach global monitors like real ones, so this
        // fires at the moment each click lands, which is when the sound and the press animation belong.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [self] event in
            let location = NSEvent.mouseLocation
            view.press(at: location)
            if let sound = sound {
                if sound.isPlaying { sound.stop() }
                sound.play()
            }
            log("mouse-down type=\(event.type.rawValue) at=(\(Int(location.x)),\(Int(screen.frame.height - location.y))) sound=\(sound == nil ? "none" : "played")")
        }
        if clickMonitor == nil { log("global mouse monitor unavailable") }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [self] _ in
            let elapsed = Date().timeIntervalSince(startedAt)
            view.phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.0))
            if fadingOut || elapsed > options.ttl - 0.3 {
                view.alphaScale = max(0, view.alphaScale - 0.12)
                if view.alphaScale <= 0 && !(sound?.isPlaying ?? false) { finish() }
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
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        log("exit")
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: click-overlay show|sounds|play|cursor|screen ...")
}

switch command {
case "screen":
    let screen = primaryScreen()
    printJSON([
        "name": screen.localizedName,
        "width": Int(screen.frame.width),
        "height": Int(screen.frame.height),
        "backingScale": Double(screen.backingScaleFactor),
    ])
case "cursor":
    guard let location = CGEvent(source: nil)?.location else { fail("cannot read cursor") }
    printJSON(["x": Double(location.x), "y": Double(location.y)])
case "sounds":
    print("none")
    print("tick")
    for name in systemSoundNames() { print(name) }
    print("<path to an .aiff, .wav, .caf or .mp3 file>")
case "play":
    let rest = Array(arguments.dropFirst())
    guard let name = rest.first else { fail("usage: click-overlay play NAME [--volume 0..1]") }
    var volume: Float = 0.6
    if rest.count >= 3, rest[1] == "--volume", let parsed = Float(rest[2]) { volume = parsed }
    guard let sound = makeSound(named: name, volume: volume) else { fail("unknown sound: \(name). Run 'click-overlay sounds' to list the options.") }
    playAndWait(sound)
    print("played \(name)")
case "show":
    let options = parseShowOptions(Array(arguments.dropFirst()))
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = OverlayDelegate(options: options)
    app.delegate = delegate
    app.run()
default:
    fail("unknown command: \(command)")
}
