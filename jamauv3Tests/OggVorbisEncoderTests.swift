// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  OggVorbisEncoderTests.swift
//  jamauv3Tests
//
//  Tests for OGG Vorbis audio encoding.
//

import Testing
import Foundation
@testable import jamauv3

// MARK: - Test Helpers

private func sineWave(frequency: Float, sampleRate: Int, duration: Float, amplitude: Float = 0.8) -> [Float] {
    let count = Int(Float(sampleRate) * duration)
    return (0..<count).map { i in
        amplitude * sin(2.0 * .pi * frequency * Float(i) / Float(sampleRate))
    }
}

private func stereoSineWave(freqL: Float, freqR: Float, sampleRate: Int, duration: Float, amplitude: Float = 0.8) -> [Float] {
    let frameCount = Int(Float(sampleRate) * duration)
    var samples = [Float](repeating: 0, count: frameCount * 2)
    for i in 0..<frameCount {
        samples[i * 2]     = amplitude * sin(2.0 * .pi * freqL * Float(i) / Float(sampleRate))
        samples[i * 2 + 1] = amplitude * sin(2.0 * .pi * freqR * Float(i) / Float(sampleRate))
    }
    return samples
}

private func rmse(_ a: [Float], _ b: [Float]) -> Float {
    let count = min(a.count, b.count)
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<count {
        let diff = a[i] - b[i]
        sum += diff * diff
    }
    return sqrt(sum / Float(count))
}

// MARK: - Encoder Tests

@Suite("OGG Vorbis Encoder")
struct OggVorbisEncoderTests {

