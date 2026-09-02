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
    private var noise: NoiseSource

    init(duration: Double, seed: Int = 0) {
        count = max(1, Int(sampleRate * duration))
        samples = [Double](repeating: 0, count: count)
        noise = NoiseSource(state: 0x9E37_79B9 &+ UInt32(truncatingIfNeeded: seed &* 7_919))
    }

    /// Adds another renderer's samples at an offset, for layers that need their own filtering.
    func mix(_ other: Renderer, at start: Double = 0, gain: Double = 1) {
        let first = Int(start * sampleRate)
        for index in 0..<other.count {
            let position = first + index
            if position >= count { break }
            samples[position] += other.samples[index] * gain
        }
    }

    func highpass(cutoff: Double) {
        let dt = 1 / sampleRate
        let alpha = dt / (1 / (2 * .pi * cutoff) + dt)
        var low = 0.0
        for index in 0..<count {
            low += alpha * (samples[index] - low)
            samples[index] -= low
        }
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

    /// A float PCM buffer for the audio engine, normalized so the loudest sample sits at `peak`.
    func pcmBuffer(peak: Double = 0.85) -> AVAudioPCMBuffer {
        let loudest = max(samples.map { abs($0) }.max() ?? 1, 1e-9)
        let scale = peak / loudest
        let buffer = AVAudioPCMBuffer(pcmFormat: Mixer.monoFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = buffer.floatChannelData![0]
        for index in 0..<count {
            channel[index] = Float(max(-1, min(1, samples[index] * scale)))
        }
        return buffer
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
    let peak: Double
    let variants: Int
    let build: (Int) -> Renderer

    init(name: String, summary: String, peak: Double = 0.85, build: @escaping () -> Renderer) {
        self.init(name: name, summary: summary, peak: peak, variants: 1, build: { _ in build() })
    }

    /// A preset with several variants: the player picks one at random per event, which keeps
    /// rapid repeats from sounding like a single sample on a loop.
    init(name: String, summary: String, peak: Double = 0.85, variants: Int, build: @escaping (Int) -> Renderer) {
        self.name = name
        self.summary = summary
        self.peak = peak
        self.variants = max(1, variants)
        self.build = build
    }

    func wavData() -> Data { build(0).wavData(peak: peak) }
    func buffers() -> [AVAudioPCMBuffer] { (0..<variants).map { build($0).pcmBuffer(peak: peak) } }
}

let presets: [Preset] = [
    Preset(name: "mouse", summary: "old mechanical mouse microswitch, the default for clicks", peak: 0.8, variants: 4) { variant in
        let j = Double(variant)
        let pitch = 1 + 0.04 * sin(j * 1.7)
        let release = 0.072 + 0.01 * sin(j * 2.3)
        let r = Renderer(duration: release + 0.07, seed: 11 + variant)
        func snap(at start: Double, level: Double, tone: Double) {
            // Metal leaf spring snapping: a broadband tick with bright metallic ringing.
            let tick = Renderer(duration: 0.004, seed: 17 + variant)
            tick.tone(.noise, duration: 0.004, frequency: constant(0), amplitude: { t in exp(-t * 2_200) })
            tick.highpass(cutoff: 2_500)
            r.mix(tick, at: start, gain: level * 0.9)
            r.tone(.sine, at: start, duration: 0.02, frequency: constant(4_200 * tone * pitch), amplitude: { t in level * 0.9 * exp(-t * 900) })
            r.tone(.sine, at: start, duration: 0.015, frequency: constant(6_300 * tone * pitch), amplitude: { t in level * 0.4 * exp(-t * 1_200) })
            // Plastic shell resonance and the finger's thud.
            r.tone(.sine, at: start, duration: 0.03, frequency: constant(950 * pitch), amplitude: { t in level * 0.5 * exp(-t * 250) })
            r.tone(.sine, at: start, duration: 0.03, frequency: constant(1_400 * pitch), amplitude: { t in level * 0.25 * exp(-t * 300) })
            r.tone(.sine, at: start, duration: 0.05, frequency: constant(180), amplitude: { t in level * 0.35 * exp(-t * 120) })
        }
        snap(at: 0, level: 1, tone: 1)
        snap(at: release, level: 0.6, tone: 1.1)
        return r
    },
    Preset(name: "mechkey", summary: "old clicky mechanical keyboard, the default for typing", peak: 0.85, variants: 6) { variant in
        let j = Double(variant)
        let pitch = 1 + 0.05 * sin(j * 1.9)
        let thock = 1 + 0.08 * cos(j * 1.3)
        let release = 0.065 + 0.015 * sin(j * 2.7)
        let r = Renderer(duration: release + 0.09, seed: 101 + variant)
        // Click jacket snapping past the slider: a sharp bright tick.
        let click = Renderer(duration: 0.003, seed: 131 + variant)
        click.tone(.noise, duration: 0.003, frequency: constant(0), amplitude: { t in exp(-t * 2_000) })
        click.highpass(cutoff: 1_800)
        r.mix(click, at: 0, gain: 0.9)
        r.tone(.sine, duration: 0.025, frequency: constant(2_600 * pitch), amplitude: { t in 0.8 * exp(-t * 600) })
        r.tone(.sine, duration: 0.02, frequency: constant(3_900 * pitch), amplitude: { t in 0.5 * exp(-t * 800) })
        // Bottom-out: the keycap hitting the plate, a low thock through the case.
        let thud = Renderer(duration: 0.03, seed: 151 + variant)
        thud.tone(.noise, duration: 0.03, frequency: constant(0), amplitude: { t in exp(-t * 250) })
        thud.lowpass(cutoff: 420)
        r.mix(thud, at: 0.006, gain: 0.9)
        r.tone(.sine, at: 0.006, duration: 0.08, frequency: constant(220 * thock), amplitude: { t in 0.9 * exp(-t * 90) })
        r.tone(.sine, at: 0.006, duration: 0.06, frequency: constant(380 * thock), amplitude: { t in 0.5 * exp(-t * 110) })
        r.tone(.sine, at: 0.006, duration: 0.05, frequency: constant(700 * pitch), amplitude: { t in 0.3 * exp(-t * 150) })
        // Release: the slider returning, a lighter clack.
        let clack = Renderer(duration: 0.002, seed: 171 + variant)
        clack.tone(.noise, duration: 0.002, frequency: constant(0), amplitude: { t in exp(-t * 2_500) })
        clack.highpass(cutoff: 2_000)
        r.mix(clack, at: release, gain: 0.5)
        r.tone(.sine, at: release, duration: 0.02, frequency: constant(3_100 * pitch), amplitude: { t in 0.5 * exp(-t * 700) })
        r.tone(.sine, at: release, duration: 0.05, frequency: constant(260 * thock), amplitude: { t in 0.35 * exp(-t * 120) })
        return r
    },
    Preset(name: "tick", summary: "short neutral click", peak: 0.8) {
        let r = Renderer(duration: 0.045)
        r.tone(.sine, duration: 0.045, frequency: constant(1_800), amplitude: { t in 0.7 * exp(-t * 90) })
        r.tone(.sine, duration: 0.045, frequency: constant(3_600), amplitude: { t in 0.2 * exp(-t * 90) })
        r.tone(.noise, duration: 0.045, frequency: constant(0), amplitude: { t in 0.25 * exp(-t * 400) })
        return r
    },
    Preset(name: "bubble", summary: "bubble pop") {
        let r = Renderer(duration: 0.12)
        r.tone(.sine, duration: 0.12, frequency: glide(from: 700, to: 150, over: 0.1), amplitude: decay(30))
        return r
    },
    Preset(name: "blip", summary: "8-bit blip", peak: 0.6) {
        let r = Renderer(duration: 0.07)
        r.tone(.square, duration: 0.07, frequency: constant(880), amplitude: decay(45))
        return r
    },
    Preset(name: "beep", summary: "classic beep", peak: 0.7) {
        let r = Renderer(duration: 0.12)
        r.tone(.sine, duration: 0.12, frequency: constant(1_000), amplitude: gate(attack: 0.005, length: 0.12, release: 0.02))
        return r
    },
    Preset(name: "ding", summary: "small bell", peak: 0.7) {
        let r = Renderer(duration: 0.7)
        r.tone(.sine, duration: 0.7, frequency: constant(1_568), amplitude: decay(5))
        r.tone(.sine, duration: 0.7, frequency: constant(2_093), amplitude: { t in 0.5 * exp(-t * 7) })
        r.tone(.sine, duration: 0.7, frequency: constant(3_136), amplitude: { t in 0.25 * exp(-t * 9) })
        return r
    },
    Preset(name: "woodblock", summary: "wood block") {
        let r = Renderer(duration: 0.1)
        r.tone(.sine, duration: 0.1, frequency: constant(800), amplitude: decay(60))
        r.tone(.sine, duration: 0.1, frequency: constant(1_200), amplitude: { t in 0.5 * exp(-t * 80) })
        r.tone(.noise, duration: 0.02, frequency: constant(0), amplitude: { t in 0.4 * exp(-t * 400) })
        return r
    },
    Preset(name: "typewriter", summary: "typewriter key") {
        let r = Renderer(duration: 0.09)
        r.tone(.noise, duration: 0.02, frequency: constant(0), amplitude: decay(300))
        r.tone(.sine, duration: 0.01, frequency: constant(2_500), amplitude: decay(500))
        r.tone(.sine, at: 0.006, duration: 0.06, frequency: constant(160), amplitude: { t in 0.8 * exp(-t * 80) })
        return r
    },
    Preset(name: "keyboard", summary: "soft key switch") {
        let r = Renderer(duration: 0.1)
        r.tone(.noise, duration: 0.012, frequency: constant(0), amplitude: decay(700))
        r.tone(.sine, duration: 0.012, frequency: constant(3_200), amplitude: { t in 0.6 * exp(-t * 600) })
        r.tone(.sine, at: 0.045, duration: 0.05, frequency: constant(420), amplitude: { t in 0.9 * exp(-t * 90) })
        r.tone(.noise, at: 0.045, duration: 0.01, frequency: constant(0), amplitude: { t in 0.3 * exp(-t * 600) })
        return r
    },
    Preset(name: "shutter", summary: "camera shutter") {
        let r = Renderer(duration: 0.14)
        r.tone(.noise, duration: 0.03, frequency: constant(0), amplitude: decay(150))
        r.tone(.noise, at: 0.07, duration: 0.06, frequency: constant(0), amplitude: decay(120))
        r.tone(.sine, at: 0.07, duration: 0.05, frequency: constant(900), amplitude: { t in 0.5 * exp(-t * 200) })
        return r
    },
    Preset(name: "drum", summary: "kick drum") {
        let r = Renderer(duration: 0.3)
        r.tone(.sine, duration: 0.3, frequency: glide(from: 160, to: 45, over: 0.15), amplitude: decay(12))
        return r
    },
    Preset(name: "rimshot", summary: "ba-dum-tss") {
        let r = Renderer(duration: 0.9)
        r.tone(.sine, duration: 0.14, frequency: glide(from: 170, to: 55, over: 0.1), amplitude: decay(25))
        r.tone(.sine, at: 0.17, duration: 0.14, frequency: glide(from: 150, to: 50, over: 0.1), amplitude: decay(25))
        r.tone(.noise, at: 0.36, duration: 0.5, frequency: constant(0), amplitude: { t in 0.7 * exp(-t * 7) })
        r.tone(.sine, at: 0.36, duration: 0.3, frequency: constant(6_000), amplitude: { t in 0.15 * exp(-t * 12) })
        return r
    },
    Preset(name: "pew", summary: "laser", peak: 0.7) {
        let r = Renderer(duration: 0.22)
        r.tone(.saw, duration: 0.22, frequency: glide(from: 1_400, to: 180, over: 0.2), amplitude: decay(12))
        return r
    },
    Preset(name: "jump", summary: "platformer jump", peak: 0.6) {
        let r = Renderer(duration: 0.18)
        r.tone(.square, duration: 0.18, frequency: glide(from: 300, to: 900, over: 0.15), amplitude: decay(10))
        return r
    },
    Preset(name: "coin", summary: "coin pickup", peak: 0.55) {
        let r = Renderer(duration: 0.42)
        r.tone(.square, duration: 0.06, frequency: constant(1_047), amplitude: constant(1))
        r.tone(.square, at: 0.06, duration: 0.36, frequency: constant(1_568), amplitude: decay(8))
        return r
    },
    Preset(name: "powerup", summary: "rising arpeggio", peak: 0.55) {
        let notes = [72, 76, 79, 84, 88, 91]
        let r = Renderer(duration: 0.05 * Double(notes.count) + 0.2)
        for (index, note) in notes.enumerated() {
            r.tone(.square, at: 0.05 * Double(index), duration: index == notes.count - 1 ? 0.25 : 0.05, frequency: constant(midiFrequency(note)), amplitude: index == notes.count - 1 ? decay(10) : constant(1))
        }
        return r
    },
    Preset(name: "boing", summary: "spring") {
        let r = Renderer(duration: 0.55)
        r.tone(.sine, duration: 0.55, frequency: { t in 200 * (1 + 0.8 * exp(-t * 12)) + 90 * sin(2 * .pi * 9 * t) * exp(-t * 3) }, amplitude: decay(5.5))
        r.tone(.triangle, duration: 0.55, frequency: { t in 400 * (1 + 0.8 * exp(-t * 12)) + 180 * sin(2 * .pi * 9 * t) * exp(-t * 3) }, amplitude: { t in 0.3 * exp(-t * 7) })
        return r
    },
    Preset(name: "boom", summary: "bass drop") {
        let r = Renderer(duration: 0.85)
        r.tone(.sine, duration: 0.85, frequency: glide(from: 110, to: 30, over: 0.6), amplitude: decay(4))
        r.tone(.noise, duration: 0.08, frequency: constant(0), amplitude: { t in 0.5 * exp(-t * 80) })
        r.distort(drive: 1.6)
        return r
    },
    Preset(name: "airhorn", summary: "air horn") {
        let r = Renderer(duration: 0.75)
        let fall: (Double) -> Double = { t in 1 - 0.04 * max(0, (t - 0.55) / 0.2) }
        for base in [220.0, 221.5, 330.0, 328.5, 440.0, 441.0] {
            r.tone(.saw, duration: 0.75, frequency: { t in base * fall(t) }, amplitude: gate(attack: 0.02, length: 0.75, release: 0.1))
        }
        r.distort(drive: 3)
        r.lowpass(cutoff: 2_500)
        return r
    },
    Preset(name: "fart", summary: "you know") {
        let r = Renderer(duration: 0.45)
        r.tone(.saw, duration: 0.45, frequency: { t in 80 - 35 * t + 10 * sin(2 * .pi * 21 * t) }, amplitude: { t in (0.55 + 0.45 * abs(sin(2 * .pi * 15 * t))) * exp(-t * 3) })
        r.tone(.noise, duration: 0.45, frequency: constant(0), amplitude: { t in 0.35 * exp(-t * 4) })
        r.lowpass(cutoff: 350)
        r.distort(drive: 2)
        return r
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
        return r
    },
    Preset(name: "robot", summary: "beep-boop", peak: 0.55) {
        let r = Renderer(duration: 0.24)
        r.tone(.square, duration: 0.09, frequency: constant(420), amplitude: gate(attack: 0.005, length: 0.09, release: 0.02))
        r.tone(.square, at: 0.11, duration: 0.12, frequency: constant(280), amplitude: gate(attack: 0.005, length: 0.12, release: 0.03))
        return r
    },
    Preset(name: "quack", summary: "duck") {
        let r = Renderer(duration: 0.16)
        r.tone(.saw, duration: 0.16, frequency: glide(from: 380, to: 260, over: 0.12), amplitude: { t in (0.5 + 0.5 * abs(sin(2 * .pi * 28 * t))) * max(0, min(1, t / 0.01, (0.16 - t) / 0.04)) })
        r.lowpass(cutoff: 1_800)
        r.distort(drive: 2)
        return r
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

func noteRenderer(_ note: Int) -> Renderer {
    let r = Renderer(duration: noteLength)
    renderNote(note, into: r)
    return r
}

func melodyRenderer(_ notes: [Int]) -> Renderer {
    let r = Renderer(duration: noteSpacing * Double(notes.count) + 0.1)
    for (index, note) in notes.enumerated() {
        renderNote(note, at: noteSpacing * Double(index), into: r)
    }
    return r
}

// MARK: - System sounds

let systemSoundsDirectory = "/System/Library/Sounds"

func systemSoundNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDirectory)) ?? []
    return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
}

/// Resolves a single sound name: a preset, a macOS system sound (case-insensitive), or a file path.
func loadBuffers(_ name: String) -> [AVAudioPCMBuffer]? {
    let key = name.lowercased()
    if let preset = presets.first(where: { $0.name == key }) {
        return preset.buffers()
    }
    if name.contains("/") {
        return fileBuffer((name as NSString).expandingTildeInPath).map { [$0] }
    }
    if let match = systemSoundNames().first(where: { $0.lowercased() == key }) {
        return fileBuffer("\(systemSoundsDirectory)/\(match).aiff").map { [$0] }
    }
    return nil
}

func fileBuffer(_ path: String) -> AVAudioPCMBuffer? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
    do { try file.read(into: buffer) } catch { return nil }
    return buffer
}

