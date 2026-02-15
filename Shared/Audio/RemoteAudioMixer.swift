//
//  RemoteAudioMixer.swift
//  Shared/Audio
//
//  Receives OGG audio from remote NINJAM users, decodes to PCM,
//  and mixes into the DSP output so the local user hears other musicians.
//
//  Threading model (3 threads, mirrors IntervalBuffer in reverse):
//    Main thread (@MainActor) → accumulates OGG fragments per GUID
//    Decode thread (background) → decodes OGG to PCM, writes to playback buffers
//    Render thread → reads playback buffers, applies gains, additive mix
//

import Foundation
import AudioToolbox
import Synchronization
import os.log

// MARK: - Data Structures

struct ChannelKey: Hashable, Sendable {
    let username: String
    let channelIndex: Int
}

/// Accumulates OGG fragments for one download GUID until complete.
/// Owned by @MainActor methods only.
struct DownloadState {
    let channelKey: ChannelKey
    var data: Data
}

/// A decode job dispatched from main thread to decode thread.
/// Includes the playbackState reference so the decode thread never accesses channelStates.
private struct DecodeJob {
    let channelKey: ChannelKey
    let oggData: Data
    let playbackState: ChannelPlaybackState
}

/// Simple linear playback buffer. Written once (all decoded samples upfront), read sequentially.
/// More appropriate than CircularBuffer since we have all data before playback starts.
final class PlaybackBuffer: @unchecked Sendable {
    private let samples: UnsafeMutablePointer<Float>
    let count: Int
    private var readPosition: Int = 0

    init(samples: [Float]) {
        self.count = samples.count
        self.samples = .allocate(capacity: samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            self.samples.initialize(from: base, count: samples.count)
        }
    }

    deinit {
        samples.deallocate()
    }

    /// Read samples sequentially. Returns number of samples actually read.
    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let available = self.count - readPosition
        let toRead = min(count, available)
        guard toRead > 0 else { return 0 }
        dest.update(from: samples.advanced(by: readPosition), count: toRead)
        readPosition += toRead
        return toRead
    }

    var availableToRead: Int { count - readPosition }
}

/// Double-buffered playback state per remote channel.
/// Shared between decode thread (writes nextBuffer) and render thread (reads currentBuffer).
final class ChannelPlaybackState: @unchecked Sendable {
    let channelKey: ChannelKey

    /// Read by render thread during mix
    var currentBuffer: PlaybackBuffer?
    /// Written by decode thread after decoding
    var nextBuffer: PlaybackBuffer?
    /// Decode thread sets true; render thread exchanges to false at interval boundary
    let nextReady = Atomic<Bool>(false)
    /// Index into DSPKernel.userGains[] (-1 = not assigned).
    /// Atomic: written by main thread (updateUserInfo), read by render thread (mixInto).
    let gainSlot = Atomic<Int>(-1)

    init(channelKey: ChannelKey) {
        self.channelKey = channelKey
    }
}

// MARK: - Remote Audio Mixer

final class RemoteAudioMixer: @unchecked Sendable {

    // MARK: - Configuration

    private let _intervalLength = Atomic<Int>(0)
    private let _sampleRate = Atomic<Int>(44100)

    // MARK: - @MainActor State (fragment accumulation)

    /// Active downloads keyed by GUID. Only accessed on @MainActor.
    private var activeDownloads: [Data: DownloadState] = [:]

    /// Playback states keyed by ChannelKey. Only accessed on main thread.
    /// Render thread receives snapshots via staged handoff (stagedRenderChannels).
    private var channelStates: [ChannelKey: ChannelPlaybackState] = [:]

    /// Username → gain slot mapping. Only on @MainActor.
    private var userSlots: [String: Int] = [:]
    private var slotInUse: [Bool] = Array(repeating: false, count: 8)

    // MARK: - Decode Thread

    private var decodeThread: Thread?
    private let shouldStop = Atomic<Bool>(false)

    /// Thread-safe decode job queue
    private var decodeQueue: [DecodeJob] = []
    private let queueLock = DispatchQueue(label: "com.jamauv3.remoteAudioMixer.queue")

    // MARK: - Render Thread State

    /// Sample position within current interval (render thread only)
    private let samplePosition = Atomic<Int>(0)

    /// Snapshot of channels for render thread — updated at boundaries.
    /// Pre-allocated with capacity to avoid heap allocation on render thread.
    private var renderChannels: [ChannelPlaybackState] = {
        var arr = [ChannelPlaybackState]()
        arr.reserveCapacity(16)
        return arr
    }()
    /// Staged channel snapshot: written by main thread, picked up by render thread.
    /// Protocol: flag=false → main thread owns staging area. flag=true → render thread may read.
    private var stagedRenderChannels: [ChannelPlaybackState] = []
    private let stagedRenderChannelsReady = Atomic<Bool>(false)

