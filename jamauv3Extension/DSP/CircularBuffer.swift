//
//  CircularBuffer.swift
//  jamauv3Extension
//
//  Lock-free circular buffer for real-time audio processing.
//  Safe for single-producer, single-consumer scenarios (one write thread, one read thread).
//

import Foundation
import AudioToolbox
import Synchronization

/// Thread-safe circular buffer for audio samples.
/// Uses atomic operations for lock-free read/write on render thread.
final class CircularBuffer: @unchecked Sendable {

    // MARK: - Properties

    private let capacity: Int
    private var buffer: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// Number of frames that can be stored in the buffer
    var frameCapacity: Int { capacity }

    // MARK: - Initialization

    /// Creates a circular buffer with the specified capacity.
    /// - Parameter capacity: Maximum number of samples the buffer can hold
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0.0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Public API

    /// Returns the number of samples available to read
    var availableToRead: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        if write >= read {
            return write - read
        } else {
            return capacity - read + write
        }
    }

    /// Returns the number of samples available to write
    var availableToWrite: Int {
        // Leave one sample empty to distinguish full from empty
        return capacity - availableToRead - 1
    }

    /// Returns true if the buffer is empty
    var isEmpty: Bool {
        writeIndex.load(ordering: .acquiring) == readIndex.load(ordering: .acquiring)
    }

    /// Clears all data from the buffer
    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
    }

    /// Writes samples to the buffer.
    /// - Parameters:
    ///   - source: Pointer to samples to write
    ///   - count: Number of samples to write
    /// - Returns: Number of samples actually written (may be less than requested if buffer is full)
    @discardableResult
    func write(from source: UnsafePointer<Float>, count: Int) -> Int {
        let available = availableToWrite
        let toWrite = min(count, available)

        if toWrite == 0 { return 0 }

        let write = writeIndex.load(ordering: .acquiring)

        // Write in up to two chunks (may wrap around)
        let firstChunkSize = min(toWrite, capacity - write)
        let secondChunkSize = toWrite - firstChunkSize

        // First chunk
        buffer.advanced(by: write).update(from: source, count: firstChunkSize)

        // Second chunk (wrap around)
        if secondChunkSize > 0 {
            buffer.update(from: source.advanced(by: firstChunkSize), count: secondChunkSize)
        }

        // Update write index
        let newWrite = (write + toWrite) % capacity
        writeIndex.store(newWrite, ordering: .releasing)

        return toWrite
    }

    /// Writes samples from an array.
    /// - Parameter samples: Array of samples to write
    /// - Returns: Number of samples actually written
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        return samples.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return 0 }
            return write(from: baseAddress, count: samples.count)
        }
    }

    /// Reads samples from the buffer.
    /// - Parameters:
    ///   - destination: Pointer to write samples to
    ///   - count: Number of samples to read
    /// - Returns: Number of samples actually read (may be less than requested if buffer is empty)
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let available = availableToRead
        let toRead = min(count, available)

        if toRead == 0 { return 0 }

        let read = readIndex.load(ordering: .acquiring)

        // Read in up to two chunks (may wrap around)
        let firstChunkSize = min(toRead, capacity - read)
        let secondChunkSize = toRead - firstChunkSize

        // First chunk
        destination.update(from: buffer.advanced(by: read), count: firstChunkSize)

        // Second chunk (wrap around)
        if secondChunkSize > 0 {
            destination.advanced(by: firstChunkSize).update(from: buffer, count: secondChunkSize)
        }

        // Update read index
        let newRead = (read + toRead) % capacity
        readIndex.store(newRead, ordering: .releasing)

        return toRead
    }

    /// Reads samples into an array.
    /// - Parameter count: Maximum number of samples to read
    /// - Returns: Array of samples read
    func read(count: Int) -> [Float] {
        let available = availableToRead
        let toRead = min(count, available)

        var result = [Float](repeating: 0.0, count: toRead)
        result.withUnsafeMutableBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            _ = read(into: baseAddress, count: toRead)
        }

        return result
    }

    /// Discards samples from the read position without copying them.
    /// - Parameter count: Number of samples to discard
    /// - Returns: Number of samples actually discarded
    @discardableResult
    func discard(count: Int) -> Int {
        let available = availableToRead
        let toDiscard = min(count, available)

        if toDiscard == 0 { return 0 }

        let read = readIndex.load(ordering: .acquiring)
        let newRead = (read + toDiscard) % capacity
        readIndex.store(newRead, ordering: .releasing)

        return toDiscard
    }

    /// Peeks at samples without advancing the read position.
    /// - Parameters:
    ///   - destination: Pointer to write samples to
    ///   - count: Number of samples to peek
    ///   - offset: Offset from current read position
    /// - Returns: Number of samples actually read
    @discardableResult
    func peek(into destination: UnsafeMutablePointer<Float>, count: Int, offset: Int = 0) -> Int {
        let available = availableToRead
        guard offset < available else { return 0 }

        let toPeek = min(count, available - offset)
        if toPeek == 0 { return 0 }

        let read = readIndex.load(ordering: .acquiring)
        let peekStart = (read + offset) % capacity

        // Peek in up to two chunks (may wrap around)
        let firstChunkSize = min(toPeek, capacity - peekStart)
        let secondChunkSize = toPeek - firstChunkSize

        // First chunk
        destination.update(from: buffer.advanced(by: peekStart), count: firstChunkSize)

        // Second chunk (wrap around)
        if secondChunkSize > 0 {
            destination.advanced(by: firstChunkSize).update(from: buffer, count: secondChunkSize)
        }

        return toPeek
    }
}