// MARK: - Mixer

/// One AVAudioEngine shared by every player. Scheduling a prepared buffer costs microseconds,
/// which matters because the key monitor must return before the next synthetic keystroke lands.
final class Mixer {
    static let shared = Mixer()
    static let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private var pools: [String: [AVAudioPlayerNode]] = [:]
    private var next: [String: Int] = [:]
    private var active = 0
    private let lock = NSLock()
    private(set) var failure: String?

    private func key(for format: AVAudioFormat) -> String {
        "\(format.sampleRate)/\(format.channelCount)/\(format.commonFormat.rawValue)/\(format.isInterleaved)"
    }

    /// Creates the player nodes for a format and starts the engine, so the first sound has no setup latency.
    func prepare(format: AVAudioFormat) {
        let poolKey = key(for: format)
        if pools[poolKey] != nil { return }
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<4 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        pools[poolKey] = nodes
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { failure = "audio engine failed to start: \(error.localizedDescription)" }
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        prepare(format: buffer.format)
        guard engine.isRunning else { return }
        let poolKey = key(for: buffer.format)
        let nodes = pools[poolKey]!
        let index = next[poolKey] ?? 0
        next[poolKey] = (index + 1) % nodes.count
        let node = nodes[index]
        node.stop()
        node.volume = volume
        lock.lock(); active += 1; lock.unlock()
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.active -= 1; self.lock.unlock()
        }
        node.play()
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return active > 0
    }
}

