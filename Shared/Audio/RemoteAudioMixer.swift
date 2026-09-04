// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

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
    /// Join-gap preview: while the owning channel hasn't started its chained playout,
    /// this interval is also decoded progressively as fragments arrive, resampled, and
    /// pushed into the channel's live FIFO. nil once the channel has started (or for a
    /// channel that was already playing when this interval began).
    var previewDecoder: OggVorbisPushdataDecoder?
    var previewResampler = PreviewResampler()
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

/// Live FIFO for the join-gap first-interval preview: interleaved-stereo PCM at the
/// engine rate, appended by @MainActor (progressive pushdata decode of the in-flight
/// interval) and drained by the render thread. A fixed-capacity ring, lazily allocated
/// on first use so channels that never preview cost nothing. On overflow the oldest
/// audio is dropped (skip-ahead) so a network stall never accretes latency. All access
/// is under an os_unfair_lock (Mutex) — nanosecond holds, matching the mixer's other
/// render-thread locks.
final class PreviewFIFO: @unchecked Sendable {
    private struct State {
        var buf: [Float] = []   // ring storage (interleaved stereo); empty until first use
        var head = 0            // read index (in floats)
        var count = 0           // valid floats available to read
    }
    private let state = Mutex(State())
    /// Capacity in frames (×2 floats). ~5 s of stereo caps the preview backlog.
    private let capacityFloats: Int

    init(capacityFrames: Int) {
        self.capacityFloats = max(2, capacityFrames * 2)
    }

    /// Append interleaved-stereo frames (main thread). Drops oldest on overflow.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        state.withLock { s in
            if s.buf.isEmpty {
                s.buf = [Float](repeating: 0, count: capacityFloats)
                s.head = 0; s.count = 0
            }
            let cap = s.buf.count
            for v in samples {
                if s.count == cap {
                    // Full: drop the oldest frame pair to make room (skip-ahead).
                    s.head = (s.head + 1) % cap
                    s.count -= 1
                }
                let tail = (s.head + s.count) % cap
                s.buf[tail] = v
                s.count += 1
            }
        }
    }

    /// Frames currently available to read.
    var availableFrames: Int {
        state.withLock { $0.count / 2 }
    }

    /// Drain up to `maxFrames` interleaved-stereo frames into `dest` (render thread).
    /// Returns frames actually read.
    func read(into dest: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        state.withLock { s in
            guard !s.buf.isEmpty else { return 0 }
            let cap = s.buf.count
            let want = min(maxFrames * 2, s.count)
            guard want > 0 else { return 0 }
            for i in 0..<want {
                dest[i] = s.buf[(s.head + i) % cap]
            }
            s.head = (s.head + want) % cap
            s.count -= want
            return want / 2
        }
    }

    func clear() {
        state.withLock { s in s.head = 0; s.count = 0 }
    }
}

/// Double-buffered playback state per remote channel.
/// Shared between decode thread (writes nextBuffer) and render thread (reads currentBuffer).
final class ChannelPlaybackState: @unchecked Sendable {
    let channelKey: ChannelKey

    /// Read/written by render thread only during mix
    var currentBuffer: PlaybackBuffer?
    /// Decode→render handoff slot. Mutex (os_unfair_lock, nanosecond hold)
    /// rather than a ready-flag + plain reference: the flag pair raced when a
    /// burst decode replaced the reference while the render thread was
    /// mid-swap. nil = nothing pending.
    let nextBuffer = Mutex<PlaybackBuffer?>(nil)
    /// Index into DSPKernel.userGains[] (-1 = not assigned).
    /// Atomic: written by main thread (updateUserInfo), read by render thread (mixInto).
    let gainSlot = Atomic<Int>(-1)

    // MARK: Join-gap first-interval preview
    /// True once the channel's first *chained* (fully-decoded) interval has begun
    /// playing. Render thread sets it at the first buffer swap; main thread reads it
    /// to stop feeding the preview once the real chain has taken over. Until then the
    /// in-flight interval is previewed live from `previewFIFO`.
    let everStarted = Atomic<Bool>(false)
    /// Live preview audio (in-flight interval), engine-rate interleaved stereo.
    let previewFIFO: PreviewFIFO
    /// Render-only: preview prebuffer gate (mirrors voice `vstarted`).
    var previewPlaying = false
    /// Render-only: fade-out frames left after the chain takes over (0 = no fade).
    var pfadeRemaining = 0

