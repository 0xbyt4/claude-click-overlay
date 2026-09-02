import AVFoundation
import AppKit
import Foundation

// Synthesized sounds, melodies, speech, and the player used by the overlay. Everything is
// generated in code at runtime, so the repository ships no third-party audio.

let sampleRate = 44_100.0

enum Waveform {
    case sine, square, triangle, saw, noise
}

struct NoiseSource {
    var state: UInt32 = 0x9E37_79B9

    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state >> 8) / Double(1 << 24) * 2 - 1
    }
}

// MARK: - Envelopes and pitch curves

func decay(_ rate: Double) -> (Double) -> Double {
    { t in exp(-t * rate) }
}

func pluck(attack: Double, rate: Double) -> (Double) -> Double {
    { t in min(1, t / attack) * exp(-t * rate) }
}

func gate(attack: Double, length: Double, release: Double) -> (Double) -> Double {
    { t in max(0, min(1, t / attack, (length - t) / release)) }
}

func constant(_ value: Double) -> (Double) -> Double {
    { _ in value }
}

func glide(from start: Double, to end: Double, over duration: Double) -> (Double) -> Double {
    { t in start * pow(end / start, min(1, t / duration)) }
}

func midiFrequency(_ note: Int) -> Double {
    440 * pow(2, Double(note - 69) / 12)
}

// MARK: - Renderer

final class Renderer {
    private(set) var samples: [Double]
    let count: Int
    private var noise = NoiseSource()

    init(duration: Double) {
        count = max(1, Int(sampleRate * duration))
        samples = [Double](repeating: 0, count: count)
    }

    /// Adds a tone whose frequency and amplitude are functions of the time since the tone began.
    func tone(_ wave: Waveform, at start: Double = 0, duration: Double, frequency: (Double) -> Double, amplitude: (Double) -> Double) {
        var phase = 0.0
        let first = Int(start * sampleRate)
        let length = Int(duration * sampleRate)
        for index in 0..<length {
            let position = first + index
            if position >= count { break }
            let t = Double(index) / sampleRate
            phase += 2 * .pi * frequency(t) / sampleRate
            let value: Double
            switch wave {
            case .sine: value = sin(phase)
            case .square: value = sin(phase) >= 0 ? 1 : -1
            case .triangle: value = 2 / .pi * asin(sin(phase))
            case .saw: value = phase.truncatingRemainder(dividingBy: 2 * .pi) / .pi - 1
            case .noise: value = noise.next()
            }
            samples[position] += value * amplitude(t)
        }
    }

    func lowpass(cutoff: Double) {
        let dt = 1 / sampleRate
        let alpha = dt / (1 / (2 * .pi * cutoff) + dt)
        var output = 0.0
        for index in 0..<count {
            output += alpha * (samples[index] - output)
            samples[index] = output
        }
    }

    func distort(drive: Double) {
        for index in 0..<count {
            samples[index] = tanh(samples[index] * drive)
        }
    }

