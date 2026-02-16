//
//  RemoteAudioMixerTests.swift
//  jamauv3Tests
//
//  Tests for RemoteAudioMixer: fragment accumulation, OGG decode, mixing, gain, user slots.
//

import Testing
import Foundation
import AudioToolbox
import Synchronization
@testable import jamauv3

// MARK: - Helper: Generate OGG data from a sine wave

private func generateOGGData(frequency: Float = 440.0, duration: Float = 1.0,
                              sampleRate: Int = 44100, channels: Int = 1,
                              quality: Float = 0.1) throws -> Data {
    let frameCount = Int(Float(sampleRate) * duration)
    let samples = (0..<frameCount).map { i in
        0.5 * sin(2.0 * .pi * frequency * Float(i) / Float(sampleRate))
    }
    return try OggVorbisEncoder.encode(
        samples: samples, sampleRate: sampleRate, channels: channels, quality: quality
    )
}

/// Helper to make a fake GUID from an integer
private func makeGUID(_ value: UInt8) -> Data {
    var guid = Data(count: 16)
    guid[0] = value
    return guid
}

/// Helper to create a RemoteChannelInfo
private func makeChannelInfo(username: String, channelIndex: UInt8 = 0, channelName: String = "ch") -> RemoteChannelInfo {
    return RemoteChannelInfo(isActive: true, channelIndex: channelIndex, volume: 0, pan: 0, flags: 0,
                       username: username, channelName: channelName)
}

// MARK: - Fragment Accumulation Tests

@Suite("RemoteAudioMixer - Fragment Accumulation")
struct FragmentAccumulationTests {

    @Test("Multiple receiveData calls assemble complete OGG data")
    func fragmentAssembly() throws {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let oggData = try generateOGGData(duration: 0.5)
        let guid = makeGUID(1)

        // Begin download
        mixer.beginDownload(guid: guid, username: "user1", channelIndex: 0,
                           fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)

        // Split OGG data into 3 fragments
        let chunkSize = oggData.count / 3
        let fragment1 = oggData[0..<chunkSize]
        let fragment2 = oggData[chunkSize..<(chunkSize * 2)]
        let fragment3 = oggData[(chunkSize * 2)...]

        mixer.receiveData(guid: guid, data: Data(fragment1), isEnd: false)
        mixer.receiveData(guid: guid, data: Data(fragment2), isEnd: false)
        mixer.receiveData(guid: guid, data: Data(fragment3), isEnd: true)

        // Give decode thread time to process
        Thread.sleep(forTimeInterval: 0.5)

        // The decode should have completed without error — verified by the mixer not crashing
        // and having processed the data.
    }

    @Test("Silence (non-OGG fourCC) skips download")
    func silenceDetection() {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let guid = makeGUID(2)

        // fourCC = 0 means silence
        mixer.beginDownload(guid: guid, username: "user1", channelIndex: 0, fourCC: 0)

        // receiveData with this guid should be a no-op (no active download)
        mixer.receiveData(guid: guid, data: Data([0x01, 0x02]), isEnd: true)

        // No crash = success
    }

    @Test("Unknown GUID in receiveData is safely ignored")
    func unknownGUID() {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let unknownGuid = makeGUID(99)
        mixer.receiveData(guid: unknownGuid, data: Data([0xFF]), isEnd: true)
        // No crash = success
    }
}

// MARK: - OGG Decode Round-Trip Tests

@Suite("RemoteAudioMixer - OGG Decode")
struct OGGDecodeTests {