    init(channelKey: ChannelKey, previewCapacityFrames: Int) {
        self.channelKey = channelKey
        self.previewFIFO = PreviewFIFO(capacityFrames: previewCapacityFrames)
    }

    /// Take the pending buffer if one is ready (render thread).
    func takeNextBuffer() -> PlaybackBuffer? {
        nextBuffer.withLock { pending in
            let taken = pending
            pending = nil
            return taken
        }
    }

    var hasNextBuffer: Bool {
        nextBuffer.withLock { $0 != nil }
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
        // Fresh session: any channel state surviving a prior connection re-opens its
        // join-gap preview so a reconnect hears the room quickly too.
        for (_, state) in channelStates {
            state.everStarted.store(false, ordering: .releasing)
            state.previewFIFO.clear()
        }

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
        // Re-grid: a BPM/BPI/sample-rate change moves the interval boundary, so the
        // first interval at the new grid re-locks up to a whole interval away. Re-open
        // the preview window on every channel (mirrors akaudio) so that gap is bridged
        // live too. The render thread reads everStarted; clearing the FIFO here is safe
        // (preview simply rebuffers before playing again).
        for (_, state) in channelStates {
            state.everStarted.store(false, ordering: .releasing)
            state.previewFIFO.clear()
        }
    }

    /// Preview ring capacity — ~5 s of stereo bounds the backlog at the engine rate.
    private var previewCapacityFrames: Int {
        max(8000, _sampleRate.load(ordering: .acquiring)) * 5
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

        // Ensure playback state exists for this channel
        if channelStates[key] == nil {
            let state = ChannelPlaybackState(channelKey: key, previewCapacityFrames: previewCapacityFrames)
            if let slot = userSlots[username] {
                state.gainSlot.store(slot, ordering: .releasing)
            }
            channelStates[key] = state
            stageRenderSnapshot()
        }

        // Arm the join-gap preview for this interval only while the channel hasn't yet
        // begun chained playout — otherwise the normal double-buffered chain handles it.
        var download = DownloadState(channelKey: key, data: Data())
        if let state = channelStates[key], !state.everStarted.load(ordering: .acquiring) {
            download.previewDecoder = OggVorbisPushdataDecoder()
        }
        activeDownloads[guid] = download
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

        // Join-gap preview: while this channel hasn't started chained playout, decode
        // the in-flight interval progressively (this new fragment only — the decoder
        // carries its own undecoded tail), resample to the engine rate, and push it
        // into the channel's live FIFO so the room is audible within ~a second instead
        // of a whole interval later. `download.data` still accumulates whole for the
        // proper decode at isEnd.
        if download.previewDecoder != nil, !data.isEmpty,
           let state = channelStates[download.channelKey] {
            if state.everStarted.load(ordering: .acquiring) {
                // Chain has taken over — retire the preview decoder for this interval.
                download.previewDecoder = nil
            } else if let decoder = download.previewDecoder {
                let src = decoder.feed(data)
                if !src.isEmpty {
                    let dstRate = _sampleRate.load(ordering: .acquiring)
                    let out = download.previewResampler.resample(
                        src, fromRate: decoder.sampleRate, toRate: dstRate)
                    if !out.isEmpty {
                        state.previewFIFO.append(out)
                    }
                }
            }
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

            job.playbackState.nextBuffer.withLock { $0 = buffer }

            decodeCount.wrappingAdd(1, ordering: .relaxed)

        } catch {
            logger.error("Failed to decode OGG: \(error)")
        }
    }

