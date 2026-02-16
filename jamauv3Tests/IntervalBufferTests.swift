//
//  IntervalBufferTests.swift
//  jamauv3Tests
//
//  Tests for interval buffer system: protocol messages, config, and integration.
//

import Testing
import Foundation
@testable import jamauv3

// MARK: - IntervalConfig Tests

@Suite("IntervalConfig")
struct IntervalConfigTests {

    @Test("Standard config: 120 BPM, 16 BPI, 44100 Hz → 352800 samples")
    func standardConfig() {
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        #expect(config.intervalLengthInSamples == 352800)
    }

    @Test("Different sample rate: 120 BPM, 16 BPI, 48000 Hz → 384000 samples")
    func differentSampleRate() {
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 48000)
        #expect(config.intervalLengthInSamples == 384000)
    }

    @Test("Short interval: 200 BPM, 4 BPI, 44100 Hz → 52920 samples")
    func shortInterval() {
        let config = IntervalConfig(bpm: 200, bpi: 4, sampleRate: 44100)
        // 4 / (200/60) * 44100 = 4 * 60/200 * 44100 = 1.2 * 44100 = 52920
        #expect(config.intervalLengthInSamples == 52920)
    }

    @Test("Zero BPM → 0 samples")
    func zeroBPM() {
        let config = IntervalConfig(bpm: 0, bpi: 16, sampleRate: 44100)
        #expect(config.intervalLengthInSamples == 0)
    }
}

// MARK: - ClientUploadIntervalBegin Tests

@Suite("ClientUploadIntervalBegin")
struct UploadIntervalBeginTests {

    @Test("Serialize produces 25-byte payload")
    func serializeSize() {
        let msg = ClientUploadIntervalBegin.audio(channelIndex: 0)
        let data = msg.serialize()
        #expect(data.count == 25)
    }

    @Test("FourCC at offset 20 is OGGv for audio")
    func fourCCOGG() {
        let msg = ClientUploadIntervalBegin.audio(channelIndex: 0)
        let data = msg.serialize()
        let fourCC = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        }
        #expect(fourCC == 0x7647474F)  // MAKE_NJ_FOURCC('O','G','G','v')
    }

    @Test("Silence has all-zero GUID and fourCC=0")
    func silence() {
        let msg = ClientUploadIntervalBegin.silence(channelIndex: 0)
        let data = msg.serialize()

        // GUID should be all zeros
        let guid = data.subdata(in: 0..<16)
        #expect(guid == Data(count: 16))

        // fourCC should be 0
        let fourCC = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        }
        #expect(fourCC == 0)
    }

    @Test("Channel index at offset 24")
    func channelIndex() {
        let msg = ClientUploadIntervalBegin.audio(channelIndex: 3)
        let data = msg.serialize()
        #expect(data[24] == 3)
    }

    @Test("buildMessage has correct header type 0x83 and payload length 25")
    func buildMessage() {
        let msg = ClientUploadIntervalBegin.audio(channelIndex: 0)
        let fullMsg = msg.buildMessage()

        // Header is 5 bytes + 25 byte payload
        #expect(fullMsg.count == 30)

        // Type byte
        #expect(fullMsg[0] == 0x83)

        // Payload length (4 bytes LE)
        let payloadLen = fullMsg.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
        }
        #expect(payloadLen == 25)
    }

    @Test("Audio begin has non-zero GUID")
    func audioGUIDNonZero() {
        let msg = ClientUploadIntervalBegin.audio(channelIndex: 0)
        let guid = msg.guid
        // With 16 random bytes, the probability of all zeros is 2^-128
        #expect(guid != Data(count: 16))
    }
}

// MARK: - ClientUploadIntervalWrite Tests

@Suite("ClientUploadIntervalWrite")
struct UploadIntervalWriteTests {

    @Test("Serialize: GUID + flags + audio data")
    func serialize() {
        let guid = Data(repeating: 0xAB, count: 16)
        let audio = Data([0x01, 0x02, 0x03])
        let msg = ClientUploadIntervalWrite(guid: guid, flags: 0, audioData: audio)
        let data = msg.serialize()

        #expect(data.count == 17 + 3)
        // GUID
        #expect(data.subdata(in: 0..<16) == guid)
        // Flags
        #expect(data[16] == 0)
        // Audio
        #expect(data.subdata(in: 17..<20) == audio)
    }

    @Test("End flag: flags & 1 = isEndOfInterval")
    func endFlag() {
        let guid = Data(count: 16)
        let endMsg = ClientUploadIntervalWrite.data(guid: guid, audioData: Data(), isEnd: true)
        #expect(endMsg.isEndOfInterval == true)
        #expect(endMsg.flags == 1)

        let continueMsg = ClientUploadIntervalWrite.data(guid: guid, audioData: Data(), isEnd: false)
        #expect(continueMsg.isEndOfInterval == false)
        #expect(continueMsg.flags == 0)
    }

