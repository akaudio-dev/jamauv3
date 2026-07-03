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
import CoreAudio
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
    let channels: Int
    private var readPosition: Int = 0

    init(samples: [Float], channels: Int = 1) {
        self.count = samples.count
        self.channels = channels
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

    /// Bounds against a hostile server: one inventing endless users/channels
    /// (roster growth) or streaming endless interval fragments without isEnd
    /// (accumulation growth). Legit intervals top out well below both.
    private static let maxRemoteChannels = 64
    private static let maxDownloadBytes = 4 * 1024 * 1024

    private let _intervalLength = Atomic<Int>(0)
    private let _sampleRate = Atomic<Int>(44100)

    // MARK: - @MainActor State (fragment accumulation)

    /// Active downloads keyed by GUID. Only accessed on @MainActor.
    private var activeDownloads: [Data: DownloadState] = [:]

    /// Reverse mapping: ChannelKey → current GUID. Used to evict stale downloads
    /// when a new interval begins for the same channel (previous isEnd was missed).
    private var channelCurrentGUID: [ChannelKey: Data] = [:]

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

    /// True once the interval clock has been anchored to a real boundary — either by a
    /// DAW-transport snap (snapSamplePosition) or by the cold-start anchor in mixInto().
    /// Until then the very first decoded interval is played immediately and the clock is
    /// reset to that instant, so a freshly decoded interval doesn't wait up to a full
    /// interval for the free-running boundary (the startup-latency bug).
    private let clockAnchored = Atomic<Bool>(false)

    /// Snapshot of channels for render thread — updated at boundaries.
    /// Pre-allocated with capacity to avoid heap allocation on render thread.
    private var renderChannels: [ChannelPlaybackState] = {
        var arr = [ChannelPlaybackState]()
        arr.reserveCapacity(16)
        return arr
    }()
    /// Staged channel snapshot: written by main thread, picked up by render thread.
    /// Protected by Mutex (os_unfair_lock) — hold time is nanoseconds (array pointer copy).
    /// nil = no pending snapshot; non-nil = main thread staged an update for render thread.
    private let stagedRenderChannels = Mutex<[ChannelPlaybackState]?>(nil)

    /// Pre-allocated temp buffer for reading from PlaybackBuffer in mix loop
    private var tempBuffer: UnsafeMutablePointer<Float>?
    private var tempBufferSize: Int = 0

    // MARK: - Diagnostics (atomic counters readable from main thread)
    let bufferSwapCount = Atomic<Int>(0)
    let samplesMixedCount = Atomic<Int>(0)
    let decodeCount = Atomic<Int>(0)
    let mixCallCount = Atomic<Int>(0)

    private let logger = Logger(subsystem: "com.jamauv3", category: "RemoteAudioMixer")

    // MARK: - Lifecycle

    func start(config: IntervalConfig) {
        shouldStop.store(false, ordering: .releasing)
        _intervalLength.store(config.intervalLengthInSamples, ordering: .releasing)
        _sampleRate.store(Int(config.sampleRate), ordering: .releasing)
        samplePosition.store(0, ordering: .releasing)
        clockAnchored.store(false, ordering: .releasing)
        stagedRenderChannels.withLock { $0 = nil }

        let thread = Thread { [weak self] in
            self?.decodeLoop()
        }
        thread.name = "com.jamauv3.remoteAudioDecoder"
        thread.qualityOfService = .userInitiated
        decodeThread = thread
        thread.start()

        logger.debug("RemoteAudioMixer started")
    }

    func stop() {
        shouldStop.store(true, ordering: .releasing)

        let deadline = Date().addingTimeInterval(2.0)
        while decodeThread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        decodeThread = nil

        activeDownloads.removeAll()
        channelCurrentGUID.removeAll()
        queueLock.sync { decodeQueue.removeAll() }

        // tempBuffer is deallocated in deinit, not here: a render callback already
        // inside mixInto() may still be writing into it. mixInto gates on shouldStop,
        // but an in-flight callback can be past that check when stop() runs.

        logger.debug("RemoteAudioMixer stopped")
    }

    /// Returns an array of 8 usernames indexed by slot. Called from main thread only.
    func slotUsernames() -> [String] {
        var result = Array(repeating: "", count: 8)
        for (username, slot) in userSlots {
            result[slot] = username
        }
        return result
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

        guard channelStates[key] != nil || channelStates.count < Self.maxRemoteChannels else {
            return
        }

        // Evict stale download for this channel if the previous interval's isEnd was missed
        if let oldGUID = channelCurrentGUID[key] {
            if activeDownloads.removeValue(forKey: oldGUID) != nil {
                logger.debug("Evicted stale download for \(username)/\(channelIndex)")
            }
        }
        channelCurrentGUID[key] = guid

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
        guard var download = activeDownloads[guid] else {
            return
        }

        download.data.append(data)

        guard download.data.count <= Self.maxDownloadBytes else {
            activeDownloads.removeValue(forKey: guid)
            if channelCurrentGUID[download.channelKey] == guid {
                channelCurrentGUID.removeValue(forKey: download.channelKey)
            }
            logger.warning("Dropped oversized download interval (\(download.data.count) bytes)")
            return
        }

        if isEnd {
            activeDownloads.removeValue(forKey: guid)
            // Clear reverse mapping since download completed normally
            if channelCurrentGUID[download.channelKey] == guid {
                channelCurrentGUID.removeValue(forKey: download.channelKey)
            }
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

    /// Called when user info changes (USERINFO_CHANGE_NOTIFY). Assigns gain slots to usernames.
    ///
    /// This message is INCREMENTAL: it lists only the channels that changed, and signals a
    /// departure with an explicit `isActive == false` record. Users absent from the message are
    /// unaffected, so we apply each record independently and must NOT treat the message as a full
    /// roster snapshot. (Treating it as a snapshot silenced every existing player whenever a new
    /// one joined: their channels weren't in the join message, so they looked "departed" and got
    /// their slot + playback state torn down.)
    func updateUserInfo(channels: [RemoteChannelInfo]) {
        var snapshotDirty = false

        for ch in channels {
            let key = ChannelKey(username: ch.username, channelIndex: Int(ch.channelIndex))

            if ch.isActive {
                // Ensure this user has a gain slot, then propagate it to any of their channels.
                if userSlots[ch.username] == nil, let freeSlot = slotInUse.firstIndex(of: false) {
                    slotInUse[freeSlot] = true
                    userSlots[ch.username] = freeSlot
                    // logger.debug("updateUserInfo: assigned slot \(freeSlot) to \(ch.username)")
                }
                if let slot = userSlots[ch.username] {
                    for (_, state) in channelStates where state.channelKey.username == ch.username {
                        state.gainSlot.store(slot, ordering: .releasing)
                    }
                }
            } else {
                // Explicit departure of this one channel: drop its playback state…
                if channelStates.removeValue(forKey: key) != nil {
                    snapshotDirty = true
                }
                // …and free the user's gain slot only once they have no channels left.
                let userStillPresent = channelStates.keys.contains { $0.username == ch.username }
                if !userStillPresent, let slot = userSlots.removeValue(forKey: ch.username) {
                    slotInUse[slot] = false
                    // logger.debug("updateUserInfo: freed slot \(slot) for \(ch.username)")
                }
            }
        }

        if snapshotDirty {
            stageRenderSnapshot()
        }
    }

    /// Prepare a render channel snapshot for the render thread to pick up.
    /// Called from main thread only.
    private func stageRenderSnapshot() {
        stagedRenderChannels.withLock { $0 = Array(channelStates.values) }
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
            // maxFrames bounds a decompression bomb: a few MB of hostile OGG can
            // decode to orders of magnitude more PCM than any legit interval.
            let decoded = try OggVorbisDecoder.decode(data: job.oggData,
                                                      maxFrames: NJ_MAX_INTERVAL_SAMPLES)
            let deinterleaved = decoded.deinterleavedSamples()
            guard let ch0 = deinterleaved.first, !ch0.isEmpty else { return }

            let localSampleRate = _sampleRate.load(ordering: .acquiring)
            let needsResample = decoded.format.sampleRate != localSampleRate && localSampleRate > 0 && decoded.format.sampleRate > 0

            let buffer: PlaybackBuffer
            if decoded.format.channels >= 2 {
                // Stereo source — resample each channel, interleave
                let left = needsResample ? linearResample(ch0, fromRate: decoded.format.sampleRate, toRate: localSampleRate) : ch0
                let ch1 = deinterleaved[1]
                let right = needsResample ? linearResample(ch1, fromRate: decoded.format.sampleRate, toRate: localSampleRate) : ch1
                let frameCount = min(left.count, right.count)
                var interleaved = [Float](repeating: 0, count: frameCount * 2)
                for i in 0..<frameCount {
                    interleaved[i * 2] = left[i]
                    interleaved[i * 2 + 1] = right[i]
                }
                buffer = PlaybackBuffer(samples: interleaved, channels: 2)
            } else {
                // Mono source
                let samples = needsResample ? linearResample(ch0, fromRate: decoded.format.sampleRate, toRate: localSampleRate) : ch0
                buffer = PlaybackBuffer(samples: samples, channels: 1)
            }

            job.playbackState.nextBuffer = buffer
            job.playbackState.nextReady.store(true, ordering: .releasing)

            decodeCount.wrappingAdd(1, ordering: .relaxed)

        } catch {
            logger.error("Failed to decode OGG: \(error)")
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

    /// Snap the sample position to align with the DAW beat grid.
    /// Called from DSPKernel.process() on transport start/seek. RT-safe (single atomic store).
    func snapSamplePosition(_ newPosition: Int) {
        samplePosition.store(newPosition, ordering: .releasing)
        // A DAW-transport snap defines the clock phase; suppress the cold-start anchor.
        clockAnchored.store(true, ordering: .releasing)
    }

    /// Mix remote audio into the output buffer. Called from DSPKernel.process().
    /// Nearly RT-safe: only a brief Mutex lock (os_unfair_lock, nanosecond hold time) for snapshot pickup.
    /// userGains is passed as UnsafeBufferPointer to avoid Array retain/release on the render thread.
    /// outPeaks: caller-owned buffer of 8 Floats; mixer max-accumulates per-slot peaks into it.
    func mixInto(outputBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: Int,
                 userGains: UnsafeBufferPointer<Float>,
                 outPeaks: UnsafeMutablePointer<Float>? = nil,
                 intervalLength: Int = 0) {

        guard !shouldStop.load(ordering: .acquiring) else { return }

        // Use passed intervalLength if nonzero, else fall back to internal config
        let intervalLength = intervalLength > 0 ? intervalLength : _intervalLength.load(ordering: .acquiring)
        guard intervalLength > 0 else { return }

        mixCallCount.wrappingAdd(1, ordering: .relaxed)

        // Ensure temp buffer is large enough (stereo needs 2× samples)
        ensureTempBuffer(frameCount: frameCount * 2)
        guard let temp = tempBuffer else { return }

        // Pick up staged channel snapshot from main thread if available
        stagedRenderChannels.withLock { staged in
            if let channels = staged {
                renderChannels = channels
                staged = nil
            }
        }

        // Track sample position and detect boundary
        var pos = samplePosition.load(ordering: .acquiring)

        // Cold-start anchor: if the clock isn't anchored yet (we're free-running, i.e. no
        // DAW-transport snap is driving it) and the first decoded interval is ready, start
        // playing it now and reset the clock to this instant. This aligns the interval
        // boundary to the real server interval grid, so a freshly decoded interval plays as
        // soon as it arrives instead of waiting up to a full interval for the free-running
        // boundary. When DAW-synced, snapSamplePosition() has already set clockAnchored, so
        // we defer to that alignment instead.
        if !clockAnchored.load(ordering: .acquiring) {
            var anyReady = false
            for channel in renderChannels {
                if channel.nextReady.load(ordering: .acquiring) { anyReady = true; break }
            }
            if anyReady {
                for channel in renderChannels {
                    if channel.nextReady.exchange(false, ordering: .acquiringAndReleasing) {
                        channel.currentBuffer = channel.nextBuffer
                        channel.nextBuffer = nil
                        bufferSwapCount.wrappingAdd(1, ordering: .relaxed)
                    }
                }
                pos = 0
                clockAnchored.store(true, ordering: .releasing)
            }
        }

        let willCrossBoundary = pos + frameCount >= intervalLength

        // At interval boundary, swap buffers
        if willCrossBoundary {
            for channel in renderChannels {
                if channel.nextReady.exchange(false, ordering: .acquiringAndReleasing) {
                    channel.currentBuffer = channel.nextBuffer
                    channel.nextBuffer = nil
                    bufferSwapCount.wrappingAdd(1, ordering: .relaxed)
                }
            }
        }

        // Update position
        pos = (pos + frameCount) % intervalLength
        samplePosition.store(pos, ordering: .releasing)

        // Mix each active channel
        for channel in renderChannels {
            guard let buffer = channel.currentBuffer else { continue }

            let slot = channel.gainSlot.load(ordering: .acquiring)
            guard slot >= 0, slot < userGains.count else { continue }
            let gain = userGains[slot]
            guard gain > 0.001 else { continue }

            let ch = buffer.channels
            let samplesRead = buffer.read(into: temp, count: frameCount * ch)
            guard samplesRead > 0 else { continue }
            let framesRead = samplesRead / ch

            samplesMixedCount.wrappingAdd(framesRead, ordering: .relaxed)

            let peak = additiveMix(
                source: temp, framesRead: framesRead, sourceChannels: ch,
                into: outputBufferList, gain: gain)

            if let outPeaks, slot < 8, peak > outPeaks[slot] {
                outPeaks[slot] = peak
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

// MARK: - Shared Mixing Utility

/// Additively mix interleaved source samples into an AudioBufferList,
/// handling all channel format combinations (stereo↔mono).
/// Returns the peak amplitude of the mixed signal (post-gain).
/// RT-safe: no allocations, no locks.
@inline(__always)
func additiveMix(
    source: UnsafePointer<Float>,
    framesRead: Int,
    sourceChannels: Int,
    into outputBufferList: UnsafeMutablePointer<AudioBufferList>,
    gain: Float = 1.0
) -> Float {
    let buffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
    guard buffers.count >= 1,
          let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
    let outR = buffers.count >= 2 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

    var peak: Float = 0

    if sourceChannels >= 2 {
        if let outR {
            // Stereo → stereo: deinterleave and add
            for i in 0..<framesRead {
                let sL = source[i * 2] * gain
                let sR = source[i * 2 + 1] * gain
                outL[i] += sL
                outR[i] += sR
                let s = max(abs(sL), abs(sR))
                if s > peak { peak = s }
            }
        } else {
            // Stereo → mono: downmix and add
            for i in 0..<framesRead {
                let sL = source[i * 2] * gain
                let sR = source[i * 2 + 1] * gain
                outL[i] += (sL + sR) * 0.5
                let s = max(abs(sL), abs(sR))
                if s > peak { peak = s }
            }
        }
    } else {
        if let outR {
            // Mono → stereo: duplicate to both channels
            for i in 0..<framesRead {
                let sample = source[i] * gain
                outL[i] += sample
                outR[i] += sample
                let s = abs(sample)
                if s > peak { peak = s }
            }
        } else {
            // Mono → mono
            for i in 0..<framesRead {
                let sample = source[i] * gain
                outL[i] += sample
                let s = abs(sample)
                if s > peak { peak = s }
            }
        }
    }

    return peak
}