    /// 16-bit mono WAV, normalized so the loudest sample sits at `peak`.
    func wavData(peak: Double = 0.85) -> Data {
        let loudest = max(samples.map { abs($0) }.max() ?? 1, 1e-9)
        let scale = peak / loudest
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            pcm[index] = Int16(max(-1, min(1, samples[index] * scale)) * 32_767)
        }
        var data = Data()
        func append<T>(_ value: T) {
            var copy = value
            withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(count * 2)
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
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - Presets

struct Preset {
    let name: String
    let summary: String
    let render: () -> Data
}

let presets: [Preset] = [
    Preset(name: "tick", summary: "short neutral click, the default") {
        let r = Renderer(duration: 0.045)
        r.tone(.sine, duration: 0.045, frequency: constant(1_800), amplitude: { t in 0.7 * exp(-t * 90) })
        r.tone(.sine, duration: 0.045, frequency: constant(3_600), amplitude: { t in 0.2 * exp(-t * 90) })
        r.tone(.noise, duration: 0.045, frequency: constant(0), amplitude: { t in 0.25 * exp(-t * 400) })
        return r.wavData(peak: 0.8)
    },
    Preset(name: "bubble", summary: "bubble pop") {
        let r = Renderer(duration: 0.12)
        r.tone(.sine, duration: 0.12, frequency: glide(from: 700, to: 150, over: 0.1), amplitude: decay(30))
        return r.wavData()
    },
    Preset(name: "blip", summary: "8-bit blip") {
        let r = Renderer(duration: 0.07)
        r.tone(.square, duration: 0.07, frequency: constant(880), amplitude: decay(45))
        return r.wavData(peak: 0.6)
    },
    Preset(name: "beep", summary: "classic beep") {
        let r = Renderer(duration: 0.12)
        r.tone(.sine, duration: 0.12, frequency: constant(1_000), amplitude: gate(attack: 0.005, length: 0.12, release: 0.02))
        return r.wavData(peak: 0.7)
    },
    Preset(name: "ding", summary: "small bell") {
        let r = Renderer(duration: 0.7)
        r.tone(.sine, duration: 0.7, frequency: constant(1_568), amplitude: decay(5))
        r.tone(.sine, duration: 0.7, frequency: constant(2_093), amplitude: { t in 0.5 * exp(-t * 7) })
        r.tone(.sine, duration: 0.7, frequency: constant(3_136), amplitude: { t in 0.25 * exp(-t * 9) })
        return r.wavData(peak: 0.7)
    },
    Preset(name: "woodblock", summary: "wood block") {
        let r = Renderer(duration: 0.1)
        r.tone(.sine, duration: 0.1, frequency: constant(800), amplitude: decay(60))
        r.tone(.sine, duration: 0.1, frequency: constant(1_200), amplitude: { t in 0.5 * exp(-t * 80) })
        r.tone(.noise, duration: 0.02, frequency: constant(0), amplitude: { t in 0.4 * exp(-t * 400) })
        return r.wavData()
    },
    Preset(name: "typewriter", summary: "typewriter key") {
        let r = Renderer(duration: 0.09)
        r.tone(.noise, duration: 0.02, frequency: constant(0), amplitude: decay(300))
        r.tone(.sine, duration: 0.01, frequency: constant(2_500), amplitude: decay(500))
        r.tone(.sine, at: 0.006, duration: 0.06, frequency: constant(160), amplitude: { t in 0.8 * exp(-t * 80) })
        return r.wavData()
    },
    Preset(name: "keyboard", summary: "mechanical key switch") {
        let r = Renderer(duration: 0.1)
        r.tone(.noise, duration: 0.012, frequency: constant(0), amplitude: decay(700))
        r.tone(.sine, duration: 0.012, frequency: constant(3_200), amplitude: { t in 0.6 * exp(-t * 600) })
        r.tone(.sine, at: 0.045, duration: 0.05, frequency: constant(420), amplitude: { t in 0.9 * exp(-t * 90) })
        r.tone(.noise, at: 0.045, duration: 0.01, frequency: constant(0), amplitude: { t in 0.3 * exp(-t * 600) })
        return r.wavData()
    },
    Preset(name: "shutter", summary: "camera shutter") {
        let r = Renderer(duration: 0.14)
        r.tone(.noise, duration: 0.03, frequency: constant(0), amplitude: decay(150))
        r.tone(.noise, at: 0.07, duration: 0.06, frequency: constant(0), amplitude: decay(120))
        r.tone(.sine, at: 0.07, duration: 0.05, frequency: constant(900), amplitude: { t in 0.5 * exp(-t * 200) })
        return r.wavData()
    },
    Preset(name: "drum", summary: "kick drum") {
        let r = Renderer(duration: 0.3)
        r.tone(.sine, duration: 0.3, frequency: glide(from: 160, to: 45, over: 0.15), amplitude: decay(12))
        return r.wavData()
    },
    Preset(name: "rimshot", summary: "ba-dum-tss") {
        let r = Renderer(duration: 0.9)
        r.tone(.sine, duration: 0.14, frequency: glide(from: 170, to: 55, over: 0.1), amplitude: decay(25))
        r.tone(.sine, at: 0.17, duration: 0.14, frequency: glide(from: 150, to: 50, over: 0.1), amplitude: decay(25))
        r.tone(.noise, at: 0.36, duration: 0.5, frequency: constant(0), amplitude: { t in 0.7 * exp(-t * 7) })
        r.tone(.sine, at: 0.36, duration: 0.3, frequency: constant(6_000), amplitude: { t in 0.15 * exp(-t * 12) })
        return r.wavData()
    },
    Preset(name: "pew", summary: "laser") {
        let r = Renderer(duration: 0.22)
        r.tone(.saw, duration: 0.22, frequency: glide(from: 1_400, to: 180, over: 0.2), amplitude: decay(12))
        return r.wavData(peak: 0.7)
    },
    Preset(name: "jump", summary: "platformer jump") {
        let r = Renderer(duration: 0.18)
        r.tone(.square, duration: 0.18, frequency: glide(from: 300, to: 900, over: 0.15), amplitude: decay(10))
        return r.wavData(peak: 0.6)
    },
    Preset(name: "coin", summary: "coin pickup") {
        let r = Renderer(duration: 0.42)
        r.tone(.square, duration: 0.06, frequency: constant(1_047), amplitude: constant(1))
        r.tone(.square, at: 0.06, duration: 0.36, frequency: constant(1_568), amplitude: decay(8))
        return r.wavData(peak: 0.55)
    },
    Preset(name: "powerup", summary: "rising arpeggio") {
        let notes = [72, 76, 79, 84, 88, 91]
        let r = Renderer(duration: 0.05 * Double(notes.count) + 0.2)
        for (index, note) in notes.enumerated() {
            r.tone(.square, at: 0.05 * Double(index), duration: index == notes.count - 1 ? 0.25 : 0.05, frequency: constant(midiFrequency(note)), amplitude: index == notes.count - 1 ? decay(10) : constant(1))
        }
        return r.wavData(peak: 0.55)
    },
    Preset(name: "boing", summary: "spring") {
        let r = Renderer(duration: 0.55)
        r.tone(.sine, duration: 0.55, frequency: { t in 200 * (1 + 0.8 * exp(-t * 12)) + 90 * sin(2 * .pi * 9 * t) * exp(-t * 3) }, amplitude: decay(5.5))
        r.tone(.triangle, duration: 0.55, frequency: { t in 400 * (1 + 0.8 * exp(-t * 12)) + 180 * sin(2 * .pi * 9 * t) * exp(-t * 3) }, amplitude: { t in 0.3 * exp(-t * 7) })
        return r.wavData()
    },
    Preset(name: "boom", summary: "bass drop") {
        let r = Renderer(duration: 0.85)
        r.tone(.sine, duration: 0.85, frequency: glide(from: 110, to: 30, over: 0.6), amplitude: decay(4))
        r.tone(.noise, duration: 0.08, frequency: constant(0), amplitude: { t in 0.5 * exp(-t * 80) })
        r.distort(drive: 1.6)
        return r.wavData()
    },
    Preset(name: "airhorn", summary: "air horn") {
        let r = Renderer(duration: 0.75)
        let fall: (Double) -> Double = { t in 1 - 0.04 * max(0, (t - 0.55) / 0.2) }
        for base in [220.0, 221.5, 330.0, 328.5, 440.0, 441.0] {
            r.tone(.saw, duration: 0.75, frequency: { t in base * fall(t) }, amplitude: gate(attack: 0.02, length: 0.75, release: 0.1))
        }
        r.distort(drive: 3)
        r.lowpass(cutoff: 2_500)
        return r.wavData()
    },
    Preset(name: "fart", summary: "you know") {
        let r = Renderer(duration: 0.45)
        r.tone(.saw, duration: 0.45, frequency: { t in 80 - 35 * t + 10 * sin(2 * .pi * 21 * t) }, amplitude: { t in (0.55 + 0.45 * abs(sin(2 * .pi * 15 * t))) * exp(-t * 3) })
        r.tone(.noise, duration: 0.45, frequency: constant(0), amplitude: { t in 0.35 * exp(-t * 4) })
        r.lowpass(cutoff: 350)
        r.distort(drive: 2)
        return r.wavData()
    },
    Preset(name: "trombone", summary: "sad trombone") {
        let r = Renderer(duration: 1.85)
        let notes: [(start: Double, length: Double, frequency: Double)] = [(0, 0.28, 233.1), (0.3, 0.28, 220), (0.6, 0.28, 207.7), (0.9, 0.9, 196)]
        for (index, note) in notes.enumerated() {
            let last = index == notes.count - 1
            r.tone(.saw, at: note.start, duration: note.length, frequency: { t in
                let vibrato = 1 + 0.012 * sin(2 * .pi * 5.5 * t)
                let droop = last ? 1 - 0.06 * max(0, (t - 0.5) / 0.4) : 1
                return note.frequency * vibrato * droop
            }, amplitude: { t in max(0, min(1, t / 0.06, (note.length - t) / 0.08)) })
        }
        r.lowpass(cutoff: 1_200)
        return r.wavData()
    },
    Preset(name: "robot", summary: "beep-boop") {
        let r = Renderer(duration: 0.24)
        r.tone(.square, duration: 0.09, frequency: constant(420), amplitude: gate(attack: 0.005, length: 0.09, release: 0.02))
        r.tone(.square, at: 0.11, duration: 0.12, frequency: constant(280), amplitude: gate(attack: 0.005, length: 0.12, release: 0.03))
        return r.wavData(peak: 0.55)
    },
    Preset(name: "quack", summary: "duck") {
        let r = Renderer(duration: 0.16)
        r.tone(.saw, duration: 0.16, frequency: glide(from: 380, to: 260, over: 0.12), amplitude: { t in (0.5 + 0.5 * abs(sin(2 * .pi * 28 * t))) * max(0, min(1, t / 0.01, (0.16 - t) / 0.04)) })
        r.lowpass(cutoff: 1_800)
        r.distort(drive: 2)
        return r.wavData()
    },
]

// MARK: - Melodies (public domain tunes as MIDI notes, 0 is a rest)

let melodies: [(name: String, summary: String, notes: [Int])] = [
    ("scale", "C major scale", [60, 62, 64, 65, 67, 69, 71, 72]),
    ("twinkle", "Twinkle Twinkle Little Star", [60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60]),
    ("ode", "Ode to Joy", [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62]),
    ("birthday", "Happy Birthday", [60, 60, 62, 60, 65, 64, 60, 60, 62, 60, 67, 65, 60, 60, 72, 69, 65, 64, 62, 70, 70, 69, 65, 67, 65]),
    ("jingle", "Jingle Bells", [64, 64, 64, 64, 64, 64, 64, 67, 60, 62, 64, 65, 65, 65, 65, 65, 64, 64, 64, 64, 62, 62, 64, 62, 67]),
    ("tetris", "Korobeiniki", [76, 71, 72, 74, 72, 71, 69, 69, 72, 76, 74, 72, 71, 72, 74, 76, 72, 69, 69, 74, 77, 81, 79, 77, 76, 72, 76, 74, 72, 71, 71, 72, 74, 76, 72, 69, 69]),
    ("elise", "Fur Elise", [76, 75, 76, 75, 76, 71, 74, 72, 69, 60, 64, 69, 71, 64, 68, 71, 72]),
]

let noteLength = 0.16
let noteSpacing = 0.18

func renderNote(_ note: Int, at start: Double = 0, into renderer: Renderer) {
    guard note > 0 else { return }
    let frequency = midiFrequency(note)
    renderer.tone(.square, at: start, duration: noteLength, frequency: constant(frequency), amplitude: { t in 0.6 * min(1, t / 0.005) * exp(-t * 9) })
    renderer.tone(.sine, at: start, duration: noteLength, frequency: constant(frequency), amplitude: { t in 0.4 * min(1, t / 0.005) * exp(-t * 7) })
}

func noteData(_ note: Int) -> Data {
    let r = Renderer(duration: noteLength)
    renderNote(note, into: r)
    return r.wavData(peak: 0.6)
}

func melodyData(_ notes: [Int]) -> Data {
    let r = Renderer(duration: noteSpacing * Double(notes.count) + 0.1)
    for (index, note) in notes.enumerated() {
        renderNote(note, at: noteSpacing * Double(index), into: r)
    }
    return r.wavData(peak: 0.6)
}

// MARK: - System sounds

let systemSoundsDirectory = "/System/Library/Sounds"

func systemSoundNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDirectory)) ?? []
    return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
}

