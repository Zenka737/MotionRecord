import Foundation
import AVFoundation

/// Offline synthesizer for royalty-free background music and a scroll-wheel sound that fits any duration.
/// Everything is generated locally (no downloads, no licences).
enum MusicMood: String, CaseIterable, Identifiable {
    case calm, upbeat, dreamy, lofi, cinematic, tech
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: return "Спокойная"
        case .upbeat: return "Бодрая"
        case .dreamy: return "Мечтательная"
        case .lofi: return "Лоу-фай"
        case .cinematic: return "Кино"
        case .tech: return "Презентация"
        }
    }
    var icon: String {
        switch self {
        case .calm: return "leaf"
        case .upbeat: return "sun.max"
        case .dreamy: return "cloud"
        case .lofi: return "cup.and.saucer"
        case .cinematic: return "film"
        case .tech: return "bolt"
        }
    }
    var defaultTempo: Double {
        switch self { case .calm: return 72; case .upbeat: return 112; case .dreamy: return 78
                      case .lofi: return 82; case .cinematic: return 70; case .tech: return 122 }
    }

    /// (root midi note, intervals above root). One chord per bar.
    fileprivate var progression: [(Int, [Int])] {
        switch self {
        case .calm:      return [(48, [0, 4, 7, 11]), (45, [0, 3, 7, 10]), (53, [0, 4, 7, 11]), (43, [0, 4, 7, 10])]   // Cmaj7 Am7 Fmaj7 G7
        case .upbeat:    return [(55, [0, 4, 7]), (50, [0, 4, 7]), (52, [0, 3, 7]), (48, [0, 4, 7])]                    // G D Em C
        case .dreamy:    return [(53, [0, 4, 7, 11]), (57, [0, 3, 7, 10]), (50, [0, 3, 7, 10]), (55, [0, 5, 7, 10])]    // Fmaj7 Am7 Dm7 Gsus
        case .lofi:      return [(45, [0, 3, 7, 10]), (50, [0, 3, 7, 10]), (43, [0, 4, 7, 10]), (48, [0, 4, 7, 11])]    // Am7 Dm7 G7 Cmaj7
        case .cinematic: return [(50, [0, 3, 7]), (46, [0, 4, 7]), (53, [0, 4, 7]), (48, [0, 4, 7])]                    // Dm Bb F C
        case .tech:      return [(52, [0, 3, 7]), (48, [0, 4, 7]), (55, [0, 4, 7]), (50, [0, 4, 7])]                    // Em C G D
        }
    }
    fileprivate var barsPerChord: Int { self == .cinematic || self == .calm ? 2 : 1 }
    fileprivate var drums: Bool { self == .upbeat || self == .lofi || self == .tech }
    fileprivate var arp: Bool { self != .cinematic }
    fileprivate var bassPulse: Bool { self == .tech || self == .upbeat }
    fileprivate var swing: Double { self == .lofi ? 0.16 : 0 }
    fileprivate var padGain: Float { self == .cinematic ? 0.55 : (self == .tech ? 0.28 : 0.4) }
}

enum KeyboardStyle: String, CaseIterable, Identifiable {
    case soft, mechanical, typewriter, bubble, paper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .soft: return "Мягкая"
        case .mechanical: return "Механическая"
        case .typewriter: return "Печатная машинка"
        case .bubble: return "Пузырьки"
        case .paper: return "Тихая"
        }
    }
}

enum MusicGenerator {
    static let sampleRate = 44100.0