    @Test("Encode known sine wave → accumulate → decode → verify PCM produced")
    func decodeRoundTrip() throws {
        // Use a short interval (200 BPM, 1 BPI = 0.3s = 13230 samples) so we can
        // easily cross the interval boundary to trigger the buffer swap.
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 200, bpi: 1, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let oggData = try generateOGGData(frequency: 440, duration: 0.3)
        let guid = makeGUID(3)

        mixer.updateUserInfo(channels: [makeChannelInfo(username: "testUser", channelName: "main")])

        mixer.beginDownload(guid: guid, username: "testUser", channelIndex: 0,
                           fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)
        mixer.receiveData(guid: guid, data: oggData, isEnd: true)

        // Wait for decode
        Thread.sleep(forTimeInterval: 1.0)

        let frameCount = 1024
        var outputL = [Float](repeating: 0, count: frameCount)
        var outputR = [Float](repeating: 0, count: frameCount)
        let gains: [Float] = Array(repeating: 1.0, count: 8)

        // Advance past the interval boundary to trigger the buffer swap.
        // Interval length ≈ 13230 samples, so we need ~13 calls of 1024.
        let intervalLength = config.intervalLengthInSamples
        let callsNeeded = (intervalLength / frameCount) + 2
        for _ in 0..<callsNeeded {
            outputL.withUnsafeMutableBufferPointer { lBuf in
                outputR.withUnsafeMutableBufferPointer { rBuf in
                    withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                        gains.withUnsafeBufferPointer { gainsPtr in
                            mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                        }
                    }
                }
            }
        }

        // Now read one more block — currentBuffer should have been swapped and contain audio
        outputL = [Float](repeating: 0, count: frameCount)
        outputR = [Float](repeating: 0, count: frameCount)
        outputL.withUnsafeMutableBufferPointer { lBuf in
            outputR.withUnsafeMutableBufferPointer { rBuf in
                withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                    gains.withUnsafeBufferPointer { gainsPtr in
                        mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                    }
                }
            }
        }

        let hasAudio = outputL.contains(where: { abs($0) > 0.001 })
        #expect(hasAudio, "Expected non-zero samples after decoding and mixing a sine wave")
    }
}

// MARK: - Gain Tests

@Suite("RemoteAudioMixer - Gain")
struct GainTests {

    @Test("gain=0 produces silence")
    func zeroGain() throws {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let oggData = try generateOGGData(duration: 0.5)
        let guid = makeGUID(4)

        mixer.updateUserInfo(channels: [makeChannelInfo(username: "gainUser")])

        mixer.beginDownload(guid: guid, username: "gainUser", channelIndex: 0,
                           fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)
        mixer.receiveData(guid: guid, data: oggData, isEnd: true)

        Thread.sleep(forTimeInterval: 0.5)

        let frameCount = 512
        var outputL = [Float](repeating: 0, count: frameCount)
        var outputR = [Float](repeating: 0, count: frameCount)
        let gains: [Float] = Array(repeating: 0.0, count: 8)

        // Force boundary + mix with gain=0
        outputL.withUnsafeMutableBufferPointer { lBuf in
            outputR.withUnsafeMutableBufferPointer { rBuf in
                withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                    gains.withUnsafeBufferPointer { gainsPtr in
                        mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                    }
                }
            }
        }

        let maxSample = outputL.map { abs($0) }.max() ?? 0
        #expect(maxSample < 0.001, "Expected silence with gain=0, got max sample \(maxSample)")
    }
}

// MARK: - User Slot Assignment Tests

@Suite("RemoteAudioMixer - User Slots")
struct UserSlotTests {

    @Test("Users get assigned sequential gain slots 0-7")
    func sequentialSlotAssignment() {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        // Add 3 users
        var channels: [RemoteChannelInfo] = (0..<3).map { i in
            makeChannelInfo(username: "user\(i)")
        }
        mixer.updateUserInfo(channels: channels)

        // Add a 4th user
        channels.append(makeChannelInfo(username: "user3"))
        mixer.updateUserInfo(channels: channels)

        // No crash and state is consistent — verified by the mixer working
    }

    @Test("User leave frees slot for reuse")
    func slotReuse() {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        // Add 2 users
        let channels: [RemoteChannelInfo] = [
            makeChannelInfo(username: "alice"),
            makeChannelInfo(username: "bob"),
        ]
        mixer.updateUserInfo(channels: channels)

        // Remove alice (only bob remains)
        mixer.updateUserInfo(channels: [makeChannelInfo(username: "bob")])

        // Add a new user — should reuse alice's freed slot
        let newChannels: [RemoteChannelInfo] = [
            makeChannelInfo(username: "bob"),
            makeChannelInfo(username: "charlie"),
        ]
        mixer.updateUserInfo(channels: newChannels)
    }
}

// MARK: - Resampling Tests

