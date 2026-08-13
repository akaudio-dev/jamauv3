// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

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
        // A non-positive capacity would make the available-space math negative
        // and bypass the == 0 guards below.
        precondition(capacity > 0, "CircularBuffer capacity must be positive")
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

    /// Clears all data from the buffer.
    ///
    /// Only safe while no concurrent reader or writer is active (e.g. before
    /// the buffer is published to the render thread): storing both indices
    /// from a third thread races a concurrent read() and can leave
    /// readIndex logically ahead of writeIndex — availableToRead then wraps
    /// and up to a full ring of stale samples replays.
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
        guard offset >= 0, offset < available else { return 0 }

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