    @Test("Encode silence and verify OGG header")
    func encodeSilence() throws {
        let silence = [Float](repeating: 0, count: 44100)  // 1s mono silence
        let encoded = try OggVorbisEncoder.encode(
            samples: silence, sampleRate: 44100, channels: 1
        )

        // Verify OggS capture pattern
        #expect(encoded.count >= 4)
        let header = String(data: encoded.prefix(4), encoding: .ascii)
        #expect(header == "OggS")

        // Decode back and verify silence
        let decoded = try OggVorbisDecoder.decode(data: encoded)
        #expect(decoded.format.channels == 1)
        #expect(decoded.format.sampleRate == 44100)

        // All decoded samples should be near zero
        let maxAbs = decoded.samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs < 0.01, "Decoded silence should be near zero, got max \(maxAbs)")
    }

    @Test("Round-trip sine wave encode/decode")
    func roundTripSineWave() throws {
        let sampleRate = 44100
        let original = sineWave(frequency: 440, sampleRate: sampleRate, duration: 2.0)

        let encoded = try OggVorbisEncoder.encode(
            samples: original, sampleRate: sampleRate, channels: 1, quality: 0.4
        )
        let decoded = try OggVorbisDecoder.decode(data: encoded)

        #expect(decoded.format.channels == 1)
        #expect(decoded.format.sampleRate == sampleRate)

        // Compare middle section (skip encoder delay at start/end)
        let skip = 2048
        let length = min(original.count, decoded.samples.count) - skip * 2
        #expect(length > 0, "Decoded signal too short")

        let origSlice = Array(original[skip..<(skip + length)])
        let decSlice = Array(decoded.samples[skip..<(skip + length)])
        let error = rmse(origSlice, decSlice)

        #expect(error < 0.05, "RMSE \(error) exceeds threshold 0.05")
    }

    @Test("Stereo encode/decode")
    func stereoRoundTrip() throws {
        let sampleRate = 44100
        let original = stereoSineWave(
            freqL: 440, freqR: 880, sampleRate: sampleRate, duration: 1.0
        )

        let encoded = try OggVorbisEncoder.encode(
            samples: original, sampleRate: sampleRate, channels: 2, quality: 0.3
        )
        let decoded = try OggVorbisDecoder.decode(data: encoded)

        #expect(decoded.format.channels == 2)
        #expect(decoded.format.sampleRate == sampleRate)

        // Verify we got approximately the right number of frames
        let expectedFrames = sampleRate  // 1 second
        let decodedFrames = decoded.samples.count / 2
        #expect(abs(decodedFrames - expectedFrames) < 2048,
                "Expected ~\(expectedFrames) frames, got \(decodedFrames)")
    }

    @Test("Stream encoder: chunked writing")
    func streamEncoder() throws {
        let sampleRate = 44100
        let original = sineWave(frequency: 440, sampleRate: sampleRate, duration: 1.0)

        let encoder = try OggVorbisStreamEncoder(
            sampleRate: sampleRate, channels: 1, quality: 0.1
        )

        var output = Data()
        let chunkSize = 1024

        // Feed in chunks
        try original.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let totalFrames = original.count
            var offset = 0
            while offset < totalFrames {
                let frames = min(chunkSize, totalFrames - offset)
                let data = try encoder.write(
                    samples: base.advanced(by: offset), frameCount: frames
                )
                output.append(data)
                offset += frames
            }
        }

        output.append(try encoder.finish())

        // Verify valid OGG output
        #expect(output.count > 0)
        let header = String(data: output.prefix(4), encoding: .ascii)
        #expect(header == "OggS")

        // Decode and verify
        let decoded = try OggVorbisDecoder.decode(data: output)
        #expect(decoded.format.channels == 1)
        #expect(decoded.format.sampleRate == sampleRate)
        #expect(decoded.samples.count > 0)
    }

    @Test("Write after finish throws alreadyFinished")
    func writeAfterFinish() throws {
        let encoder = try OggVorbisStreamEncoder(
            sampleRate: 44100, channels: 1, quality: 0.1
        )

        _ = try encoder.write(samples: [Float](repeating: 0, count: 1024))
        _ = try encoder.finish()

        #expect(throws: OggEncoderError.alreadyFinished) {
            _ = try encoder.write(samples: [Float](repeating: 0, count: 1024))
        }

        #expect(throws: OggEncoderError.alreadyFinished) {
            _ = try encoder.finish()
        }
    }

    @Test("Invalid parameters: zero sample rate")
    func invalidSampleRate() {
        #expect(throws: OggEncoderError.invalidParameter) {
            _ = try OggVorbisStreamEncoder(sampleRate: 0, channels: 1)
        }
    }

    @Test("Invalid parameters: zero channels")
    func invalidChannels() {
        #expect(throws: OggEncoderError.invalidParameter) {
            _ = try OggVorbisStreamEncoder(sampleRate: 44100, channels: 0)
        }
    }

    @Test("Bitrate to quality mapping matches WDL reference")
    func bitrateMapping() {
        // Known values from WDL/vorbisencdec.h (mono)
        #expect(OggVorbisEncoder.qualityForBitrate(32, channels: 1) == -0.1)   // < 40
        #expect(OggVorbisEncoder.qualityForBitrate(64, channels: 1) == 0.0)    // boundary
        #expect(abs(OggVorbisEncoder.qualityForBitrate(95, channels: 1) - 0.3) < 0.001)
        #expect(abs(OggVorbisEncoder.qualityForBitrate(110, channels: 1) - 0.5) < 0.001)
        #expect(abs(OggVorbisEncoder.qualityForBitrate(140, channels: 1) - 0.75) < 0.001)
        #expect(OggVorbisEncoder.qualityForBitrate(240, channels: 1) == 1.0)

        // Stereo: bitrate scaled by 5/8 before lookup
        // 128 kbps stereo → 80 kbps effective → quality = 0.1 + (80-75)*(0.2/20) = 0.15
        let stereoQ = OggVorbisEncoder.qualityForBitrate(128, channels: 2)
        #expect(stereoQ > 0.1 && stereoQ < 0.2)

        // Clamping
        #expect(OggVorbisEncoder.qualityForBitrate(1, channels: 1) == -0.1)
        #expect(OggVorbisEncoder.qualityForBitrate(500, channels: 1) == 1.0)
    }

    @Test("Level preservation through encode/decode at various quality settings")
    func levelPreservation() throws {
        let sampleRate = 44100
        let duration: Float = 4.0
        let inputAmplitude: Float = 0.8

        // Generate a 440 Hz sine wave
        let original = sineWave(frequency: 440, sampleRate: sampleRate, duration: duration, amplitude: inputAmplitude)

        // RMS of a perfect sine: amplitude / sqrt(2)
        let expectedRMS = inputAmplitude / sqrt(2.0)

        for quality: Float in [-0.1, 0.0, 0.1, 0.3, 0.5, 0.75, 1.0] {
            let encoded = try OggVorbisEncoder.encode(
                samples: original, sampleRate: sampleRate, channels: 1, quality: quality
            )
            let decoded = try OggVorbisDecoder.decode(data: encoded)

            // Skip encoder delay (2048 samples) at start/end
            let skip = 4096
            let end = decoded.samples.count - skip
            guard end > skip else { continue }
            let samples = Array(decoded.samples[skip..<end])

            // Compute peak and RMS
            let peak = samples.map { abs($0) }.max() ?? 0
            var sumSq: Float = 0
            for s in samples { sumSq += s * s }
            let rms = sqrt(sumSq / Float(samples.count))

            let peakRatio = peak / inputAmplitude
            let rmsRatio = rms / expectedRMS

            // Log the results for analysis
            print("Quality \(String(format: "%+.1f", quality)): peak=\(String(format: "%.4f", peak)) (\(String(format: "%.1f%%", peakRatio * 100))), RMS=\(String(format: "%.4f", rms)) (\(String(format: "%.1f%%", rmsRatio * 100))), size=\(encoded.count / 1024)KB")

            // At any quality, level should be preserved within reasonable bounds
            // This test is diagnostic — if peak or RMS is significantly below 100%,
            // that explains the level discrepancy
            #expect(peakRatio > 0.5, "Peak dropped to \(peakRatio * 100)% at quality \(quality)")
            #expect(peakRatio < 1.1, "Peak exceeded input at quality \(quality)")
        }
    }

    @Test("Level preservation: streaming encoder (as IntervalBuffer uses it)")
    func streamingLevelPreservation() throws {
        let sampleRate = 44100
        let duration: Float = 8.0  // Typical NINJAM interval
        let inputAmplitude: Float = 0.8

        let original = sineWave(frequency: 440, sampleRate: sampleRate, duration: duration, amplitude: inputAmplitude)
        let expectedRMS = inputAmplitude / sqrt(2.0)

        // Encode using streaming encoder at quality 0.1 (what IntervalBuffer uses)
        let encoder = try OggVorbisStreamEncoder(sampleRate: sampleRate, channels: 1, quality: 0.1)
        var output = Data()
        let chunkSize = 512  // Same chunk size as IntervalBuffer

        try original.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < original.count {
                let frames = min(chunkSize, original.count - offset)
                let data = try encoder.write(samples: base.advanced(by: offset), frameCount: frames)
                output.append(data)
                offset += frames
            }
        }
        output.append(try encoder.finish())

        // Decode
        let decoded = try OggVorbisDecoder.decode(data: output)

        // Analyze middle section
        let skip = 4096
        let end = decoded.samples.count - skip
        #expect(end > skip, "Decoded signal too short")
        let samples = Array(decoded.samples[skip..<end])

        let peak = samples.map { abs($0) }.max() ?? 0
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))

        let peakRatio = peak / inputAmplitude
        let rmsRatio = rms / expectedRMS

        print("Streaming q0.1: peak=\(String(format: "%.4f", peak)) (\(String(format: "%.1f%%", peakRatio * 100))), RMS=\(String(format: "%.4f", rms)) (\(String(format: "%.1f%%", rmsRatio * 100)))")

        // If this shows ~61%, we found the codec attenuation
        #expect(peakRatio > 0.5, "Peak dropped to \(peakRatio * 100)%")
    }

    @Test("NINJAM interval: 8s mono at quality 0.1 produces reasonable output size")
    func ninjamIntervalSize() throws {
        // 8 seconds at 44100 Hz mono (typical NINJAM: 120 BPM, 16 BPI)
        let sampleRate = 44100
        let duration: Float = 8.0
        let samples = sineWave(frequency: 440, sampleRate: sampleRate, duration: duration)

        let encoded = try OggVorbisEncoder.encode(
            samples: samples, sampleRate: sampleRate, channels: 1, quality: 0.1
        )

        // At ~75 kbps, 8 seconds ≈ 75000 bytes. Allow wide range for VBR variation.
        let sizeKB = encoded.count / 1024
        #expect(encoded.count > 10_000, "Output too small: \(sizeKB) KB")
        #expect(encoded.count < 200_000, "Output too large: \(sizeKB) KB")

        // Verify it's decodable
        let decoded = try OggVorbisDecoder.decode(data: encoded)
        #expect(decoded.format.sampleRate == sampleRate)
        #expect(decoded.format.channels == 1)
    }
}
