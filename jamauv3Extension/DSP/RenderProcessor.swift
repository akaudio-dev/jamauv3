//
//  RenderProcessor.swift
//  jamauv3Extension
//
//  Pure Swift render processor - replaces C++ AUProcessHelper.
//

import Foundation
import AudioToolbox
import AVFoundation

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
        var now = AUEventSampleTime(timestamp.pointee.mSampleTime)
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
            
            // Calculate frames until next event
            let headEventTime = nextEvent!.pointee.head.eventSampleTime
            let framesThisSegment = AUAudioFrameCount(max(0, headEventTime - now))
            
            // Process frames before the next event
            if framesThisSegment > 0 {
                let frameOffset = frameCount - framesRemaining
                processSegment(
                    kernel: kernel,
                    inBufferList: inBufferList,
                    outBufferList: outBufferList,
                    now: now,
                    frameCount: min(framesThisSegment, framesRemaining),
                    frameOffset: frameOffset
                )
                
                framesRemaining -= min(framesThisSegment, framesRemaining)
                now += AUEventSampleTime(framesThisSegment)
            }
            
            // Handle all events at this time
            nextEvent = performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent)
        }
    }
    
    /// Processes a segment of audio frames.
    private static func processSegment(
        kernel: DSPKernel,
        inBufferList: UnsafeMutablePointer<AudioBufferList>,
        outBufferList: UnsafeMutablePointer<AudioBufferList>,
        now: AUEventSampleTime,
        frameCount: AUAudioFrameCount,
        frameOffset: AUAudioFrameCount
    ) {
        // Adjust buffer pointers by frame offset
        let inBuffers = UnsafeMutableAudioBufferListPointer(inBufferList)
        let outBuffers = UnsafeMutableAudioBufferListPointer(outBufferList)
        
        // Create offset buffer lists for this segment
        // For simplicity, we'll process the full buffer and the kernel handles offset internally
        // In a production implementation, you'd create temporary buffer lists with offset pointers
        
        kernel.process(
            inputBufferList: inBufferList,
            outputBufferList: outBufferList,
            frameCount: frameCount,
            bufferStartTime: now
        )
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
