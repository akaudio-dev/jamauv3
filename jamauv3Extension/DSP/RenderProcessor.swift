// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  RenderProcessor.swift
//  jamauv3Extension
//
//  Pure Swift render processor - replaces C++ AUProcessHelper.
//

import Foundation
import AudioToolbox
import AVFoundation
import CoreAudio

/// Handles the render loop and event processing for the Audio Unit.
final class RenderProcessor: @unchecked Sendable {
    
    private let kernel: DSPKernel
    private let inputBus: BufferedInputBus
    private var inputChannelCount: UInt32 = 0
    private var outputChannelCount: UInt32 = 0
    
    init(kernel: DSPKernel, inputBus: BufferedInputBus) {
        self.kernel = kernel
        self.inputBus = inputBus
    }
    
    func setChannelCount(input: UInt32, output: UInt32) {
        inputChannelCount = input
        outputChannelCount = output
    }
    
    /// Creates the internal render block for the Audio Unit.
    func internalRenderBlock() -> AUInternalRenderBlock {
        return { [kernel] (
            actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timestamp: UnsafePointer<AudioTimeStamp>,
            frameCount: AUAudioFrameCount,
            outputBusNumber: Int,
            outputData: UnsafeMutablePointer<AudioBufferList>,
            realtimeEventListHead: UnsafePointer<AURenderEvent>?,
            pullInputBlock: AURenderPullInputBlock?
        ) -> AUAudioUnitStatus in

            // Check frame count limit
            if frameCount > kernel.maximumFramesToRender() {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            // Pull input directly into the output buffer (in-place processing).
            // The host delivers input audio into the output buffer, and we process in-place.
            if let pullBlock = pullInputBlock {
                var pullFlags: AudioUnitRenderActionFlags = []
                let err = pullBlock(&pullFlags, timestamp, frameCount, 0, outputData)
                if err != noErr { return err }
            } else {
                // No input to pull: the host-provided buffer holds arbitrary memory.
                // Zero it so stale bytes are neither captured for upload nor played.
                let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                for i in 0..<buffers.count {
                    if let data = buffers[i].mData {
                        memset(data, 0, Int(buffers[i].mDataByteSize))
                    }
                }
            }

            // Process in-place: input and output are the same buffer
            Self.processWithEvents(
                kernel: kernel,
                inBufferList: outputData,
                outBufferList: outputData,
                timestamp: timestamp,
                frameCount: frameCount,
                events: realtimeEventListHead
            )

            return noErr
        }
    }
    
    /// Processes audio with interleaved event handling.
    private static func processWithEvents(
        kernel: DSPKernel,
        inBufferList: UnsafeMutablePointer<AudioBufferList>,
        outBufferList: UnsafeMutablePointer<AudioBufferList>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        events: UnsafePointer<AURenderEvent>?
    ) {
        // mSampleTime and event times are host-supplied; a NaN/infinite timestamp or an
        // event scheduled past Int64/UInt32 range must clamp, not trap the render thread.
        let sampleTime = timestamp.pointee.mSampleTime
        var now = AUEventSampleTime(sampleTime.isFinite && sampleTime.magnitude < 9.2e18 ? sampleTime : 0)
        var framesRemaining = frameCount
        var nextEvent = events

        while framesRemaining > 0 {
            // If no more events, process remaining frames and exit
            if nextEvent == nil {
                let frameOffset = frameCount - framesRemaining
                processSegment(
                    kernel: kernel,
                    inBufferList: inBufferList,
                    outBufferList: outBufferList,
                    now: now,
                    frameCount: framesRemaining,
                    frameOffset: frameOffset
                )
                return
            }

            // Calculate frames until next event, clamped to this render cycle
            let headEventTime = nextEvent!.pointee.head.eventSampleTime
            let framesThisSegment: AUAudioFrameCount
            if headEventTime <= now {
                framesThisSegment = 0
            } else {
                let (delta, overflow) = headEventTime.subtractingReportingOverflow(now)
                framesThisSegment = overflow ? framesRemaining : AUAudioFrameCount(min(delta, Int64(framesRemaining)))
            }

            // Process frames before the next event
            if framesThisSegment > 0 {
                let frameOffset = frameCount - framesRemaining
                processSegment(
                    kernel: kernel,
                    inBufferList: inBufferList,
                    outBufferList: outBufferList,
                    now: now,
                    frameCount: framesThisSegment,
                    frameOffset: frameOffset
                )

                framesRemaining -= framesThisSegment
                now += AUEventSampleTime(framesThisSegment)
            }
            
            // Handle all events at this time
            nextEvent = performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent)
        }
    }
    