/// Resolves a single sound name: a preset, a macOS system sound (case-insensitive), or a file path.
func loadSingleSound(_ name: String) -> NSSound? {
    let key = name.lowercased()
    if let preset = presets.first(where: { $0.name == key }) {
        return NSSound(data: preset.render())
    }
    if name.contains("/") {
        return NSSound(contentsOfFile: (name as NSString).expandingTildeInPath, byReference: false)
    }
    if let match = systemSoundNames().first(where: { $0.lowercased() == key }) {
        return NSSound(contentsOfFile: "\(systemSoundsDirectory)/\(match).aiff", byReference: false)
    }
    return nil
}

// MARK: - Player

/// Plays whatever `--sound` asks for on every click.
/// Specs: "none", a preset or system sound or file, "random", "random:a,b,c", "melody:NAME", "say:TEXT".
final class SoundPlayer: NSObject {
    private enum Mode {
        case silent
        case single(String, NSSound)
        case random([(String, NSSound)])
        case melody(String, [Int])
        case speech(String)
    }

    private let mode: Mode
    private let volume: Float
    private let stateDirectory: String?
    private var noteCache: [Int: NSSound] = [:]
    private var current: NSSound?
    private lazy var synthesizer = AVSpeechSynthesizer()
    private(set) var problem: String?

