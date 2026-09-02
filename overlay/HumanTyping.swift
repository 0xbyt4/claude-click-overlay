import AppKit
import CoreGraphics
import Foundation

// Types text with human-like pacing by posting keyboard events, playing the key sound as each
// character is sent. Used by the hook's ASMR typing mode after the CLI has typed the first
// character itself, which validates that the frontmost app accepts typing.

struct HumanTypingOptions {
    var text = ""
    var charactersPerSecond = 10.0
    var maxSeconds = 60.0
    var sound = "mechkey"
    var volume: Float = 0.6
    var logPath: String?
}

func parseHumanTypingOptions(_ args: [String]) -> HumanTypingOptions {
    var options = HumanTypingOptions()
    var index = 0
    func value(for flag: String) -> String {
        guard index + 1 < args.count else { fail("\(flag) needs a value") }
        index += 2
        return args[index - 1]
    }
    while index < args.count {
        switch args[index] {
        case "--cps":
            guard let cps = Double(value(for: "--cps")), cps > 0 else { fail("--cps needs a positive number") }
            options.charactersPerSecond = cps
        case "--max-seconds":
            guard let seconds = Double(value(for: "--max-seconds")), seconds > 0 else { fail("--max-seconds needs a positive number") }
            options.maxSeconds = seconds
        case "--sound":
            options.sound = value(for: "--sound")
        case "--volume":
            guard let volume = Float(value(for: "--volume")) else { fail("--volume needs a number") }
            options.volume = volume
        case "--log":
            options.logPath = value(for: "--log")
        case "--text-file":
            let path = value(for: "--text-file")
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
            options.text = text
        default:
            options.text = args[index]
            index += 1
        }
    }
    return options
}

/// Gaussian sample via Box-Muller, for log-normal timing jitter.
func gaussianSample() -> Double {
    let u1 = Double.random(in: 0.000_01...1)
    let u2 = Double.random(in: 0...1)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

/// Delay to wait after sending `character`, imitating a person: jitter around the base rate,
/// a beat after spaces, longer after punctuation and line breaks, and the odd pause to think.
func humanDelay(after character: Character, base: Double) -> Double {
    var delay = base * exp(0.35 * gaussianSample())
    if character == " " { delay *= 1.4 }
    if ".,;:!?".contains(character) { delay += Double.random(in: 0.15...0.35) }
    if character == "\n" { delay += Double.random(in: 0.25...0.5) }
    if Double.random(in: 0...1) < 0.02 { delay += Double.random(in: 0.4...0.9) }
    return delay
}

func postKeystroke(_ character: Character, source: CGEventSource?) {
    let virtualKey: CGKeyCode? = character == "\n" || character == "\r" ? 36 : (character == "\t" ? 48 : nil)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey ?? 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey ?? 0, keyDown: false) else { return }
    if virtualKey == nil {
        var units = Array(String(character).utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func runHumanTyping(_ options: HumanTypingOptions) {
    let characters = Array(options.text)
    guard !characters.isEmpty else { print("typed 0 characters"); return }
    var base = 1.0 / options.charactersPerSecond
    // Keep long texts within the time budget by speeding up proportionally.
    if Double(characters.count) * base * 1.25 > options.maxSeconds {
        base = options.maxSeconds / (Double(characters.count) * 1.25)
    }
    let logHandle = options.logPath.flatMap { path -> FileHandle? in
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        return FileHandle(forWritingAtPath: path)
    }
    func log(_ message: String) {
        guard let handle = logHandle else { return }
        handle.seekToEndOfFile()
        handle.write("\(ISO8601DateFormatter().string(from: Date())) type-human[\(ProcessInfo.processInfo.processIdentifier)] \(message)\n".data(using: .utf8)!)
    }

    let player = SoundPlayer(spec: options.sound, volume: options.volume, stateDirectory: nil)
    if let problem = player.problem { log("sound problem: \(problem)") }
    var aborted = false
    // Esc pressed by a person aborts, matching computer use's own escape hatch. Our own events
    // never carry keyCode 53.
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
        if event.keyCode == 53 { aborted = true }
    }
    let source = CGEventSource(stateID: .hidSystemState)
    let started = Date()
    var sent = 0
    log("start characters=\(characters.count) cps=\(String(format: "%.1f", 1 / base)) sound=\(options.sound)")
    for character in characters {
        if aborted { break }
        postKeystroke(character, source: source)
        sent += 1
        player.play()
        RunLoop.main.run(until: Date().addingTimeInterval(humanDelay(after: character, base: base)))
    }
    let deadline = Date().addingTimeInterval(2)
    while player.isPlaying && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    let elapsed = Date().timeIntervalSince(started)
    log("done sent=\(sent) of \(characters.count) in \(String(format: "%.1f", elapsed))s aborted=\(aborted)")
    logHandle?.closeFile()
    print("typed \(sent) of \(characters.count) characters in \(String(format: "%.1f", elapsed))s\(aborted ? " (aborted with Esc)" : "")")
    if aborted { exit(3) }
}