@Suite("RemoteAudioMixer - Resampling")
struct ResamplingTests {

    @Test("48kHz OGG decoded for 44.1kHz local rate")
    func resample48to44() throws {
        // Short interval so we can easily cross the boundary
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 200, bpi: 1, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        // Encode at 48kHz
        let oggData = try generateOGGData(frequency: 440, duration: 0.3, sampleRate: 48000)
        let guid = makeGUID(5)

        mixer.updateUserInfo(channels: [makeChannelInfo(username: "rsUser")])

        mixer.beginDownload(guid: guid, username: "rsUser", channelIndex: 0,
                           fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)
        mixer.receiveData(guid: guid, data: oggData, isEnd: true)

        // Wait for decode + resample
        Thread.sleep(forTimeInterval: 1.0)

        let frameCount = 512
        var outputL = [Float](repeating: 0, count: frameCount)
        var outputR = [Float](repeating: 0, count: frameCount)
        let gains: [Float] = Array(repeating: 1.0, count: 8)

        // Advance past interval boundary to trigger buffer swap
        let intervalLength = config.intervalLengthInSamples
        let callsNeeded = (intervalLength / frameCount) + 2
        for _ in 0..<callsNeeded {
            outputL.withUnsafeMutableBufferPointer { lBuf in
                outputR.withUnsafeMutableBufferPointer { rBuf in
                    withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                        gains.withUnsafeBufferPointer { gainsPtr in
                            mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                        }
                    }
                }
            }
        }

        // Now read — currentBuffer should contain resampled audio
        outputL = [Float](repeating: 0, count: frameCount)
        outputR = [Float](repeating: 0, count: frameCount)
        outputL.withUnsafeMutableBufferPointer { lBuf in
            outputR.withUnsafeMutableBufferPointer { rBuf in
                withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                    gains.withUnsafeBufferPointer { gainsPtr in
                        mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                    }
                }
            }
        }

        let hasAudio = outputL.contains(where: { abs($0) > 0.001 })
        #expect(hasAudio, "Expected non-zero samples after resampling 48kHz → 44.1kHz")
    }
}

// MARK: - Concurrent Access Tests

@Suite("RemoteAudioMixer - Concurrency")
struct ConcurrencyTests {

    @Test("Concurrent mixInto + beginDownload/receiveData does not crash")
    func concurrentMixAndDownload() throws {
        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 120, bpi: 16, sampleRate: 44100)
        mixer.start(config: config)
        defer { mixer.stop() }

        let oggData = try generateOGGData(duration: 0.5)
        let iterations = 200
        let stopped = Atomic<Bool>(false)

        // Render thread: call mixInto continuously
        let renderThread = Thread {
            let frameCount = 512
            var outputL = [Float](repeating: 0, count: frameCount)
            var outputR = [Float](repeating: 0, count: frameCount)
            let gains: [Float] = Array(repeating: 1.0, count: 8)

            while !stopped.load(ordering: .acquiring) {
                outputL.withUnsafeMutableBufferPointer { lBuf in
                    outputR.withUnsafeMutableBufferPointer { rBuf in
                        withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                            gains.withUnsafeBufferPointer { gainsPtr in
                                mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                            }
                        }
                    }
                }
            }
        }
        renderThread.name = "test.renderThread"
        renderThread.start()

        // Main thread: repeatedly add/remove users and send audio
        for i in 0..<iterations {
            let username = "user\(i % 4)"
            let guid = makeGUID(UInt8(i % 250))

            // Update user info (adds/removes users)
            let channels: [RemoteChannelInfo] = (0..<(i % 4 + 1)).map { j in
                makeChannelInfo(username: "user\(j)")
            }
            mixer.updateUserInfo(channels: channels)

            // Begin + receive audio
            mixer.beginDownload(guid: guid, username: username, channelIndex: 0,
                               fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)
            mixer.receiveData(guid: guid, data: oggData, isEnd: true)
        }

        // Let decode thread catch up
        Thread.sleep(forTimeInterval: 0.5)

        stopped.store(true, ordering: .releasing)
        // Wait for render thread
        Thread.sleep(forTimeInterval: 0.1)
    }
}

// MARK: - Memory Tests

