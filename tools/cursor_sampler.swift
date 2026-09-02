import AppKit
import CoreGraphics
// Samples the real cursor position (logical points, top-left origin) at 50 ms intervals.
// Usage: cursor_sampler <seconds> <logfile>
let secs = Double(CommandLine.arguments[1])!
let logPath = CommandLine.arguments[2]
FileManager.default.createFile(atPath: logPath, contents: nil)
let h = FileHandle(forWritingAtPath: logPath)!
let start = Date()
let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })!
h.write("# screen logical=\(Int(screen.frame.width))x\(Int(screen.frame.height)) backingScale=\(screen.backingScaleFactor)\n".data(using: .utf8)!)
while Date().timeIntervalSince(start) < secs {
    if let loc = CGEvent(source: nil)?.location {
        let t = Date().timeIntervalSince(start)
        h.write(String(format: "%.3f %.2f %.2f\n", t, loc.x, loc.y).data(using: .utf8)!)
    }
    usleep(50_000)
}
h.closeFile()
