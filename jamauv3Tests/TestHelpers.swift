//
//  TestHelpers.swift
//  jamauv3Tests
//
//  Shared test utilities: memory measurement, AudioBufferList construction.
//

import Foundation
import AudioToolbox

// MARK: - Memory Measurement

/// Measure resident memory of the current process.
func residentMemoryBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

/// Run a closure in two equal phases after warmup, return memory growth per phase.
/// If there's a real leak, both phases show similar growth. If it's allocator ramp-up,
/// the second phase shows much less growth.
func measureMemoryGrowth(warmup: Int, iterations: Int, body: () throws -> Void) rethrows -> (warmupToMid: Int, midToEnd: Int) {
    for _ in 0..<warmup {
        try autoreleasepool { try body() }
    }
    let after_warmup = residentMemoryBytes()

    for _ in 0..<iterations {
        try autoreleasepool { try body() }
    }
    let after_phase1 = residentMemoryBytes()

    for _ in 0..<iterations {
        try autoreleasepool { try body() }
    }
    let after_phase2 = residentMemoryBytes()

    return (
        warmupToMid: after_phase1 - after_warmup,
        midToEnd: after_phase2 - after_phase1
    )
}

// MARK: - AudioBufferList Construction

/// Creates a temporary mutable stereo AudioBufferList from two Float buffers and passes it to a closure.
func withUnsafeMutableAudioBufferList(
    lBuf: UnsafeMutableBufferPointer<Float>,
    rBuf: UnsafeMutableBufferPointer<Float>,
    body: (UnsafeMutablePointer<AudioBufferList>) -> Void
) {
    let channelCount = 2
    let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * (channelCount - 1)
    let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ablPtr.deallocate() }

    let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
    abl.pointee.mNumberBuffers = UInt32(channelCount)

    let buffers = UnsafeMutableAudioBufferListPointer(abl)

    buffers[0] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(lBuf.count * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(lBuf.baseAddress!)
    )
    buffers[1] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(rBuf.count * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(rBuf.baseAddress!)
    )

    body(abl)
}