    /// Pre-allocated temp buffer for reading from PlaybackBuffer in mix loop
    private var tempBuffer: UnsafeMutablePointer<Float>?
    private var tempBufferSize: Int = 0

    private let logger = Logger(subsystem: "com.jamauv3", category: "RemoteAudioMixer")

    // MARK: - Lifecycle

    func start(config: IntervalConfig) {
        shouldStop.store(false, ordering: .releasing)
        _intervalLength.store(config.intervalLengthInSamples, ordering: .releasing)
        _sampleRate.store(Int(config.sampleRate), ordering: .releasing)
        samplePosition.store(0, ordering: .releasing)
        stagedRenderChannelsReady.store(false, ordering: .releasing)

        let thread = Thread { [weak self] in
            self?.decodeLoop()
        }
        thread.name = "com.jamauv3.remoteAudioDecoder"
        thread.qualityOfService = .userInitiated
        decodeThread = thread
        thread.start()

        logger.info("RemoteAudioMixer started")
    }

    func stop() {
        shouldStop.store(true, ordering: .releasing)

        let deadline = Date().addingTimeInterval(2.0)
        while decodeThread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        decodeThread = nil

        activeDownloads.removeAll()
        queueLock.sync { decodeQueue.removeAll() }

        if let buf = tempBuffer {
            buf.deallocate()
            tempBuffer = nil
            tempBufferSize = 0
        }

        logger.info("RemoteAudioMixer stopped")
    }

    func updateConfig(_ config: IntervalConfig) {
        _intervalLength.store(config.intervalLengthInSamples, ordering: .releasing)
        _sampleRate.store(Int(config.sampleRate), ordering: .releasing)
    }

    deinit {
        if let buf = tempBuffer {
            buf.deallocate()
        }
    }

    // MARK: - @MainActor API (Fragment Accumulation)

    /// Called when server announces a new download interval.
    func beginDownload(guid: Data, username: String, channelIndex: Int, fourCC: UInt32) {
        // Skip non-OGG (silence) intervals
        guard fourCC == ClientUploadIntervalBegin.oggVorbisFourCC else {
            return
        }

        let key = ChannelKey(username: username, channelIndex: channelIndex)
        activeDownloads[guid] = DownloadState(channelKey: key, data: Data())

        // Ensure playback state exists for this channel
        if channelStates[key] == nil {
            let state = ChannelPlaybackState(channelKey: key)
            if let slot = userSlots[username] {
                state.gainSlot.store(slot, ordering: .releasing)
            }
            channelStates[key] = state
            stageRenderSnapshot()
        }
    }

    /// Called with audio data fragments for a download.
    func receiveData(guid: Data, data: Data, isEnd: Bool) {
        guard var download = activeDownloads[guid] else { return }

        download.data.append(data)

        if isEnd {
            activeDownloads.removeValue(forKey: guid)
            let oggData = download.data
            let channelKey = download.channelKey

            guard !oggData.isEmpty else { return }
            guard let state = channelStates[channelKey] else { return }
            let job = DecodeJob(channelKey: channelKey, oggData: oggData, playbackState: state)
            queueLock.sync { decodeQueue.append(job) }
        } else {
            activeDownloads[guid] = download
        }
    }

    /// Called when user info changes. Assigns gain slots to usernames.
    func updateUserInfo(channels: [RemoteChannelInfo]) {
        var activeUsernames = Set<String>()
        for ch in channels where ch.isActive {
            activeUsernames.insert(ch.username)
        }

        // Remove slots for users who left
        for (username, slot) in userSlots {
            if !activeUsernames.contains(username) {
                slotInUse[slot] = false
                userSlots.removeValue(forKey: username)
                for (_, state) in channelStates where state.channelKey.username == username {
                    state.gainSlot.store(-1, ordering: .releasing)
                }
            }
        }

        // Assign slots to new users
        for username in activeUsernames {
            if userSlots[username] == nil {
                if let freeSlot = slotInUse.firstIndex(of: false) {
                    slotInUse[freeSlot] = true
                    userSlots[username] = freeSlot
                    for (_, state) in channelStates where state.channelKey.username == username {
                        state.gainSlot.store(freeSlot, ordering: .releasing)
                    }
                }
            }
        }

        // Clean up playback states for inactive channels
        let inactiveKeys = channelStates.keys.filter { key in
            !channels.contains(where: { $0.username == key.username && Int($0.channelIndex) == key.channelIndex && $0.isActive })
        }
        for key in inactiveKeys {
            channelStates.removeValue(forKey: key)
        }

        if !inactiveKeys.isEmpty {
            stageRenderSnapshot()
        }
    }