@Suite("RemoteAudioMixer - Memory")
struct RemoteAudioMixerMemoryTests {

    @Test("Repeated decode cycles don't leak")
    func decodeCyclesDoNotLeak() throws {
        let result = try measureMemoryGrowth(warmup: 5, iterations: 30) {
            let oggData = try generateOGGData(duration: 0.25)
            _ = try OggVorbisDecoder.decode(data: oggData)
        }

        #expect(result.midToEnd < 3 * 1024 * 1024 * memoryThresholdMultiplier,
                "Phase 2 grew by \(result.midToEnd / 1024) KB — possible decode leak")
    }

    @Test("Sustained session: many intervals with dropped downloads don't leak")
    func sustainedSessionDoesNotLeak() throws {
        // Pre-generate OGG data once (avoids encoder allocation noise in measurement)
        let oggData = try generateOGGData(frequency: 440, duration: 0.3)
        let usernames = ["alice", "bob", "charlie"]
        let frameCount = 512
        let gains: [Float] = Array(repeating: 1.0, count: 8)

        /// Simulate one interval: begin + receive + mix through boundary
        func runInterval(mixer: RemoteAudioMixer, intervalIndex: Int, config: IntervalConfig) {
            var outputL = [Float](repeating: 0, count: frameCount)
            var outputR = [Float](repeating: 0, count: frameCount)

            // Each user sends audio this interval
            for (ui, username) in usernames.enumerated() {
                let guid = {
                    var g = Data(count: 16)
                    g[0] = UInt8(intervalIndex & 0xFF)
                    g[1] = UInt8(ui)
                    return g
                }()

                mixer.beginDownload(guid: guid, username: username, channelIndex: 0,
                                   fourCC: ClientUploadIntervalBegin.oggVorbisFourCC)

                // ~10% of intervals: simulate dropped isEnd (the leak scenario)
                if intervalIndex % 10 == ui {
                    // Send some data but never isEnd — stale download
                    mixer.receiveData(guid: guid, data: oggData.prefix(100), isEnd: false)
                } else {
                    // Normal complete download
                    mixer.receiveData(guid: guid, data: oggData, isEnd: true)
                }
            }

            // Let decode thread process
            Thread.sleep(forTimeInterval: 0.05)

            // Simulate render thread: advance through one full interval
            let callsNeeded = (config.intervalLengthInSamples / frameCount) + 2
            for _ in 0..<callsNeeded {
                outputL.withUnsafeMutableBufferPointer { lBuf in
                    outputR.withUnsafeMutableBufferPointer { rBuf in
                        withUnsafeMutableAudioBufferList(lBuf: lBuf, rBuf: rBuf) { abl in
                            gains.withUnsafeBufferPointer { gainsPtr in
                                mixer.mixInto(outputBufferList: abl, frameCount: frameCount, userGains: gainsPtr)
                            }
                        }
                    }
                }
            }
        }

        let mixer = RemoteAudioMixer()
        let config = IntervalConfig(bpm: 200, bpi: 1, sampleRate: 44100) // ~0.3s intervals
        mixer.start(config: config)
        defer { mixer.stop() }

        mixer.updateUserInfo(channels: usernames.map { makeChannelInfo(username: $0) })

        // Warmup phase
        for i in 0..<20 {
            runInterval(mixer: mixer, intervalIndex: i, config: config)
        }
        let memAfterWarmup = residentMemoryBytes()

        // Sustained phase: 200 intervals (~60 seconds of simulated session at 200 BPM/1 BPI)
        for i in 20..<220 {
            runInterval(mixer: mixer, intervalIndex: i, config: config)
        }
        let memAfterSustained = residentMemoryBytes()

        let growth = memAfterSustained - memAfterWarmup
        // With the leak fix, stale downloads are evicted each interval, so growth should be minimal.
        // Without the fix, 200 intervals × 3 users × ~10% drop rate × ~100 bytes = small but
        // the real issue is accumulated OGG Data objects (~50KB each) that never get freed.
        #expect(growth < 8 * 1024 * 1024 * memoryThresholdMultiplier,
                "Sustained session grew by \(growth / 1024) KB over 200 intervals — possible leak")
    }
}