    @Test("buildMessage has correct header type 0x84")
    func buildMessage() {
        let guid = Data(count: 16)
        let msg = ClientUploadIntervalWrite(guid: guid, flags: 1, audioData: Data([0xFF]))
        let fullMsg = msg.buildMessage()

        // Type byte
        #expect(fullMsg[0] == 0x84)

        // Payload length: 16 + 1 + 1 = 18
        let payloadLen = fullMsg.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
        }
        #expect(payloadLen == 18)
    }
}

// MARK: - Full Interval Encoding Test

@Suite("Interval Encoding Integration")
struct IntervalEncodingTests {

    @Test("1-second mono interval encodes to valid OGG")
    func fullIntervalEncode() throws {
        let sampleRate = 44100
        let duration: Float = 1.0
        let frameCount = Int(Float(sampleRate) * duration)

        // Generate a 440 Hz sine wave
        let samples = (0..<frameCount).map { i in
            0.8 * sin(2.0 * .pi * 440.0 * Float(i) / Float(sampleRate))
        }

        // Encode using the stream encoder (as IntervalBuffer would)
        let encoder = try OggVorbisStreamEncoder(sampleRate: sampleRate, channels: 1, quality: 0.1)
        var encoded = Data()

        // Feed in chunks (simulating render callbacks)
        let chunkSize = 512
        try samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < frameCount {
                let frames = min(chunkSize, frameCount - offset)
                let data = try encoder.write(samples: base.advanced(by: offset), frameCount: frames)
                encoded.append(data)
                offset += frames
            }
        }

        // Finish
        encoded.append(try encoder.finish())

        // Verify OGG header: first 4 bytes should be "OggS"
        #expect(encoded.count > 4)
        #expect(encoded[0] == 0x4F) // 'O'
        #expect(encoded[1] == 0x67) // 'g'
        #expect(encoded[2] == 0x67) // 'g'
        #expect(encoded[3] == 0x53) // 'S'

        // Verify it can be decoded
        let decoded = try OggVorbisDecoder.decode(data: encoded)
        // Should have approximately the same number of samples (Vorbis adds/trims a few)
        #expect(decoded.samples.count > frameCount / 2)
    }
}

// MARK: - Memory Tests

@Suite("Memory")
struct MemoryTests {

    // Strategy: run two equal phases after warmup. If there's a real leak,
    // both phases show similar growth. If it's just allocator ramp-up,
    // the second phase shows much less growth than the first.
    // We check that the second phase doesn't grow more than a threshold.

    @Test("OggVorbisStreamEncoder: repeated create/encode/finish doesn't leak")
    func encoderCreateDestroyDoesNotLeak() throws {
        let sampleRate = 44100
        let silence = [Float](repeating: 0, count: 4096)

        let result = try measureMemoryGrowth(warmup: 20, iterations: 200) {
            let enc = try OggVorbisStreamEncoder(sampleRate: sampleRate, channels: 1)
            _ = try silence.withUnsafeBufferPointer { ptr in
                try enc.write(samples: ptr.baseAddress!, frameCount: silence.count)
            }
            _ = try enc.finish()
        }

        // Phase 2 should show near-zero growth if no leak.
        // A real leak of ~50 KB/encoder × 200 = ~10 MB would show up clearly.
        #expect(result.midToEnd < 2 * 1024 * 1024 * memoryThresholdMultiplier,
                "Phase 2 grew by \(result.midToEnd / 1024) KB (phase 1: \(result.warmupToMid / 1024) KB) — possible encoder leak")
    }

    @Test("OggVorbisStreamEncoder: dropping without finish() doesn't leak C resources")
    func encoderDropWithoutFinishDoesNotLeak() throws {
        let sampleRate = 44100
        let silence = [Float](repeating: 0, count: 4096)

        let result = try measureMemoryGrowth(warmup: 20, iterations: 200) {
            let enc = try OggVorbisStreamEncoder(sampleRate: sampleRate, channels: 1)
            _ = try silence.withUnsafeBufferPointer { ptr in
                try enc.write(samples: ptr.baseAddress!, frameCount: silence.count)
            }
            // Intentionally NOT calling finish() — deinit must still free C structs
        }

        #expect(result.midToEnd < 2 * 1024 * 1024 * memoryThresholdMultiplier,
                "Phase 2 grew by \(result.midToEnd / 1024) KB (phase 1: \(result.warmupToMid / 1024) KB) — deinit may not be freeing C resources")
    }

    @Test("OGG encode/decode round-trip: repeated cycles don't leak")
    func encodeDecodeRoundTripDoesNotLeak() throws {
        let sampleRate = 44100
        let samples = [Float](repeating: 0, count: 44100)

        let result = try measureMemoryGrowth(warmup: 10, iterations: 50) {
            let encoded = try OggVorbisEncoder.encode(
                samples: samples, sampleRate: sampleRate, channels: 1
            )
            _ = try OggVorbisDecoder.decode(data: encoded)
        }

        #expect(result.midToEnd < 3 * 1024 * 1024 * memoryThresholdMultiplier,
                "Phase 2 grew by \(result.midToEnd / 1024) KB (phase 1: \(result.warmupToMid / 1024) KB) — possible encode/decode leak")
    }
}
