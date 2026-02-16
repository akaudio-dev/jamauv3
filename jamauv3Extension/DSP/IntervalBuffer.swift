//
//  IntervalBuffer.swift
//  jamauv3Extension
//
//  Captures local audio during NINJAM intervals, encodes to OGG Vorbis,
//  and streams upload messages to the server.
//
//  Threading model (3 threads):
//    Render thread → captureAudio() → CircularBuffer (SPSC)
//    Encoding thread → encodingLoop() → reads CircularBuffer, feeds OggVorbisStreamEncoder
//    Main thread → receives upload messages via callbacks
//

import Foundation
import Synchronization
import os.log

// MARK: - Interval Buffer

/// Captures audio from the render thread during NINJAM intervals,
/// incrementally encodes to OGG Vorbis, and delivers upload messages.
///
/// - Render thread calls `captureAudio()` — mixes stereo to mono, writes to SPSC buffer
/// - Background encoding thread reads from buffer, feeds encoder, dispatches upload messages
/// - Main thread receives protocol messages via callbacks
final class IntervalBuffer: @unchecked Sendable {

    // MARK: - Callbacks (set by integration code, invoked on @MainActor)

    var onUploadBegin: (@MainActor @Sendable (ClientUploadIntervalBegin) -> Void)?
    var onUploadWrite: (@MainActor @Sendable (ClientUploadIntervalWrite) -> Void)?
    var onIntervalBoundary: (@MainActor @Sendable () -> Void)?

    // MARK: - Configuration

    private let channelIndex: UInt8
    private let encoderQuality: Float

    // Atomic interval length — updated from main thread, read from render thread
    private let _intervalLength = Atomic<Int>(0)
    private let _sampleRate = Atomic<Int>(44100)

    // MARK: - Render Thread State

    /// SPSC lock-free buffer: render thread writes, encoding thread reads
    private let captureBuffer: CircularBuffer

    /// Sample position within current interval (render thread increments, resets at boundary)
    private let samplePosition = Atomic<Int>(0)

    /// Set by render thread when interval boundary is reached
    private let intervalBoundaryReached = Atomic<Bool>(false)

    /// Gate: only capture when active
    private let isCapturing = Atomic<Bool>(false)

    // MARK: - Encoding Thread State

    private var encodingThread: Thread?
    private let shouldStop = Atomic<Bool>(false)
    private var currentEncoder: OggVorbisStreamEncoder?
    private var currentGUID = Data(count: 16)

    private let logger = Logger(subsystem: "com.jamauv3", category: "IntervalBuffer")

    // MARK: - Initialization

    /// Create an IntervalBuffer.
    /// - Parameters:
    ///   - config: Initial interval configuration (BPM, BPI, sample rate)
    ///   - channelIndex: Local channel index for upload messages
    ///   - quality: Vorbis VBR quality (-0.1 to 1.0), default 0.1 ≈ 75 kbps
    init(config: IntervalConfig, channelIndex: UInt8 = 0, quality: Float = 0.1) {
        self.channelIndex = channelIndex
        self.encoderQuality = quality

        // Size buffer for 2× interval length to avoid overflow
        let intervalSamples = max(config.intervalLengthInSamples, 44100)
        self.captureBuffer = CircularBuffer(capacity: intervalSamples * 2 + 1)

        _intervalLength.store(config.intervalLengthInSamples, ordering: .releasing)
        _sampleRate.store(Int(config.sampleRate), ordering: .releasing)
    }

    // MARK: - Lifecycle

    /// Start capturing and encoding. Sends initial silence Begin message.
    func start() {
        guard !isCapturing.load(ordering: .acquiring) else { return }

        shouldStop.store(false, ordering: .releasing)
        captureBuffer.reset()
        samplePosition.store(0, ordering: .releasing)
        intervalBoundaryReached.store(false, ordering: .releasing)

        // Send initial silence for the first partial interval.
        // Don't create encoder yet — the first interval is always partial/silence.
        // The encoder will be created at the first interval boundary in finalizeAndStartNewInterval().
        // currentGUID stays as Data(count: 16) (all zeros) to match the silence GUID.
        let silenceBegin = ClientUploadIntervalBegin.silence(channelIndex: channelIndex)
        if let onUploadBegin = onUploadBegin {
            Task { @MainActor in onUploadBegin(silenceBegin) }
        }

        isCapturing.store(true, ordering: .releasing)

        // Start encoding thread
        let thread = Thread { [weak self] in
            self?.encodingLoop()
        }
        thread.name = "com.jamauv3.intervalEncoder"
        thread.qualityOfService = .userInitiated
        encodingThread = thread
        thread.start()

        logger.info("IntervalBuffer started")
    }

    /// Stop capturing and encoding. Finalizes current interval.
    func stop() {
        guard isCapturing.load(ordering: .acquiring) else { return }

        isCapturing.store(false, ordering: .releasing)
        shouldStop.store(true, ordering: .releasing)

        // Wait for encoding thread to finish (with timeout)
        let deadline = Date().addingTimeInterval(2.0)
        while encodingThread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        encodingThread = nil

        currentEncoder = nil
        logger.info("IntervalBuffer stopped")
    }

    /// Update interval configuration (called from main thread on BPM/BPI change)
    func updateConfig(_ config: IntervalConfig) {
        _intervalLength.store(config.intervalLengthInSamples, ordering: .releasing)
        _sampleRate.store(Int(config.sampleRate), ordering: .releasing)
    }

    // MARK: - Render Thread API

