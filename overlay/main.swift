import AppKit
import Foundation

// Entry point: dispatches the subcommands documented in ClickOverlay.swift.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: click-overlay show|sounds|play|render|use|cursor|screen ...")
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
    print("Choose: click-overlay use CLICK_SPEC [--key SPEC] [--scroll SPEC] [--volume 0..1]")
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
    for (flag, target) in [("--key", 0), ("--scroll", 1)] {
        if let index = rest.firstIndex(of: flag) {
            guard index + 1 < rest.count else { fail("\(flag) needs a sound spec") }
            if target == 0 { keySpec = rest[index + 1] } else { scrollSpec = rest[index + 1] }
            rest.removeSubrange(index...index + 1)
        }
    }
    for extra in [keySpec, scrollSpec].compactMap({ $0 }) {
        if let problem = SoundPlayer(spec: extra, volume: volume, stateDirectory: nil).problem { fail("\(problem). Run 'click-overlay sounds' to list the options.") }
    }
    let spec = rest.first
    if command != "use" && spec == nil { fail("usage: click-overlay \(command) SPEC [--volume 0..1]") }
    if command == "use" && spec == nil && keySpec == nil && scrollSpec == nil { fail("usage: click-overlay use [CLICK_SPEC] [--key SPEC] [--scroll SPEC] [--volume 0..1] | use --clear") }
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
        config["volume"] = NSDecimalNumber(string: String(format: "%.2f", volume))
        do { try writeConfig(config) } catch { fail("cannot write config: \(error.localizedDescription)") }
        print("click=\(config["sound"] ?? "tick") key=\(config["key_sound"] ?? "keyboard") scroll=\(config["scroll_sound"] ?? "none") volume=\(volume) saved to \(configPath())")
    }
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
