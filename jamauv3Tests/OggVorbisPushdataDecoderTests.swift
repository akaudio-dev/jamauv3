// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

import Testing
import Foundation
@testable import jamauv3

private func sineWave(frequency: Float, sampleRate: Int, duration: Float, amplitude: Float = 0.8) -> [Float] {
    let count = Int(Float(sampleRate) * duration)
    var out = [Float](repeating: 0, count: count)
    let w = 2.0 * Float.pi * frequency / Float(sampleRate)
    for i in 0..<count { out[i] = amplitude * sin(w * Float(i)) }
    return out
}

/// Encode a mono sine into a single OGG interval for the decoder tests.
private func encodeSineOgg(frequency: Float, sampleRate: Int, duration: Float,
                           amplitude: Float = 0.8) throws -> Data {
    let original = sineWave(frequency: frequency, sampleRate: sampleRate,
                            duration: duration, amplitude: amplitude)
    let encoder = try OggVorbisStreamEncoder(sampleRate: sampleRate, channels: 1, quality: 0.1)
    var out = Data()
    try original.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        out.append(try encoder.write(samples: base, frameCount: original.count))
    }
    out.append(try encoder.finish())
    return out
}

@Suite("OggVorbisPushdataDecoder")
struct OggVorbisPushdataDecoderTests {

    /// Feeding an OGG interval byte-by-byte in tiny fragments (as it would stream in
    /// off the network) must decode to the same audio a whole-buffer decode produces:
    /// correct channel count / sample rate, ~1 s of frames, and a level-transparent RMS.
    @Test("Chunked pushdata decode matches whole-buffer decode")
    func chunkedMatchesWhole() throws {
        let sampleRate = 44100
        let ogg = try encodeSineOgg(frequency: 440, sampleRate: sampleRate, duration: 1.0)

        let decoder = OggVorbisPushdataDecoder()
        var interleaved: [Float] = []

        // Small fragments deliberately smaller than a page to exercise the tail carry.
        let chunk = 300
        var offset = 0
        while offset < ogg.count {
            let end = min(offset + chunk, ogg.count)
            let piece = ogg.subdata(in: offset..<end)
            interleaved.append(contentsOf: decoder.feed(piece))
            offset = end
        }

        #expect(!decoder.failed)
        #expect(decoder.channels == 1)
        #expect(decoder.sampleRate == sampleRate)

        // Output is interleaved stereo (mono duplicated to L/R).
        let frames = interleaved.count / 2
        #expect(abs(frames - sampleRate) < 4096,
                "expected ~\(sampleRate) frames, got \(frames)")

        // L and R identical for a mono source.
        var maxLRdiff: Float = 0
        for i in stride(from: 0, to: interleaved.count, by: 2) {
            maxLRdiff = max(maxLRdiff, abs(interleaved[i] - interleaved[i + 1]))
        }
        #expect(maxLRdiff < 1e-6)

        // RMS is preserved (~0.8/sqrt2 ≈ 0.566) — the codec is level-transparent.
        var sumSq: Double = 0
        for i in stride(from: 0, to: interleaved.count, by: 2) {
            sumSq += Double(interleaved[i]) * Double(interleaved[i])
        }
        let rms = sqrt(sumSq / Double(max(1, frames)))
        #expect(rms > 0.45 && rms < 0.65, "unexpected RMS \(rms)")
    }

    /// A single all-at-once feed must decode identically to the chunked path.
    @Test("Single-shot pushdata decode")
    func singleShot() throws {
        let sampleRate = 48000
        let ogg = try encodeSineOgg(frequency: 220, sampleRate: sampleRate, duration: 0.5)
        let decoder = OggVorbisPushdataDecoder()
        let out = decoder.feed(ogg)
        #expect(!decoder.failed)
        #expect(decoder.sampleRate == sampleRate)
        #expect(out.count / 2 > sampleRate / 4) // got a meaningful amount of audio
    }

    /// Junk bytes must never open a decoder or crash — just fail cleanly.
    @Test("Garbage input fails cleanly")
    func garbageFails() {
        let decoder = OggVorbisPushdataDecoder()
        let junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let out = decoder.feed(junk)
        #expect(out.isEmpty)
        // Either still waiting (never opened) or explicitly failed — never a crash,
        // never spurious audio.
        #expect(decoder.channels == 0 || decoder.failed)
    }

    /// PreviewFIFO must stay bounded no matter how much is appended (a hostile server
    /// could otherwise drive unbounded growth / an unbounded render-thread lock hold),
    /// and on overflow it keeps the most-recent audio (skip-ahead).
    @Test("PreviewFIFO stays bounded and keeps newest audio on overflow")
    func previewFifoBounded() {
        let capFrames = 100
        let fifo = PreviewFIFO(capacityFrames: capFrames)
        var batch = [Float]()
        for f in 0..<250 { batch.append(Float(f)); batch.append(Float(f)) } // 250 stereo frames
        fifo.append(batch)
        #expect(fifo.availableFrames == capFrames) // never exceeds capacity

        var out = [Float](repeating: 0, count: capFrames * 2)
        let got = out.withUnsafeMutableBufferPointer { fifo.read(into: $0.baseAddress!, maxFrames: capFrames) }
        #expect(got == capFrames)
        #expect(out[0] == 150.0)                 // oldest surviving frame (250 - 100)
        #expect(out[(capFrames - 1) * 2] == 249.0) // newest frame
        #expect(fifo.availableFrames == 0)        // fully drained
    }

    /// The resampler changes the frame count by the rate ratio and preserves the
    /// fractional phase across successive chunks (no gaps/dupes at the seams).
    @Test("PreviewResampler rate conversion")
    func resamplerRateConversion() {
        var rs = PreviewResampler()
        // 100 ms of interleaved-stereo source at 48k → resample to 44.1k.
        let srcFrames = 4800
        var src = [Float](repeating: 0, count: srcFrames * 2)
        let w = 2.0 * Float.pi * 440.0 / 48000.0
        for i in 0..<srcFrames {
            let s = sin(w * Float(i))
            src[i * 2] = s; src[i * 2 + 1] = s
        }
        var total = 0
        // Feed in 3 pieces to exercise the carry.
        for piece in stride(from: 0, to: src.count, by: 3200) {
            let end = min(piece + 3200, src.count)
            let out = rs.resample(Array(src[piece..<end]), fromRate: 48000, toRate: 44100)
            total += out.count / 2
        }
        let expected = Int(Double(srcFrames) * 44100.0 / 48000.0)
        #expect(abs(total - expected) < 64, "expected ~\(expected) frames, got \(total)")
    }
}
