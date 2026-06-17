import AVFoundation

/// Synthesised UI chimes for start / stop recording. We generate the tones in-engine
/// (soft sine + a touch of harmonics, with a quick attack and exponential decay) rather
/// than using the dated built-in system sounds, so the cues feel as polished as the rest
/// of the app. Tones are short and play before/after capture, so they don't bleed into
/// the recorded audio.
@MainActor
final class AppSounds {
    static let shared = AppSounds()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var startBuffer: AVAudioPCMBuffer?
    private var stopBuffer:  AVAudioPCMBuffer?
    private var tickBuffer:  AVAudioPCMBuffer?
    private var running = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Rising perfect-fourth (A5 → D6): a bright, optimistic "go".
        startBuffer = makeChime(notes: [(880.00, 0.00), (1174.66, 0.085)])
        // Falling (E6 → A5): a gentle, settled "done".
        stopBuffer  = makeChime(notes: [(1318.51, 0.00), (880.00, 0.095)])
        // A single soft, short blip for each countdown beat (A5) — quieter than the chimes
        // so 3-2-1 feels like a gentle pulse that resolves into the brighter "go".
        tickBuffer  = makeTick(freq: 880.00)
    }

    func playStart() { play(startBuffer) }
    func playStop()  { play(stopBuffer) }
    func playTick()  { play(tickBuffer) }

    // MARK: - Private

    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        ensureRunning()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func ensureRunning() {
        guard !running else { return }
        do { try engine.start(); running = true } catch { running = false }
    }

    /// Builds a short two-note chime. Each note is a sine with a soft 2nd/3rd harmonic and an
    /// 8 ms attack into an exponential decay — a clean, bell-like tone with no harsh click.
    private func makeChime(notes: [(freq: Double, start: Double)]) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = 0.45                       // overall buffer length (s)
        let noteDur = 0.30                      // per-note ring-out (s)
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let ch = buf.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frames) { ch[i] = 0 }

        for note in notes {
            let startFrame = Int(note.start * sr)
            let count = Int(noteDur * sr)
            for i in 0..<count {
                let idx = startFrame + i
                if idx >= Int(frames) { break }
                let t = Double(i) / sr
                let attack = min(1.0, t / 0.008)          // 8 ms fade-in (no click)
                let env = attack * exp(-t * 7.5)          // smooth exponential decay
                let w = 2.0 * Double.pi * note.freq * t
                let sample = (sin(w) * 0.80
                              + sin(2 * w) * 0.14
                              + sin(3 * w) * 0.05) * env
                ch[idx] += Float(sample * 0.22)           // headroom; two notes overlap briefly
            }
        }
        return buf
    }

    /// A short, soft single-note blip for countdown beats: 6 ms attack, fast decay (~0.16 s),
    /// lower level than the chimes so the 3-2-1 stays gentle.
    private func makeTick(freq: Double) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = 0.20
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let ch = buf.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let attack = min(1.0, t / 0.006)
            let env = attack * exp(-t * 22.0)
            let w = 2.0 * Double.pi * freq * t
            let sample = (sin(w) * 0.85 + sin(2 * w) * 0.12) * env
            ch[i] = Float(sample * 0.16)
        }
        return buf
    }
}