    static var outputDirectory: URL {
        let d = RecordingSession.libraryURL.appendingPathComponent("Generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Public

    /// Generates a stereo 16-bit WAV of `duration` seconds and returns its URL.
    static func generateMusic(mood: MusicMood, tempo: Double, duration: Double, seed: UInt64) throws -> URL {
        let dur = min(max(duration, 4), 600)
        var rng = SplitMix(seed: seed)
        let n = Int(dur * sampleRate)
        var L = [Float](repeating: 0, count: n), R = L
        let beat = 60.0 / tempo
        let bar = beat * 4
        let prog = mood.progression
        let chordLen = bar * Double(mood.barsPerChord)
        var t = 0.0, ci = 0
        while t < dur {
            let (root, ints) = prog[ci % prog.count]
            let notes = ints.map { root + $0 }
            // pad (soft, slowly detuned)
            for (k, m) in notes.enumerated() {
                let f = midi(m + 12)
                let pan = Float(k % 2 == 0 ? -0.3 : 0.3)
                add(&L, &R, voice: .pad, freq: f, start: t, dur: chordLen + 0.6, gain: mood.padGain * 0.22, pan: pan)
            }
            // bass
            let bassF = midi(root - 12)
            if mood.bassPulse {
                var b = 0.0
                while b < chordLen - 0.01 {
                    add(&L, &R, voice: .bass, freq: bassF, start: t + b, dur: beat * 0.45, gain: 0.34, pan: 0)
                    b += beat / 2
                }
            } else {
                add(&L, &R, voice: .bass, freq: bassF, start: t, dur: chordLen, gain: 0.3, pan: 0)
            }
            // arpeggio
            if mood.arp {
                let steps = Int(chordLen / (beat / 2))
                let tones = notes + notes.map { $0 + 12 } + [notes[0] + 24]
                var idx = 0
                for s in 0..<steps {
                    let swung = (s % 2 == 1) ? mood.swing * beat : 0
                    if rng.nextDouble() < 0.82 {
                        let pat = [0, 1, 2, 3, 2, 1, 4, 2]
                        idx = pat[s % pat.count] % tones.count
                        let accent: Float = s % 4 == 0 ? 1.0 : 0.72
                        add(&L, &R, voice: .pluck, freq: midi(tones[idx] + 12), start: t + Double(s) * beat / 2 + swung,
                            dur: beat * 1.3, gain: 0.2 * accent, pan: Float(rng.nextDouble() * 0.8 - 0.4))
                    }
                }
            }
            // drums
            if mood.drums {
                var b = 0.0
                var step = 0
                while b < chordLen - 0.01 {
                    let tt = t + b
                    if step % 4 == 0 { add(&L, &R, voice: .kick, freq: 55, start: tt, dur: 0.35, gain: mood == .lofi ? 0.42 : 0.5, pan: 0) }
                    if step % 8 == 4 { add(&L, &R, voice: .snare, freq: 190, start: tt, dur: 0.25, gain: 0.22, pan: 0.05) }
                    let swung = (step % 2 == 1) ? mood.swing * beat / 2 : 0
                    add(&L, &R, voice: .hat, freq: 8000, start: tt + swung, dur: 0.06, gain: step % 2 == 0 ? 0.07 : 0.045, pan: 0.2)
                    step += 1
                    b += beat / 2
                }
            }
            t += chordLen
            ci += 1
        }
        reverb(&L, &R, mix: mood == .cinematic || mood == .dreamy ? 0.32 : 0.2)
        fades(&L, &R, fadeIn: 0.8, fadeOut: min(3.0, dur * 0.25))
        return try writeWAV(L, R, name: "Музыка-\(mood.title)-\(Int(tempo))bpm")
    }

    /// Scroll-wheel ticks that speed up and slow down, stretched to fit exactly `duration` seconds.
    static func generateWheel(duration: Double, maxRate: Double, soft: Bool, seed: UInt64) throws -> URL {
        let dur = min(max(duration, 0.3), 60)
        var rng = SplitMix(seed: seed)
        let n = Int(dur * sampleRate)
        var L = [Float](repeating: 0, count: n), R = L
        var t = 0.0
        while t < dur {
            let x = t / dur
            let curve = Float(sin(Double.pi * x))
            let rate = 4 + (maxRate - 4) * Double(curve)
            let f = (soft ? 1250.0 : 1800.0) + rng.nextDouble() * 360 - 180
            add(&L, &R, voice: .wheel, freq: f, start: t, dur: 0.05, gain: 0.35 + 0.65 * curve, pan: Float(rng.nextDouble() * 0.2 - 0.1))
            t += 1.0 / rate
        }
        fades(&L, &R, fadeIn: 0.01, fadeOut: 0.05)
        return try writeWAV(L, R, name: "Колёсико-\(String(format: "%.1f", dur))с")
    }

    /// Deterministic file for the typing sound of a text overlay (so it's regenerated only when its parameters change).
    static func typingURL(textID: UUID, text: String, speed: Double, lead: Double) -> URL {
        var h: UInt64 = 5381
        for u in "\(text)|\(Int(speed * 10))|\(Int(lead * 100))".utf8 { h = h &* 33 &+ UInt64(u) }
        return outputDirectory.appendingPathComponent("typing-\(textID.uuidString)-\(String(h, radix: 16)).wav")
    }

    /// Keyboard typing sound: one soft key click per visible character, synchronized with the typewriter animation.
    static func generateTyping(text: String, speed: Double, lead: Double, to url: URL) throws {
        let chars = Array(text)
        let dur = lead + Double(chars.count) / max(speed, 1) + 0.4
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: text.hashValue))
        let n = Int(dur * sampleRate)
        var L = [Float](repeating: 0, count: n), R = L
        for (i, ch) in chars.enumerated() {
            if ch == "\n" { continue }
            let t = lead + Double(i) / speed + (rng.nextDouble() - 0.5) * 0.012
            let space = ch == " "
            add(&L, &R, voice: .wheel, freq: space ? 760 : 1250 + rng.nextDouble() * 500, start: t, dur: 0.07,
                gain: space ? 0.55 : 0.4 + Float(rng.nextDouble()) * 0.2, pan: Float(rng.nextDouble() * 0.2 - 0.1))
            add(&L, &R, voice: .bass, freq: space ? 120 : 170, start: t, dur: 0.05, gain: 0.12, pan: 0)
        }
        var peak: Float = 0.001
        for i in 0..<n { peak = max(peak, abs(L[i]), abs(R[i])) }
        for i in 0..<n { L[i] *= 0.8 / peak; R[i] *= 0.8 / peak }
        try writeWAV(L, R, to: url)
    }