// MARK: - Multi-Channel Circular Buffer

/// Circular buffer for multi-channel audio.
/// Stores channels non-interleaved for efficient per-channel processing.
final class MultiChannelCircularBuffer: @unchecked Sendable {

    private let channelBuffers: [CircularBuffer]
    let channelCount: Int
    let frameCapacity: Int

    /// Creates a multi-channel circular buffer.
    /// - Parameters:
    ///   - channels: Number of channels
    ///   - capacity: Capacity in frames (samples per channel)
    init(channels: Int, capacity: Int) {
        self.channelCount = channels
        self.frameCapacity = capacity
        self.channelBuffers = (0..<channels).map { _ in CircularBuffer(capacity: capacity) }
    }

    /// Number of frames available to read (minimum across all channels)
    var availableToRead: Int {
        channelBuffers.map { $0.availableToRead }.min() ?? 0
    }

    /// Number of frames available to write (minimum across all channels)
    var availableToWrite: Int {
        channelBuffers.map { $0.availableToWrite }.min() ?? 0
    }

    var isEmpty: Bool {
        channelBuffers.allSatisfy { $0.isEmpty }
    }

    func reset() {
        channelBuffers.forEach { $0.reset() }
    }

    /// Writes interleaved samples to all channels.
    /// - Parameters:
    ///   - source: Pointer to interleaved samples
    ///   - frameCount: Number of frames to write
    /// - Returns: Number of frames actually written
    @discardableResult
    func writeInterleaved(from source: UnsafePointer<Float>, frameCount: Int) -> Int {
        let available = availableToWrite
        let framesToWrite = min(frameCount, available)

        if framesToWrite == 0 { return 0 }

        // De-interleave into temporary buffers
        var channelData = [[Float]](repeating: [], count: channelCount)
        for ch in 0..<channelCount {
            channelData[ch].reserveCapacity(framesToWrite)
        }

        for frame in 0..<framesToWrite {
            for ch in 0..<channelCount {
                channelData[ch].append(source[frame * channelCount + ch])
            }
        }

        // Write to each channel buffer
        for ch in 0..<channelCount {
            channelBuffers[ch].write(channelData[ch])
        }

        return framesToWrite
    }

    /// Writes non-interleaved samples to all channels.
    /// - Parameters:
    ///   - channelPointers: Array of pointers to per-channel samples
    ///   - frameCount: Number of frames to write
    /// - Returns: Number of frames actually written
    @discardableResult
    func write(channelPointers: [UnsafePointer<Float>], frameCount: Int) -> Int {
        guard channelPointers.count == channelCount else { return 0 }

        let available = availableToWrite
        let framesToWrite = min(frameCount, available)

        if framesToWrite == 0 { return 0 }

        for ch in 0..<channelCount {
            channelBuffers[ch].write(from: channelPointers[ch], count: framesToWrite)
        }

        return framesToWrite
    }

    /// Reads non-interleaved samples from all channels.
    /// - Parameters:
    ///   - channelPointers: Array of pointers to write per-channel samples to
    ///   - frameCount: Number of frames to read
    /// - Returns: Number of frames actually read
    @discardableResult
    func read(channelPointers: [UnsafeMutablePointer<Float>], frameCount: Int) -> Int {
        guard channelPointers.count == channelCount else { return 0 }

        let available = availableToRead
        let framesToRead = min(frameCount, available)

        if framesToRead == 0 { return 0 }

        for ch in 0..<channelCount {
            channelBuffers[ch].read(into: channelPointers[ch], count: framesToRead)
        }

        return framesToRead
    }

    /// Reads interleaved samples from all channels.
    /// - Parameters:
    ///   - destination: Pointer to write interleaved samples to
    ///   - frameCount: Number of frames to read
    /// - Returns: Number of frames actually read
    @discardableResult
    func readInterleaved(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let available = availableToRead
        let framesToRead = min(frameCount, available)

        if framesToRead == 0 { return 0 }

        // Read from each channel into temporary buffers
        var channelData = [[Float]](repeating: [], count: channelCount)
        for ch in 0..<channelCount {
            channelData[ch] = channelBuffers[ch].read(count: framesToRead)
        }

        // Interleave into destination
        for frame in 0..<framesToRead {
            for ch in 0..<channelCount {
                destination[frame * channelCount + ch] = channelData[ch][frame]
            }
        }

        return framesToRead
    }

    /// Discards frames from all channels.
    /// - Parameter frameCount: Number of frames to discard
    /// - Returns: Number of frames actually discarded
    @discardableResult
    func discard(frameCount: Int) -> Int {
        let available = availableToRead
        let framesToDiscard = min(frameCount, available)

        if framesToDiscard == 0 { return 0 }

        for ch in 0..<channelCount {
            channelBuffers[ch].discard(count: framesToDiscard)
        }

        return framesToDiscard
    }
}