    /// Capture audio from the render thread. Mixes stereo to mono.
    /// Called from DSPKernel.process() — must be RT-safe (no locks, no allocations).
    ///
    /// - Parameters:
    ///   - inputL: Left channel samples
    ///   - inputR: Right channel samples (nil for mono input)
    ///   - frameCount: Number of frames
    ///   - intervalLength: Corrected interval length in samples (from DSPKernel drift correction)
    /// - Returns: `true` when an interval boundary was reached
    @discardableResult
    func captureAudio(inputL: UnsafePointer<Float>, inputR: UnsafePointer<Float>?,
                      frameCount: Int, intervalLength: Int = 0) -> Bool {
        guard isCapturing.load(ordering: .acquiring) else { return false }

        // Use passed intervalLength if nonzero, else fall back to internal config
        let effectiveLength = intervalLength > 0 ? intervalLength : _intervalLength.load(ordering: .acquiring)
        guard effectiveLength > 0 else { return false }

        // Mix stereo to mono using stack allocation (RT-safe)
        withUnsafeTemporaryAllocation(of: Float.self, capacity: frameCount) { monoBuffer in
            let mono = monoBuffer.baseAddress!

            if let inputR = inputR {
                for i in 0..<frameCount {
                    mono[i] = (inputL[i] + inputR[i]) * 0.5
                }
            } else {
                mono.update(from: inputL, count: frameCount)
            }

            captureBuffer.write(from: mono, count: frameCount)
        }

        // Count samples and detect interval boundary
        var pos = samplePosition.load(ordering: .acquiring)
        pos += frameCount
        var hitBoundary = false
        if pos >= effectiveLength {
            pos = pos % effectiveLength
            intervalBoundaryReached.store(true, ordering: .releasing)
            hitBoundary = true
        }
        samplePosition.store(pos, ordering: .releasing)
        return hitBoundary
    }

    // MARK: - Encoding Thread

    /// Background encoding loop. Polls capture buffer at ~100 Hz.
    private func encodingLoop() {
        let chunkSize = 4096
        var readBuffer = [Float](repeating: 0, count: chunkSize)

        while !shouldStop.load(ordering: .acquiring) {
            drainCaptureBuffer(into: &readBuffer, chunkSize: chunkSize)

            // Check for interval boundary
            if intervalBoundaryReached.exchange(false, ordering: .acquiringAndReleasing) {
                finalizeAndStartNewInterval()
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        // On stop: drain remaining samples, finalize encoder, send EOS
        drainCaptureBuffer(into: &readBuffer, chunkSize: chunkSize)
        finishCurrentInterval()
    }

    /// Read all available samples from capture buffer, encode, and send.
    /// Reuses the caller's readBuffer to avoid allocation.
    private func drainCaptureBuffer(into readBuffer: inout [Float], chunkSize: Int) {
        var remaining = captureBuffer.availableToRead
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            let actualRead = readBuffer.withUnsafeMutableBufferPointer { ptr in
                captureBuffer.read(into: ptr.baseAddress!, count: toRead)
            }
            guard actualRead > 0 else { break }
            remaining -= actualRead

            guard let encoder = currentEncoder else { continue }
            do {
                let encoded = try readBuffer.withUnsafeBufferPointer { ptr in
                    try encoder.write(samples: ptr.baseAddress!, frameCount: actualRead)
                }
                if !encoded.isEmpty {
                    sendWrite(audioData: encoded, isEnd: false)
                }
            } catch {
                logger.error("Encoding error: \(error)")
            }
        }
    }

    /// Finish the current encoder and send the end-of-interval marker.
    private func finishCurrentInterval() {
        if let encoder = currentEncoder {
            do {
                let finalData = try encoder.finish()
                if !finalData.isEmpty {
                    sendWrite(audioData: finalData, isEnd: false)
                }
            } catch {
                logger.error("Error finishing encoder: \(error)")
            }
        }
        sendWrite(audioData: Data(), isEnd: true)
    }

    /// Finalize current interval encoder, start a new one.
    private func finalizeAndStartNewInterval() {
        finishCurrentInterval()
        createNewEncoder()

        // Send Begin for new interval
        let beginMsg = ClientUploadIntervalBegin(
            guid: currentGUID, estimatedSize: 0,
            fourCC: ClientUploadIntervalBegin.oggVorbisFourCC,
            channelIndex: channelIndex
        )
        if let onUploadBegin = onUploadBegin {
            Task { @MainActor in onUploadBegin(beginMsg) }
        }

        // Notify UI of interval boundary
        if let onIntervalBoundary = onIntervalBoundary {
            Task { @MainActor in onIntervalBoundary() }
        }
    }

    // MARK: - Helpers

    /// Create a new encoder and GUID for the next interval.
    private func createNewEncoder() {
        let sampleRate = _sampleRate.load(ordering: .acquiring)
        currentGUID = Self.randomGUID()
        do {
            currentEncoder = try OggVorbisStreamEncoder(
                sampleRate: sampleRate, channels: 1, quality: encoderQuality
            )
        } catch {
            logger.error("Failed to create encoder: \(error)")
            currentEncoder = nil
        }
    }

    /// Send an upload write message via callback (dispatches to main thread).
    private func sendWrite(audioData: Data, isEnd: Bool) {
        let msg = ClientUploadIntervalWrite(
            guid: currentGUID, flags: isEnd ? 1 : 0, audioData: audioData
        )
        if let onUploadWrite = onUploadWrite {
            Task { @MainActor in onUploadWrite(msg) }
        }
    }

    /// Generate a random 16-byte GUID.
    static func randomGUID() -> Data {
        var data = Data(count: 16)
        data.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        }
        return data
    }
}