    init(spec rawSpec: String, volume: Float, stateDirectory: String?) {
        let spec = rawSpec.trimmingCharacters(in: .whitespaces)
        self.volume = max(0, min(1, volume))
        self.stateDirectory = stateDirectory
        var problem: String?
        var mode = Mode.silent
        let lowered = spec.lowercased()
        if spec.isEmpty || lowered == "none" {
            mode = .silent
        } else if lowered == "random" || lowered.hasPrefix("random:") {
            let names = lowered == "random" ? presets.map { $0.name } : spec.dropFirst("random:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var choices: [(String, NSSound)] = []
            for name in names {
                if let sound = loadSingleSound(name) { choices.append((name, sound)) } else { problem = "unknown sound in random list: \(name)" }
            }
            mode = choices.isEmpty ? .silent : .random(choices)
        } else if lowered.hasPrefix("melody:") {
            let name = String(lowered.dropFirst("melody:".count))
            if let melody = melodies.first(where: { $0.name == name }) {
                mode = .melody(melody.name, melody.notes)
            } else {
                problem = "unknown melody: \(name)"
            }
        } else if lowered.hasPrefix("say:") {
            let text = String(spec.dropFirst("say:".count)).trimmingCharacters(in: .whitespaces)
            mode = text.isEmpty ? .silent : .speech(text)
        } else if let sound = loadSingleSound(spec) {
            mode = .single(spec, sound)
        } else {
            problem = "unknown sound: \(spec)"
        }
        self.mode = mode
        self.problem = problem
        super.init()
    }

    var isSilent: Bool {
        if case .silent = mode { return true }
        return false
    }

    var isPlaying: Bool {
        if case .speech = mode { return synthesizer.isSpeaking }
        return current?.isPlaying ?? false
    }

    private func start(_ sound: NSSound) {
        current?.stop()
        sound.volume = volume
        sound.play()
        current = sound
    }

    private var positionFile: String? {
        guard let directory = stateDirectory, case let .melody(name, _) = mode else { return nil }
        return "\(directory)/melody-\(name).pos"
    }

    private func loadPosition() -> Int {
        guard let file = positionFile, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func savePosition(_ position: Int) {
        guard let file = positionFile else { return }
        try? String(position).write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Plays the next thing and returns a short description for the log.
    @discardableResult
    func play() -> String {
        switch mode {
        case .silent:
            return "none"
        case let .single(name, sound):
            start(sound)
            return name
        case let .random(choices):
            let choice = choices.randomElement()!
            start(choice.1)
            return "random:\(choice.0)"
        case let .melody(name, notes):
            let position = loadPosition() % notes.count
            let note = notes[position]
            savePosition((position + 1) % notes.count)
            if note > 0 {
                let sound = noteCache[note] ?? NSSound(data: noteData(note))!
                noteCache[note] = sound
                start(sound)
            }
            return "melody:\(name) note \(position + 1)/\(notes.count)"
        case let .speech(text):
            synthesizer.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.volume = volume
            synthesizer.speak(utterance)
            return "say:\(text)"
        }
    }

    /// Renders the spec to WAV data for previews and files. Speech cannot be rendered.
    func previewData() -> Data? {
        switch mode {
        case .silent, .speech:
            return nil
        case let .single(name, _):
            if let preset = presets.first(where: { $0.name == name.lowercased() }) { return preset.render() }
            return nil
        case let .random(choices):
            let choice = choices.randomElement()!
            return presets.first(where: { $0.name == choice.0.lowercased() })?.render()
        case let .melody(_, notes):
            return melodyData(notes)
        }
    }

    /// Plays the whole thing once and waits for it to finish, for `play` previews.
    func playPreview(timeout: Double = 12) -> String {
        var description = ""
        if case let .melody(name, notes) = mode {
            start(NSSound(data: melodyData(notes))!)
            description = "melody:\(name) (\(notes.count) notes)"
        } else {
            description = play()
        }
        let deadline = Date().addingTimeInterval(timeout)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        while isPlaying && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return description
    }
}

// MARK: - Config file shared with the hook

func configPath() -> String {
    if let custom = ProcessInfo.processInfo.environment["CLICK_OVERLAY_CONFIG"], !custom.isEmpty {
        return (custom as NSString).expandingTildeInPath
    }
    return ("~/.config/claude-click-overlay/config.json" as NSString).expandingTildeInPath
}

func readConfig() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: configPath()),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

func writeConfig(_ config: [String: Any]) throws {
    let path = configPath()
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}