    /// Processes a segment of audio frames starting at `frameOffset` within the buffers.
    /// The kernel always processes from a buffer's start, so the segment is expressed by
    /// temporarily advancing each mData pointer (and shrinking mDataByteSize to match,
    /// keeping downstream bounds checks honest), then restoring the saved descriptors.
    private static func processSegment(
        kernel: DSPKernel,
        inBufferList: UnsafeMutablePointer<AudioBufferList>,
        outBufferList: UnsafeMutablePointer<AudioBufferList>,
        now: AUEventSampleTime,
        frameCount: AUAudioFrameCount,
        frameOffset: AUAudioFrameCount
    ) {
        let byteOffset = Int(frameOffset) * MemoryLayout<Float>.size
        if byteOffset == 0 {
            kernel.process(
                inputBufferList: inBufferList,
                outputBufferList: outBufferList,
                frameCount: frameCount,
                bufferStartTime: now
            )
            return
        }

        let sameList = inBufferList == outBufferList
        let inBuffers = UnsafeMutableAudioBufferListPointer(inBufferList)
        let outBuffers = UnsafeMutableAudioBufferListPointer(outBufferList)
        let savedCount = inBuffers.count + (sameList ? 0 : outBuffers.count)

        // Stack scratch for the original buffer descriptors (tiny; RT-safe).
        withUnsafeTemporaryAllocation(of: AudioBuffer.self, capacity: savedCount) { saved in
            var idx = 0
            advance(inBuffers, by: byteOffset, saving: saved, at: &idx)
            if !sameList { advance(outBuffers, by: byteOffset, saving: saved, at: &idx) }

            kernel.process(
                inputBufferList: inBufferList,
                outputBufferList: outBufferList,
                frameCount: frameCount,
                bufferStartTime: now
            )

            idx = 0
            for i in 0..<inBuffers.count { inBuffers[i] = saved[idx]; idx += 1 }
            if !sameList {
                for i in 0..<outBuffers.count { outBuffers[i] = saved[idx]; idx += 1 }
            }
        }
    }

    private static func advance(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        by byteOffset: Int,
        saving saved: UnsafeMutableBufferPointer<AudioBuffer>,
        at idx: inout Int
    ) {
        for i in 0..<buffers.count {
            saved[idx] = buffers[i]
            idx += 1
            guard let base = buffers[i].mData else { continue }
            let step = min(byteOffset, Int(buffers[i].mDataByteSize))
            buffers[i].mData = base + step
            buffers[i].mDataByteSize -= UInt32(step)
        }
    }
    
    /// Handles all events occurring at or before the given time.
    private static func performAllSimultaneousEvents(
        kernel: DSPKernel,
        now: AUEventSampleTime,
        event: UnsafePointer<AURenderEvent>?
    ) -> UnsafePointer<AURenderEvent>? {
        var currentEvent = event
        
        while let evt = currentEvent {
            kernel.handleOneEvent(now: now, event: evt)
            
            // Move to next event (cast from mutable to immutable pointer)
            if let next = evt.pointee.head.next {
                currentEvent = UnsafePointer(next)
            } else {
                currentEvent = nil
            }
            
            // Stop if next event is in the future
            if let next = currentEvent, next.pointee.head.eventSampleTime > now {
                break
            }
        }
        
        return currentEvent
    }
}