    /// Linear interpolation resampling (matches njclient.cpp quality)
    private func linearResample(_ input: [Float], fromRate: Int, toRate: Int) -> [Float] {
        let ratio = Double(fromRate) / Double(toRate)
        // Upsampling multiplies the sample count; a hostile low `fromRate` must not
        // turn a capped decode into a huge allocation. Nothing past the max interval
        // length is ever played, so truncating there loses no audio.
        let outputCount = min(Int(Double(input.count) / ratio), NJ_MAX_INTERVAL_SAMPLES)
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

        // Preview pacing (join-gap first-interval preview): buffer ~0.5 s before it
        // starts (senders' OGG pages arrive in bursts), and fade the retired preview
        // tail over ~0.25 s when the real chained interval takes over.
        let sr = _sampleRate.load(ordering: .acquiring)
        let previewPrebuf = max(1, sr / 2)
        let pfadeTotal = max(1, sr / 4)

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
                if channel.hasNextBuffer { anyReady = true; break }
            }
            if anyReady {
                for channel in renderChannels {
                    if let next = channel.takeNextBuffer() {
                        swapIn(channel, next, pfadeTotal: pfadeTotal)
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
                if let next = channel.takeNextBuffer() {
                    swapIn(channel, next, pfadeTotal: pfadeTotal)
                }
            }
        }

        // Update position
        pos = (pos + frameCount) % intervalLength
        samplePosition.store(pos, ordering: .releasing)

        // Mix each active channel: the chained (fully-decoded) interval when present,
        // plus the join-gap preview / its fade-out for a channel that hasn't yet locked
        // onto its chain.
        for channel in renderChannels {
            let slot = channel.gainSlot.load(ordering: .acquiring)
            guard slot >= 0, slot < userGains.count else { continue }
            let gain = userGains[slot]
            guard gain > 0.001 else { continue }

            var chPeak: Float = 0

            // ---- Chained playout (double-buffered, boundary-swapped) ----
            if let buffer = channel.currentBuffer {
                let ch = buffer.channels
                let samplesRead = buffer.read(into: temp, count: frameCount * ch)
                if samplesRead > 0 {
                    let framesRead = samplesRead / ch
                    samplesMixedCount.wrappingAdd(framesRead, ordering: .relaxed)
                    let peak = additiveMix(
                        source: temp, framesRead: framesRead, sourceChannels: ch,
                        into: outputBufferList, gain: gain)
                    if peak > chPeak { chPeak = peak }
                }
            }

            // ---- Join-gap preview / its fade-out (interleaved stereo FIFO) ----
            if !channel.everStarted.load(ordering: .acquiring) {
                // Live preview of the in-flight interval. Prebuffer before starting; a
                // dry spell re-arms the prebuffer.
                if !channel.previewPlaying,
                   channel.previewFIFO.availableFrames >= previewPrebuf {
                    channel.previewPlaying = true
                }
                if channel.previewPlaying {
                    let m = channel.previewFIFO.read(into: temp, maxFrames: frameCount)
                    if m > 0 {
                        let peak = additiveMix(
                            source: temp, framesRead: m, sourceChannels: 2,
                            into: outputBufferList, gain: gain)
                        if peak > chPeak { chPeak = peak }
                    }
                    if m < frameCount { channel.previewPlaying = false } // ran dry
                }
            } else if channel.pfadeRemaining > 0 {
                // The chain took over: fade the preview's unplayed tail out over the
                // fade window instead of hard-cutting (loop-point handover).
                let want = min(frameCount, channel.pfadeRemaining)
                let m = channel.previewFIFO.read(into: temp, maxFrames: want)
                if m > 0 {
                    // Pre-scale by a per-frame descending ramp, then additive-mix.
                    let base = channel.pfadeRemaining
                    for f in 0..<m {
                        let g = Float(base - f) / Float(pfadeTotal)
                        temp[f * 2] *= g
                        temp[f * 2 + 1] *= g
                    }
                    let peak = additiveMix(
                        source: temp, framesRead: m, sourceChannels: 2,
                        into: outputBufferList, gain: gain)
                    if peak > chPeak { chPeak = peak }
                    channel.pfadeRemaining -= m
                } else {
                    channel.pfadeRemaining = 0
                }
                if channel.pfadeRemaining <= 0 { channel.previewFIFO.clear() }
            }

            if let outPeaks, slot < 8, chPeak > outPeaks[slot] {
                outPeaks[slot] = chPeak
            }
        }
    }

    /// Swap a freshly decoded interval into a channel's chained playout (render thread).
    /// On the channel's very first chained interval this also retires the join-gap
    /// preview: mark it started and arm a short fade-out of whatever preview audio is
    /// still queued (the interval now replays in its proper slot — a loop-point handover).
    @inline(__always)
    private func swapIn(_ channel: ChannelPlaybackState, _ next: PlaybackBuffer, pfadeTotal: Int) {
        channel.currentBuffer = next
        bufferSwapCount.wrappingAdd(1, ordering: .relaxed)
        if !channel.everStarted.load(ordering: .acquiring) {
            channel.everStarted.store(true, ordering: .releasing)
            channel.previewPlaying = false
            let avail = channel.previewFIFO.availableFrames
            channel.pfadeRemaining = avail > 0 ? pfadeTotal : 0
            if channel.pfadeRemaining == 0 { channel.previewFIFO.clear() }
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