    // MARK: Keyboard sounds

    static func keyboardURL(style: KeyboardStyle, times: [(Double, Int)], duration: Double) -> URL {
        var h: UInt64 = 5381
        for (t, k) in times { h = h &* 33 &+ UInt64(Int(t * 1000)) &* 7 &+ UInt64(k) }
        h = h &* 33 &+ UInt64(duration * 100)
        return outputDirectory.appendingPathComponent("keyboard-\(style.rawValue)-\(String(h, radix: 16)).wav")
    }

    /// Renders one key-press sound (letter, space, return, delete) of a keyboard style at `t`.
    private static func key(_ L: inout [Float], _ R: inout [Float], style: KeyboardStyle, kind: Int, t: Double, rng: inout SplitMix) {
        let pan = Float(rng.nextDouble() * 0.24 - 0.12)
        let v = Float(0.85 + rng.nextDouble() * 0.3)
        let j = rng.nextDouble()
        switch style {
        case .soft:
            let f = kind == 1 ? 780.0 : (kind == 2 ? 640.0 : 1200 + j * 300)
            add(&L, &R, voice: .wheel, freq: f, start: t, dur: 0.07, gain: (kind == 1 ? 0.5 : 0.4) * v, pan: pan)
            add(&L, &R, voice: .bass, freq: kind == 1 ? 110 : 160, start: t, dur: 0.05, gain: 0.12 * v, pan: 0)
        case .mechanical:
            let f = kind == 1 ? 1500.0 : 2300 + j * 450
            add(&L, &R, voice: .wheel, freq: f, start: t, dur: 0.06, gain: 0.5 * v, pan: pan)
            add(&L, &R, voice: .wheel, freq: f * 0.62, start: t + 0.055 + j * 0.01, dur: 0.05, gain: 0.22 * v, pan: pan)   // release click
            add(&L, &R, voice: .bass, freq: kind == 1 ? 95 : 140, start: t, dur: 0.06, gain: 0.2 * v, pan: 0)
        case .typewriter:
            add(&L, &R, voice: .wheel, freq: 900 + j * 200, start: t, dur: 0.08, gain: 0.6 * v, pan: pan)
            add(&L, &R, voice: .bass, freq: 85, start: t, dur: 0.09, gain: 0.3 * v, pan: 0)
            if kind == 2 { add(&L, &R, voice: .pluck, freq: 2349, start: t + 0.02, dur: 0.9, gain: 0.12, pan: 0.05) }  // carriage bell
        case .bubble:
            let f = 520 + j * 380 + (kind == 1 ? -150 : 0)
            add(&L, &R, voice: .pluck, freq: f, start: t, dur: 0.18, gain: 0.34 * v, pan: pan)
            add(&L, &R, voice: .wheel, freq: 1800, start: t, dur: 0.03, gain: 0.12 * v, pan: pan)
        case .paper:
            add(&L, &R, voice: .wheel, freq: 650 + j * 150, start: t, dur: 0.06, gain: 0.24 * v, pan: pan)
            add(&L, &R, voice: .bass, freq: 120, start: t, dur: 0.04, gain: 0.08 * v, pan: 0)
        }
        if kind == 3 { add(&L, &R, voice: .wheel, freq: 2600, start: t + 0.012, dur: 0.03, gain: 0.1, pan: pan) }
    }