// MARK: - Player

/// Plays whatever `--sound` asks for on every event.
/// Specs: "none", a preset or system sound or file, "random", "random:a,b,c", "melody:NAME", "say:TEXT".
final class SoundPlayer: NSObject {
    private enum Mode {
        case silent
        case single(String, [AVAudioPCMBuffer])
        case random([(String, [AVAudioPCMBuffer])])
        case melody(String, [Int])
        case speech(String)
    }

    private let mode: Mode
    private let volume: Float
    private let stateDirectory: String?
    private var noteCache: [Int: AVAudioPCMBuffer] = [:]
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
            var choices: [(String, [AVAudioPCMBuffer])] = []
            for name in names {
                if let buffers = loadBuffers(name) { choices.append((name, buffers)) } else { problem = "unknown sound in random list: \(name)" }
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
        } else if let buffers = loadBuffers(spec) {
            mode = .single(spec, buffers)
        } else {
            problem = "unknown sound: \(spec)"
        }
        self.mode = mode
        self.problem = problem
        super.init()
        warmUp()
    }

    /// Prepares the mixer pools so the first event plays without engine start-up latency.
    private func warmUp() {
        switch mode {
        case let .single(_, buffers): for buffer in buffers { Mixer.shared.prepare(format: buffer.format) }
        case let .random(choices): for choice in choices { for buffer in choice.1 { Mixer.shared.prepare(format: buffer.format) } }
        case let .melody(_, notes):
            Mixer.shared.prepare(format: Mixer.monoFormat)
            for note in Set(notes) where note > 0 { noteCache[note] = noteRenderer(note).pcmBuffer(peak: 0.6) }
        case .silent, .speech: break
        }
        if let failure = Mixer.shared.failure, problem == nil { problem = failure }
    }

    var isSilent: Bool {
        if case .silent = mode { return true }
        return false
    }

    var isPlaying: Bool {
        if case .speech = mode { return synthesizer.isSpeaking }
        return Mixer.shared.isPlaying
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

    /// Plays the next thing and returns a short description for the log. Cheap enough to call
    /// from an event monitor: the work is one buffer schedule on the audio engine.
    @discardableResult
    func play() -> String {
        switch mode {
        case .silent:
            return "none"
        case let .single(name, buffers):
            Mixer.shared.play(buffers.randomElement()!, volume: volume)
            return name
        case let .random(choices):
            let choice = choices.randomElement()!
            Mixer.shared.play(choice.1.randomElement()!, volume: volume)
            return "random:\(choice.0)"
        case let .melody(name, notes):
            let position = loadPosition() % notes.count
            let note = notes[position]
            savePosition((position + 1) % notes.count)
            if note > 0 {
                let buffer = noteCache[note] ?? noteRenderer(note).pcmBuffer(peak: 0.6)
                noteCache[note] = buffer
                Mixer.shared.play(buffer, volume: volume)
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

    /// Renders the spec to WAV data for files. Speech and file-based sounds cannot be rendered.
    func previewData() -> Data? {
        switch mode {
        case .silent, .speech:
            return nil
        case let .single(name, _):
            return presets.first(where: { $0.name == name.lowercased() })?.wavData()
        case let .random(choices):
            let choice = choices.randomElement()!
            return presets.first(where: { $0.name == choice.0.lowercased() })?.wavData()
        case let .melody(_, notes):
            return melodyRenderer(notes).wavData(peak: 0.6)
        }
    }

    /// Plays the whole thing once and waits for it to finish, for `play` previews.
    func playPreview(timeout: Double = 12) -> String {
        var description = ""
        if case let .melody(name, notes) = mode {
            Mixer.shared.play(melodyRenderer(notes).pcmBuffer(peak: 0.6), volume: volume)
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
