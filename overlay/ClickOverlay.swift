import AppKit
import CoreGraphics
import Foundation

// click-overlay: draws transparent, click-through markers on the primary display so the
// user can see where a Claude Code computer-use action is about to land.
//
// Subcommands:
//   show [--ttl SECONDS] --marker X,Y,LABEL,KIND [--marker ...]
//        X,Y are logical points with a top-left origin (CGWindowList convention).
//        KIND is one of: click, scroll, move, drag-start, drag-end.
//        Exits after TTL seconds or on SIGTERM/SIGINT (fades out first).
//   cursor   Prints the current cursor position as JSON (logical points, top-left origin).
//   screen   Prints the primary display geometry as JSON.

struct Marker {
    let x: CGFloat
    let y: CGFloat
    let label: String
    let kind: String
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

func parseMarkers(_ args: [String]) -> (markers: [Marker], ttl: Double) {
    var markers: [Marker] = []
    var ttl = 2.0
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--ttl":
            guard i + 1 < args.count, let value = Double(args[i + 1]) else { fail("--ttl needs a number") }
            ttl = value
            i += 2
        case "--marker":
            guard i + 1 < args.count else { fail("--marker needs X,Y,LABEL,KIND") }
            let parts = args[i + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                fail("bad marker: \(args[i + 1])")
            }
            let label = parts.count > 2 ? parts[2] : ""
            let kind = parts.count > 3 ? parts[3] : "click"
            markers.append(Marker(x: CGFloat(x), y: CGFloat(y), label: label, kind: kind))
            i += 2
        default:
            fail("unknown argument: \(args[i])")
        }
    }
    if markers.isEmpty { fail("at least one --marker is required") }
    return (markers, ttl)
}

final class MarkerView: NSView {
    let markers: [Marker]
    let screenHeight: CGFloat
    var phase: CGFloat = 0
    var alphaScale: CGFloat = 1

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

    func point(_ marker: Marker) -> NSPoint {
        NSPoint(x: marker.x, y: screenHeight - marker.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        var dragStart: NSPoint?
        for marker in markers {
            let center = point(marker)
            let tint = color(for: marker.kind).withAlphaComponent(alphaScale)

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
            let radius: CGFloat = (marker.kind == "move" ? 14 : 22) + pulse
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = marker.kind == "move" ? 2 : 4
            tint.setStroke()
            ring.stroke()

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
                var origin = NSPoint(x: center.x + radius + 12, y: center.y + radius - 2)
                // Keep the label on screen near the right and top edges.
                if origin.x + size.width + 12 > bounds.maxX { origin.x = center.x - radius - size.width - 24 }
                if origin.y + size.height + 6 > bounds.maxY { origin.y = center.y - radius - size.height - 8 }
                let box = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
                tint.setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
            }
        }
    }
}

final class OverlayDelegate: NSObject, NSApplicationDelegate {
    let markers: [Marker]
    let ttl: Double
    var window: NSWindow!
    var view: MarkerView!
    var startedAt = Date()
    var fadingOut = false

    init(markers: [Marker], ttl: Double) {
        self.markers = markers
        self.ttl = ttl
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
        view = MarkerView(frame: NSRect(origin: .zero, size: screen.frame.size), markers: markers, screenHeight: screen.frame.height)
        window.contentView = view
        window.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [self] _ in
            let elapsed = Date().timeIntervalSince(startedAt)
            view.phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.0))
            if fadingOut || elapsed > ttl - 0.3 {
                view.alphaScale = max(0, view.alphaScale - 0.12)
                if view.alphaScale <= 0 { NSApp.terminate(nil) }
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

    var signalSources: [DispatchSourceSignal] = []
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: click-overlay show|cursor|screen ...")
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
case "show":
    let (markers, ttl) = parseMarkers(Array(arguments.dropFirst()))
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = OverlayDelegate(markers: markers, ttl: ttl)
    app.delegate = delegate
    app.run()
default:
    fail("unknown command: \(command)")
}