    /// One audio track for ALL recorded key presses (times already in OUTPUT time), `duration` seconds long.
    static func generateKeyboard(style: KeyboardStyle, times: [(Double, Int)], duration: Double, to url: URL) throws {
        var rng = SplitMix(seed: 0xC0FFEE)
        let n = max(Int(duration * sampleRate), Int(sampleRate))
        var L = [Float](repeating: 0, count: n), R = L
        for (t, kind) in times where t >= 0 && t < duration { key(&L, &R, style: style, kind: kind, t: t, rng: &rng) }
        var peak: Float = 0.001
        for i in 0..<n { peak = max(peak, abs(L[i]), abs(R[i])) }
        let g = min(0.85 / peak, 3)      // keep a consistent loudness, don't over-boost very sparse typing
        for i in 0..<n { L[i] *= g; R[i] *= g }
        try writeWAV(L, R, to: url)
    }

    /// Short typing demo so the user can audition a style.
    static func keyboardDemo(style: KeyboardStyle) throws -> URL {
        let url = outputDirectory.appendingPathComponent("keyboard-demo-\(style.rawValue).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var times: [(Double, Int)] = []
        var t = 0.1
        var rng = SplitMix(seed: 42)
        let kinds = [0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 3, 0, 0, 1, 0, 0, 0, 2]
        for k in kinds { times.append((t, k)); t += 0.07 + rng.nextDouble() * 0.12 }
        try generateKeyboard(style: style, times: times, duration: t + 0.5, to: url)
        return url
    }

    // MARK: Synthesis

    private enum Voice { case pad, pluck, bass, kick, snare, hat, wheel }

    private static func midi(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

    private static func add(_ L: inout [Float], _ R: inout [Float], voice: Voice, freq: Double,
                            start: Double, dur: Double, gain: Float, pan: Float) {
        let s0 = Int(start * sampleRate)
        guard s0 < L.count else { return }
        let len = min(Int(dur * sampleRate), L.count - s0)
        guard len > 0 else { return }
        let lg = gain * (pan <= 0 ? 1 : 1 - pan * 0.7), rg = gain * (pan >= 0 ? 1 : 1 + pan * 0.7)
        var phase = 0.0, phase2 = 0.0
        var lp: Float = 0
        var seed = UInt32(truncatingIfNeeded: s0 &* 2654435761 &+ Int(freq))
        for i in 0..<len {
            let tt = Double(i) / sampleRate
            let x = Double(i) / Double(len)
            var v: Float
            switch voice {
            case .pad:
                let a = Float(min(1, tt / 0.45)) * Float(min(1, (dur - tt) / 0.6))
                phase += 2 * .pi * freq / sampleRate; phase2 += 2 * .pi * freq * 1.004 / sampleRate
                v = a * (Float(sin(phase)) * 0.6 + Float(sin(phase2)) * 0.4 + 0.15 * Float(sin(phase * 2)) + 0.05 * Float(sin(phase2 * 3)))
            case .pluck:
                let e = Float(exp(-tt * 3.4)) * Float(min(1, tt / 0.004))
                phase += 2 * .pi * freq / sampleRate
                v = e * (Float(sin(phase)) + 0.35 * Float(sin(phase * 2)) * Float(exp(-tt * 6)) + 0.12 * Float(sin(phase * 3)) * Float(exp(-tt * 9)))
            case .bass:
                let e = Float(min(1, tt / 0.01)) * Float(min(1, max(0, (dur - tt) / 0.08)))
                phase += 2 * .pi * freq / sampleRate
                v = e * (Float(sin(phase)) + 0.25 * Float(sin(phase * 2))) * (voice == .bass && dur < 1 ? Float(exp(-tt * 3)) : 1)
            case .kick:
                let f = 40 + 90 * exp(-tt * 28)
                phase += 2 * .pi * f / sampleRate
                v = Float(sin(phase)) * Float(exp(-tt * 9))
            case .snare:
                seed = seed &* 1664525 &+ 1013904223
                let nz = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                lp += 0.5 * (nz - lp)
                phase += 2 * .pi * freq / sampleRate
                v = (lp * 0.8 + Float(sin(phase)) * 0.3) * Float(exp(-tt * 20))
            case .hat:
                seed = seed &* 1664525 &+ 1013904223
                let nz = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                v = (nz - lp); lp = nz
                v *= Float(exp(-tt * 70))
            case .wheel:
                seed = seed &* 1664525 &+ 1013904223
                let nz = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                lp += 0.35 * (nz - lp)
                phase += 2 * .pi * freq / sampleRate
                v = (Float(sin(phase)) * 0.8 + lp * 0.5) * Float(exp(-tt * 190)) * Float(min(1, tt / 0.0004))
            }
            _ = x
            L[s0 + i] += v * lg
            R[s0 + i] += v * rg
        }
    }

    /// Small Schroeder-style reverb (parallel combs + two allpasses) for lush ambience.
    private static func reverb(_ L: inout [Float], _ R: inout [Float], mix: Float) {
        let combs = [1687, 1931, 2203, 2503]
        func process(_ x: [Float], offset: Int) -> [Float] {
            var out = [Float](repeating: 0, count: x.count)
            for d in combs {
                let dl = d + offset
                var buf = [Float](repeating: 0, count: dl)
                var idx = 0
                for i in 0..<x.count {
                    let y = buf[idx]
                    out[i] += y * 0.25
                    buf[idx] = x[i] + y * 0.82
                    idx += 1; if idx == dl { idx = 0 }
                }
            }
            for d in [225 + offset, 556 + offset] {
                var buf = [Float](repeating: 0, count: d)
                var idx = 0
                for i in 0..<out.count {
                    let b = buf[idx]
                    let y = -out[i] + b
                    buf[idx] = out[i] + b * 0.5
                    out[i] = y
                    idx += 1; if idx == d { idx = 0 }
                }
            }
            return out
        }
        let wl = process(L, offset: 0), wr = process(R, offset: 23)
        for i in 0..<L.count { L[i] += wl[i] * mix; R[i] += wr[i] * mix }
    }

    private static func fades(_ L: inout [Float], _ R: inout [Float], fadeIn: Double, fadeOut: Double) {
        let n = L.count
        let fi = max(1, Int(fadeIn * sampleRate)), fo = max(1, Int(fadeOut * sampleRate))
        for i in 0..<min(fi, n) { let k = Float(i) / Float(fi); L[i] *= k; R[i] *= k }
        for i in 0..<min(fo, n) { let k = Float(i) / Float(fo); L[n - 1 - i] *= k; R[n - 1 - i] *= k }
        var peak: Float = 0.001
        for i in 0..<n { peak = max(peak, abs(L[i]), abs(R[i])) }
        let g = 0.85 / peak
        for i in 0..<n { L[i] *= g; R[i] *= g }
    }

    private static func writeWAV(_ L: [Float], _ R: [Float], name: String) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let url = outputDirectory.appendingPathComponent("\(name)-\(stamp).wav")
        try writeWAV(L, R, to: url)
        return url
    }

    private static func writeWAV(_ L: [Float], _ R: [Float], to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(L.count)) else {
            throw NSError(domain: "MusicGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не хватило памяти для звука"])
        }
        buf.frameLength = AVAudioFrameCount(L.count)
        L.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: L.count) }
        R.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: R.count) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buf)
    }
}

private struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - UI

import SwiftUI

struct KeyboardSoundCard: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject private var previewer = SoundPreviewer.shared

    var body: some View {
        let count = editor.session.meta.keys.count
        let kb = editor.project.keyboard
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Звуки клавиатуры")
            if count == 0 {
                Text("В этом видео нет записанных нажатий клавиш. При записи включите «Записывать нажатия клавиш» и разрешите «Мониторинг ввода» — тогда звук клавиатуры подставится сам. Для текста со своим печатанием используйте вкладку «Текст».")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            } else {
                Text("Найдено нажатий клавиш: \(count). Буквы самой записи не сохраняются — только моменты нажатий.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            }
            Toggle("Добавить звук набора на клавиатуре", isOn: Binding(get: { kb.enabled }, set: { v in editor.edit { $0.keyboard.enabled = v } }))
                .toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12.5)).disabled(count == 0)
            ForEach(KeyboardStyle.allCases) { st in
                HStack(spacing: 8) {
                    Button { play(st) } label: {
                        Image(systemName: previewer.playing?.contains("keyboard-demo-\(st.rawValue)") == true ? "stop.fill" : "play.fill").font(.system(size: 10))
                            .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
                    }.buttonStyle(.plain).help("Прослушать")
                    Text(st.title).font(.system(size: 12.5))
                    Spacer()
                    Image(systemName: kb.style == st.rawValue ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(kb.style == st.rawValue ? Theme.accent : Theme.textDim)
                }
                .contentShape(Rectangle())
                .onTapGesture { editor.edit { $0.keyboard.style = st.rawValue } }
            }
            SliderRow(title: "Громкость", value: Binding(get: { kb.volume * 100 }, set: { v in editor.edit(coalesce: "kbvol") { $0.keyboard.volume = v / 100 } }),
                      range: 0...200, format: "%.0f%%")
        }.card()
    }

    private func play(_ st: KeyboardStyle) {
        if let u = try? MusicGenerator.keyboardDemo(style: st) { previewer.toggle(u) }
    }
}

