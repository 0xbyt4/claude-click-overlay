import AppKit
import Foundation

// Entry point: dispatches the subcommands documented in ClickOverlay.swift.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: click-overlay show|sounds|play|render|use|type-human|cursor|screen ...")
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
    print("Presets (synthesized, no files needed):")
    for preset in presets { print("  \(preset.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(preset.summary)") }
    print("System sounds: " + systemSoundNames().joined(separator: ", "))
    print("Melodies (one note per click): " + melodies.map { "melody:\($0.name) (\($0.summary))" }.joined(separator: ", "))
    print("Modes: random | random:a,b,c | say:TEXT | /path/to/file.aiff | none")
    print("Choose: click-overlay use CLICK_SPEC [--key SPEC] [--scroll SPEC] [--typing fast|asmr] [--banner on|off] [--cps N] [--volume 0..1]")
case "play", "render", "use":
    var rest = Array(arguments.dropFirst())
    var volume: Float = 0.6
    if let index = rest.firstIndex(of: "--volume") {
        guard index + 1 < rest.count, let parsed = Float(rest[index + 1]) else { fail("--volume needs a number") }
        volume = parsed
        rest.removeSubrange(index...index + 1)
    }
    if command == "use" && rest.first == "--clear" {
        try? FileManager.default.removeItem(atPath: configPath())
        print("config removed, back to defaults (\(configPath()))")
        exit(0)
    }
    var keySpec: String?
    var scrollSpec: String?
    var extras: [String: Any] = [:]
    for (flag, target) in [("--key", 0), ("--scroll", 1), ("--typing", 2), ("--banner", 3), ("--cps", 4)] {
        if let index = rest.firstIndex(of: flag) {
            guard index + 1 < rest.count else { fail("\(flag) needs a value") }
            let value = rest[index + 1]
            switch target {
            case 0: keySpec = value
            case 1: scrollSpec = value
            case 2:
                guard ["fast", "asmr"].contains(value.lowercased()) else { fail("--typing must be fast or asmr") }
                extras["typing"] = value.lowercased()
            case 3:
                guard ["on", "off"].contains(value.lowercased()) else { fail("--banner must be on or off") }
                extras["typing_banner"] = value.lowercased()
            default:
                guard let cps = Double(value), cps > 0 else { fail("--cps needs a positive number") }
                extras["asmr_cps"] = NSDecimalNumber(string: String(format: "%.1f", cps))
            }
            rest.removeSubrange(index...index + 1)
        }
    }
    for extra in [keySpec, scrollSpec].compactMap({ $0 }) {
        if let problem = SoundPlayer(spec: extra, volume: volume, stateDirectory: nil).problem { fail("\(problem). Run 'click-overlay sounds' to list the options.") }
    }
    let spec = rest.first
    if command != "use" && spec == nil { fail("usage: click-overlay \(command) SPEC [--volume 0..1]") }
    if command == "use" && spec == nil && keySpec == nil && scrollSpec == nil && extras.isEmpty { fail("usage: click-overlay use [CLICK_SPEC] [--key SPEC] [--scroll SPEC] [--typing fast|asmr] [--banner on|off] [--cps N] [--volume 0..1] | use --clear") }
    let player = SoundPlayer(spec: spec ?? "none", volume: volume, stateDirectory: nil)
    if let problem = player.problem { fail("\(problem). Run 'click-overlay sounds' to list the options.") }
    if command == "play" {
        print("played \(player.playPreview())")
    } else if command == "render" {
        guard rest.count >= 2 else { fail("usage: click-overlay render SPEC FILE.wav") }
        guard let data = player.previewData() else { fail("\(spec ?? "none") cannot be rendered to a file") }
        do { try data.write(to: URL(fileURLWithPath: rest[1])) } catch { fail("cannot write \(rest[1]): \(error.localizedDescription)") }
        print("wrote \(rest[1]) (\(data.count) bytes)")
    } else {
        var config = readConfig()
        if let spec = spec { config["sound"] = spec }
        if let keySpec = keySpec { config["key_sound"] = keySpec }
        if let scrollSpec = scrollSpec { config["scroll_sound"] = scrollSpec }
        for (key, value) in extras { config[key] = value }
        config["volume"] = NSDecimalNumber(string: String(format: "%.2f", volume))
        do { try writeConfig(config) } catch { fail("cannot write config: \(error.localizedDescription)") }
        let typing = (config["typing"] as? String) ?? "asmr"
        let keyDefault = typing == "asmr" ? "mechkey" : "none"
        print("click=\(config["sound"] ?? "mouse") key=\(config["key_sound"] ?? keyDefault) scroll=\(config["scroll_sound"] ?? "none") typing=\(typing) banner=\(config["typing_banner"] ?? "off") volume=\(volume) saved to \(configPath())")
    }
case "type-human":
    runHumanTyping(parseHumanTypingOptions(Array(arguments.dropFirst())))
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
