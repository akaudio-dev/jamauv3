//
//  DSPKernel.swift
//  jamauv3Extension
//
//  Pure Swift DSP kernel - replaces C++ jamauv3ExtensionDSPKernel.
//

import Foundation
import AudioToolbox
import CoreMIDI

/// Pure Swift DSP kernel, safe for use from render thread.
/// Uses only value types and avoids allocations in the process() hot path.
final class DSPKernel: @unchecked Sendable {
    
    // MARK: - Properties

    private(set) var sampleRate: Double = 44100.0
    private var userGains: [Float] = Array(repeating: 0.75, count: Int(jamauv3ExtensionNumUsers))
    private var noteEnvelope: Float = 1.0  // Initialize to 1.0 so audio passes through even without MIDI
    private var bypassed: Bool = false
    private var maxFramesToRender: AUAudioFrameCount = 1024

    /// Interval buffer for capturing local audio and encoding to OGG for NINJAM upload
    var intervalBuffer: IntervalBuffer?
    
    var musicalContextBlock: AUHostMusicalContextBlock?
    var midiOutputEventBlock: AUMIDIEventListBlock?
    
    // MARK: - Initialization
    
    func initialize(inputChannelCount: Int, outputChannelCount: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    func deInitialize() {
        // Cleanup if needed
    }
    
    // MARK: - Bypass
    
    func isBypassed() -> Bool {
        return bypassed
    }
    
    func setBypass(_ shouldBypass: Bool) {
        bypassed = shouldBypass
    }
    
    // MARK: - Parameters
    
    func setParameter(address: AUParameterAddress, value: AUValue) {
        let index = Int(address - jamauv3ExtensionParameterAddress_userGainBase)
        if index >= 0 && index < Int(jamauv3ExtensionNumUsers) {
            userGains[index] = value
        }
    }

    func getParameter(address: AUParameterAddress) -> AUValue {
        let index = Int(address - jamauv3ExtensionParameterAddress_userGainBase)
        if index >= 0 && index < Int(jamauv3ExtensionNumUsers) {
            return AUValue(userGains[index])
        }
        return 0.0
    }
    
    // MARK: - Max Frames
    
    func maximumFramesToRender() -> AUAudioFrameCount {
        return maxFramesToRender
    }
    
    func setMaximumFramesToRender(_ maxFrames: AUAudioFrameCount) {
        maxFramesToRender = maxFrames
    }
    
    // MARK: - MIDI Protocol
    
    func audioUnitMIDIProtocol() -> MIDIProtocolID {
        return MIDIProtocolID._2_0
    }
    
    // MARK: - DSP Processing
    
    /// Core signal processing function.
    /// - Parameters:
    ///   - inputBufferList: Input audio buffer list
    ///   - outputBufferList: Output audio buffer list
    ///   - frameCount: Number of frames to process
    ///   - bufferStartTime: Sample time of buffer start
    func process(inputBufferList: UnsafePointer<AudioBufferList>,
                 outputBufferList: UnsafeMutablePointer<AudioBufferList>,
                 frameCount: AUAudioFrameCount,
                 bufferStartTime: AUEventSampleTime) {
        
        // Query musical context if available
        if let contextBlock = musicalContextBlock {
            _ = contextBlock(nil, nil, nil, nil, nil, nil)
        }
        
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

        // Capture raw input for NINJAM upload (before envelope processing)
        if let intervalBuffer = intervalBuffer,
           inputBuffers.count >= 1,
           let inputDataL = inputBuffers[0].mData {
            let inputL = inputDataL.assumingMemoryBound(to: Float.self)
            var inputR: UnsafePointer<Float>?
            if inputBuffers.count >= 2, let inputDataR = inputBuffers[1].mData {
                inputR = UnsafePointer(inputDataR.assumingMemoryBound(to: Float.self))
            }
            intervalBuffer.captureAudio(inputL: inputL, inputR: inputR, frameCount: Int(frameCount))
        }

        // Process each channel
        for channelIndex in 0..<min(inputBuffers.count, outputBuffers.count) {
            guard let inputData = inputBuffers[channelIndex].mData,
                  let outputData = outputBuffers[channelIndex].mData else {
                continue
            }
            
            let inputFloats = inputData.assumingMemoryBound(to: Float.self)
            let outputFloats = outputData.assumingMemoryBound(to: Float.self)
            
            // Apply envelope per sample (user gains will be applied when mixing remote streams)
            for frameIndex in 0..<Int(frameCount) {
                outputFloats[frameIndex] = inputFloats[frameIndex] * noteEnvelope
            }
        }
    }
    
    // MARK: - Event Handling
    
    func handleOneEvent(now: AUEventSampleTime, event: UnsafePointer<AURenderEvent>) {
        switch event.pointee.head.eventType {
        case .parameter:
            event.withMemoryRebound(to: AUParameterEvent.self, capacity: 1) { paramEvent in
                handleParameterEvent(now: now, event: paramEvent.pointee)
            }
            
        case .midiEventList:
            event.withMemoryRebound(to: AUMIDIEventList.self, capacity: 1) { midiEvent in
                handleMIDIEventList(now: now, event: midiEvent)
            }
            
        default:
            break
        }
    }
    
    func handleParameterEvent(now: AUEventSampleTime, event: AUParameterEvent) {
        setParameter(address: event.parameterAddress, value: event.value)
    }
    
    func handleMIDIEventList(now: AUEventSampleTime, event: UnsafePointer<AUMIDIEventList>) {
        // Process MIDI events
        var iterator = event.pointee.eventList.packet
        for _ in 0..<event.pointee.eventList.numPackets {
            processMIDIPacket(iterator)
            // Note: In real implementation, you'd iterate through the packet list
        }
    }
    
    private func processMIDIPacket(_ packet: MIDIEventPacket) {
        // Handle MIDI 2.0 voice messages
        // Check for note on/off to control envelope
        let words = packet.words
        let messageType = (words.0 >> 28) & 0xF
        
        if messageType == 0x4 { // Channel Voice Message (MIDI 2.0)
            let status = (words.0 >> 20) & 0xF
            switch status {
            case 0x8: // Note Off
                noteEnvelope = 0.0
            case 0x9: // Note On
                noteEnvelope = 1.0
            default:
                break
            }
        }
    }
}