    /// Prepare a render channel snapshot for the render thread to pick up.
    /// Only writes if the previous snapshot was consumed (flag is false).
    /// Called from main thread only.
    private func stageRenderSnapshot() {
        guard !stagedRenderChannelsReady.load(ordering: .acquiring) else {
            return  // Render thread hasn't consumed previous snapshot yet — skip
        }
        stagedRenderChannels = Array(channelStates.values)
        stagedRenderChannelsReady.store(true, ordering: .releasing)
    }

    // MARK: - Decode Thread

    private func decodeLoop() {
        while !shouldStop.load(ordering: .acquiring) {
            if let job = dequeueJob() {
                decodeAndBuffer(job)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func dequeueJob() -> DecodeJob? {
        queueLock.sync {
            decodeQueue.isEmpty ? nil : decodeQueue.removeFirst()
        }
    }

    private func decodeAndBuffer(_ job: DecodeJob) {
        do {
            let decoded = try OggVorbisDecoder.decode(data: job.oggData)
            let deinterleaved = decoded.deinterleavedSamples()
            guard let monoChannel = deinterleaved.first, !monoChannel.isEmpty else { return }

            let localSampleRate = _sampleRate.load(ordering: .acquiring)

            // Resample if needed
            let samples: [Float]
            if decoded.format.sampleRate != localSampleRate && localSampleRate > 0 && decoded.format.sampleRate > 0 {
                samples = linearResample(monoChannel, fromRate: decoded.format.sampleRate, toRate: localSampleRate)
            } else {
                samples = monoChannel
            }

            let buffer = PlaybackBuffer(samples: samples)
            job.playbackState.nextBuffer = buffer
            job.playbackState.nextReady.store(true, ordering: .releasing)

        } catch {
            logger.error("Failed to decode OGG for \(job.channelKey.username)/\(job.channelKey.channelIndex): \(error)")
        }
    }

    /// Linear interpolation resampling (matches njclient.cpp quality)
    private func linearResample(_ input: [Float], fromRate: Int, toRate: Int) -> [Float] {
        let ratio = Double(fromRate) / Double(toRate)
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let srcIndex = Int(srcPos)
            let frac = Float(srcPos - Double(srcIndex))

            if srcIndex + 1 < input.count {
                output[i] = input[srcIndex] * (1.0 - frac) + input[srcIndex + 1] * frac
            } else if srcIndex < input.count {
                output[i] = input[srcIndex]
            }
        }
        return output
    }

    // MARK: - Render Thread API

    /// Mix remote audio into the output buffer. Called from DSPKernel.process().
    /// Must be RT-safe: no allocations, no locks.
    /// userGains is passed as UnsafeBufferPointer to avoid Array retain/release on the render thread.
    func mixInto(outputBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 userGains: UnsafeBufferPointer<Float>) {

        let intervalLength = _intervalLength.load(ordering: .acquiring)
        guard intervalLength > 0 else { return }

        // Ensure temp buffer is large enough
        ensureTempBuffer(frameCount: frameCount)
        guard let temp = tempBuffer else { return }

        // Pick up staged channel snapshot from main thread if available
        if stagedRenderChannelsReady.exchange(false, ordering: .acquiringAndReleasing) {
            renderChannels = stagedRenderChannels
        }

        // Track sample position and detect boundary
        var pos = samplePosition.load(ordering: .acquiring)
        let willCrossBoundary = pos + frameCount >= intervalLength

        // At interval boundary, swap buffers
        if willCrossBoundary {
            for channel in renderChannels {
                if channel.nextReady.exchange(false, ordering: .acquiringAndReleasing) {
                    channel.currentBuffer = channel.nextBuffer
                    channel.nextBuffer = nil
                }
            }
        }

        // Update position
        pos = (pos + frameCount) % intervalLength
        samplePosition.store(pos, ordering: .releasing)

        // Get output buffer pointers
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        guard outputBuffers.count >= 1 else { return }

        let outputL = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self)
        let outputR = outputBuffers.count >= 2 ? outputBuffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        guard let outL = outputL else { return }

        // Mix each active channel
        for channel in renderChannels {
            guard let buffer = channel.currentBuffer else { continue }

            let slot = channel.gainSlot.load(ordering: .acquiring)
            guard slot >= 0, slot < userGains.count else { continue }
            let gain = userGains[slot]
            guard gain > 0.001 else { continue }

            let samplesRead = buffer.read(into: temp, count: frameCount)
            guard samplesRead > 0 else { continue }

            // Additive mix: mono → stereo (equal L+R)
            for i in 0..<samplesRead {
                let sample = temp[i] * gain
                outL[i] += sample
                outputR?[i] += sample
            }
        }
    }

    /// Ensure the pre-allocated temp buffer is large enough.
    private func ensureTempBuffer(frameCount: Int) {
        if frameCount > tempBufferSize {
            tempBuffer?.deallocate()
            tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            tempBuffer?.initialize(repeating: 0, count: frameCount)
            tempBufferSize = frameCount
        }
    }

}
