import AppKit

// Usage: overlay_test <x> <y> <seconds> <logfile>
// x,y are logical points with top-left origin (same convention as CGWindowList).
let args = CommandLine.arguments
let px = Double(args[1])!, py = Double(args[2])!, secs = Double(args[3])!
let logPath = args[4]
let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func log(_ s: String) {
    let line = "\(fmt.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}

final class RingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
        ring.lineWidth = 4
        NSColor.systemRed.setStroke(); ring.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: c.x - 30, y: c.y)); cross.line(to: NSPoint(x: c.x + 30, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - 30)); cross.line(to: NSPoint(x: c.x, y: c.y + 30))
        cross.lineWidth = 2; NSColor.systemRed.withAlphaComponent(0.8).setStroke(); cross.stroke()
        let label = "Claude click" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        let bg = NSRect(x: c.x + 28, y: c.y + 20, width: sz.width + 12, height: sz.height + 6)
        NSColor.systemRed.setFill(); NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: bg.minX + 6, y: bg.minY + 3), withAttributes: attrs)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { exit(2) }
        let size: CGFloat = 220
        // Convert top-left-origin point to AppKit bottom-left-origin frame.
        let appkitY = screen.frame.height - py
        let frame = NSRect(x: px - size/2, y: appkitY - size/2, width: size, height: size)
        win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.contentView = RingView(frame: NSRect(origin: .zero, size: frame.size))
        win.orderFrontRegardless()
        log("overlay shown pid=\(ProcessInfo.processInfo.processIdentifier) at logical(\(px),\(py)) level=\(win.level.rawValue)")
        NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            log("EVENT: app was HIDDEN by someone (NSApp.isHidden=\(NSApp.isHidden))")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
            log("EVENT: app UNHIDDEN")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main) { _ in
            log("EVENT: occlusion changed visible=\(self.win.occlusionState.contains(.visible))")
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            log("tick hidden=\(NSApp.isHidden) winVisible=\(self.win.isVisible) occlVisible=\(self.win.occlusionState.contains(.visible))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { log("exit after \(secs)s"); NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Delegate(); app.delegate = d
app.run()