struct GeneratorCards: View {
    @ObservedObject var editor: EditorModel
    @State private var mood: MusicMood = .calm
    @State private var tempo: Double = MusicMood.calm.defaultTempo
    @State private var fitVideo = true
    @State private var length: Double = 30
    @State private var busy = false
    @State private var wheelRate: Double = 26
    @State private var wheelSoft = true
    @State private var wheelFit = true
    @State private var wheelLen: Double = 1.5
    @ObservedObject private var previewer = SoundPreviewer.shared
    @State private var last: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Генератор музыки")
            Text("Выберите настроение — музыка создаётся сама и подгоняется под длину видео.")
                .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(MusicMood.allCases) { m in
                    Button { mood = m; tempo = m.defaultTempo } label: {
                        VStack(spacing: 4) {
                            Image(systemName: m.icon).font(.system(size: 15))
                            Text(m.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(mood == m ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(mood == m ? Theme.accent : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }
            SliderRow(title: "Темп", value: $tempo, range: 55...140, format: "%.0f уд/мин")
            HStack {
                Text("Длина по видео").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $fitVideo).labelsHidden().toggleStyle(.switch)
            }
            if !fitVideo { SliderRow(title: "Длина", value: $length, range: 10...180, format: "%.0f с") }
            Button { generateMusic() } label: {
                Label(busy ? "Создаю…" : "Создать музыку", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
        }.card()

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Колёсико мыши")
            Text("Приятные щелчки прокрутки: разгоняются и затихают, длина подстраивается под выбранный кусок.")
                .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
            HStack {
                Text("Подогнать под 3 секунды у плейхеда").font(.system(size: 12)).lineLimit(1)
                Spacer()
                Toggle("", isOn: $wheelFit).labelsHidden().toggleStyle(.switch)
            }
            if !wheelFit { SliderRow(title: "Длина", value: $wheelLen, range: 0.4...10, format: "%.1f с") }
            SliderRow(title: "Скорость", value: $wheelRate, range: 10...50, format: "%.0f/с")
            HStack {
                Text("Мягкий звук").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $wheelSoft).labelsHidden().toggleStyle(.switch)
            }
            Button { generateWheel() } label: {
                Label("Создать и поставить", systemImage: "computermouse").frame(maxWidth: .infinity)
            }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
            if let last {
                HStack {
                    Button { previewer.toggle(last) } label: {
                        Label(previewer.playing == last.path ? "Стоп" : "Прослушать последнее", systemImage: previewer.playing == last.path ? "stop.fill" : "play.fill")
                    }.buttonStyle(SecondaryButtonStyle())
                    Button { NSWorkspace.shared.activateFileViewerSelecting([last]) } label: { Image(systemName: "folder") }
                        .buttonStyle(SecondaryButtonStyle()).help("Показать файл")
                }
            }
        }.card()
    }

    private func generateMusic() {
        busy = true
        let m = mood, tp = tempo
        let dur = fitVideo ? max(editor.outputDuration, 5) : length
        let seed = UInt64.random(in: 0...UInt64.max)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MusicGenerator.generateMusic(mood: m, tempo: tp, duration: dur, seed: seed) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let url):
                    last = url
                    editor.addAudio(url: url, isMusic: true, at: 0, name: "Музыка · \(m.title)")
                case .failure(let e): editor.onError?("Не удалось создать музыку: \(e.localizedDescription)")
                }
            }
        }
    }

    private func generateWheel() {
        busy = true
        let dur = wheelFit ? min(3, max(editor.outputDuration - editor.playhead, 0.4)) : wheelLen
        let rate = wheelRate, soft = wheelSoft
        let at = editor.playhead
        let seed = UInt64.random(in: 0...UInt64.max)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MusicGenerator.generateWheel(duration: dur, maxRate: rate, soft: soft, seed: seed) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let url):
                    last = url
                    editor.addAudio(url: url, isMusic: false, at: at, name: "Колёсико")
                case .failure(let e): editor.onError?("Не удалось создать звук: \(e.localizedDescription)")
                }
            }
        }
    }
}
