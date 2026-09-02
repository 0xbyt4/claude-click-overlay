import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders each marker style with the overlay's own drawing code into an animated GIF for the
// README: a batch on a light settings list, showing done, current, upcoming, the click ripple,
// and the highlight moving on.
//
// Usage: render-styles OUTPUT_DIR [--stroke halo|colour] [--scale 2]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputDirectory = arguments.first else { fail("usage: render-styles OUTPUT_DIR [--stroke halo|colour] [--scale N]") }
var strokeName = "halo"
var scale: CGFloat = 2
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--stroke": strokeName = arguments[index + 1]; index += 2
    case "--scale": scale = CGFloat(Double(arguments[index + 1]) ?? 2); index += 2
    default: fail("unknown argument \(arguments[index])")
    }
}
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let canvas = NSSize(width: 300, height: 200)
let frameRate = 12.0
let frameCount = 40

/// A mock settings list, like the light surfaces the overlay lands on.
func drawListBackground() {
    NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.957, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas).fill()
    let card = NSRect(x: 24, y: 20, width: 252, height: 160)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
    NSColor.white.setFill()
    cardPath.fill()
    NSColor(calibratedWhite: 0.855, alpha: 1).setStroke()
    cardPath.lineWidth = 1
    cardPath.stroke()
    let rows = ["Displays", "Sound", "Battery", "General"]
    let icons: [NSColor] = [
        NSColor(calibratedRed: 0.18, green: 0.49, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.94, green: 0.31, blue: 0.31, alpha: 1),
        NSColor(calibratedRed: 0.24, green: 0.75, blue: 0.36, alpha: 1),
        NSColor(calibratedWhite: 0.5, alpha: 1),
    ]
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 1)]
    let chevron: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1)]
    for (row, name) in rows.enumerated() {
        // Rows are laid out from the top in the same coordinates the markers use (top-left origin).
        let yTop = 40 + CGFloat(row) * 38
        let y = canvas.height - yTop
        icons[row].setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: y - 10, width: 20, height: 20), xRadius: 5, yRadius: 5).fill()
        (name as NSString).draw(at: NSPoint(x: 70, y: y - 9), withAttributes: attributes)
        ("\u{203A}" as NSString).draw(at: NSPoint(x: 252, y: y - 9), withAttributes: chevron)
        if row < rows.count - 1 {
            NSColor(calibratedWhite: 0.93, alpha: 1).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 70, y: y - 19))
            line.line(to: NSPoint(x: 262, y: y - 19))
            line.stroke()
        }
    }
}

func makeMarkers() -> [Marker] {
    [
        Marker(x: 250, y: 40, label: "1 left click", kind: "click"),
        Marker(x: 150, y: 78, label: "2 left click", kind: "click"),
        Marker(x: 150, y: 116, label: "3 left click", kind: "click"),
        Marker(x: 250, y: 154, label: "4 scroll", kind: "scroll"),
    ]
}

/// Timeline: marker 1 already done; 2 pulses, gets clicked; 3 pulses, gets clicked; 4 pulses.
func configure(view: MarkerView, frame: Int) {
    let now = Date()
    view.phase = CGFloat(Double(frame) / frameRate).truncatingRemainder(dividingBy: 1)
    view.pressedAt = [0: now.addingTimeInterval(-5)]
    view.current = 1
    let pressSecond = 14
    let pressThird = 27
    if frame >= pressSecond {
        view.pressedAt[1] = now.addingTimeInterval(-Double(frame - pressSecond) / frameRate)
        view.current = 2
    }
    if frame >= pressThird {
        view.pressedAt[2] = now.addingTimeInterval(-Double(frame - pressThird) / frameRate)
        view.current = 3
    }
}

func renderFrame(style: String, frame: Int) -> CGImage {
    let view = MarkerView(frame: NSRect(origin: .zero, size: canvas), markers: makeMarkers(), banner: [], screenHeight: canvas.height, style: style, stroke: strokeName)
    configure(view: view, frame: frame)
    let width = Int(canvas.width * scale)
    let height = Int(canvas.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // The bitmap's point size is the canvas, so the context already maps points to pixels.
    drawListBackground()
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

for style in markerStyles {
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(style).gif")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { fail("cannot create \(url.path)") }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<frameCount {
        let image = renderFrame(style: style, frame: frame)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / frameRate]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(url.lastPathComponent) (\(frameCount) frames, \(bytes / 1024) KB)")
}
