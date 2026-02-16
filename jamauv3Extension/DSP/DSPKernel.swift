//
//  DSPKernel.swift
//  jamauv3Extension
//
//  Pure Swift DSP kernel - replaces C++ jamauv3ExtensionDSPKernel.
//

import Foundation
import AudioToolbox
import CoreMIDI
import Synchronization

/// Pure Swift DSP kernel, safe for use from render thread.
/// Uses only value types and avoids allocations in the process() hot path.
final class DSPKernel: @unchecked Sendable {

    // MARK: - Properties

    private(set) var sampleRate: Double = 44100.0
    private var userGains: [Float] = Array(repeating: 1.0, count: Int(jamauv3ExtensionNumUsers))

    private var noteEnvelope: Float = 1.0  // Initialize to 1.0 so audio passes through even without MIDI
    private var bypassed: Bool = false
    private var maxFramesToRender: AUAudioFrameCount = 1024

    /// Interval buffer for capturing local audio and encoding to OGG for NINJAM upload
    var intervalBuffer: IntervalBuffer?

    /// Peak amplitude trackers (render thread writes, diagnostic timer reads)
    let inputPeak = Atomic<UInt32>(0)   // Float bits stored as UInt32 for atomic access
    let outputPeak = Atomic<UInt32>(0)

    /// Remote audio mixer for decoding and playing back other users' audio
    var remoteAudioMixer: RemoteAudioMixer?

    var musicalContextBlock: AUHostMusicalContextBlock?
    var transportStateBlock: AUHostTransportStateBlock?
    var midiOutputEventBlock: AUMIDIEventListBlock?

    /// Host tempo (Double.bitPattern), render thread writes, main thread reads via diagnostic timer
    let hostTempo = Atomic<UInt64>(0)
    /// Host beat position (Double.bitPattern)
    let hostBeatPosition = Atomic<UInt64>(0)

    // Tempo sync: interval length correction
    private var baseIntervalLength: Int = 0
    private var ninjamBPI: Int = 0
    let correctedIntervalLength = Atomic<Int>(0)

    // Transport sync: snap interval position to DAW beat grid
    private var wasTransportMoving: Bool = false
    private var previousBeatPosition: Double = 0
    let needsInitialSnap = Atomic<Bool>(false)
    
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
    
    // MARK: - Tempo Sync

    /// Set interval config for drift correction. Called from main thread.
    func setIntervalConfig(bpi: Int, intervalLength: Int) {
        ninjamBPI = bpi
        baseIntervalLength = intervalLength
        correctedIntervalLength.store(intervalLength, ordering: .releasing)
        needsInitialSnap.store(true, ordering: .releasing)
    }

    /// Detect transport start, seek, or initial connect and snap interval position to DAW beat grid.
    /// Called from process() — RT-safe (atomics only, no allocations).
    private func snapToBeatGridIfNeeded(tempo: Double, beatPosition: Double, frameCount: Int) {
        // Determine transport state
        var transportMoving = false
        if let tsBlock = transportStateBlock {
            var flags = AUHostTransportStateFlags()
            _ = tsBlock(&flags, nil, nil, nil)
            transportMoving = flags.contains(.moving)
        } else {
            // Fallback: infer "moving" from beat position changing
            transportMoving = (beatPosition != previousBeatPosition)
        }

        // Detect snap triggers
        let transportStarted = transportMoving && !wasTransportMoving
        let initialSnap = needsInitialSnap.load(ordering: .acquiring)

        // Seek detection: beat position jumped more than expected for this buffer
        var seekDetected = false
        if transportMoving && wasTransportMoving && tempo > 0 {
            let beatsPerBuffer = (tempo / 60.0) * (Double(frameCount) / sampleRate)
            let actualJump = abs(beatPosition - previousBeatPosition)
            // Allow 2× expected jump as tolerance before considering it a seek
            if actualJump > beatsPerBuffer * 2.0 && actualJump > 0.5 {
                seekDetected = true
            }
        }

        wasTransportMoving = transportMoving
        previousBeatPosition = beatPosition

        guard transportStarted || seekDetected || initialSnap else { return }
        guard ninjamBPI > 0, baseIntervalLength > 0, tempo > 0 else { return }

        // Only snap when host BPM ≈ NINJAM BPM
        let ninjamBPM = Double(ninjamBPI) / (Double(baseIntervalLength) / sampleRate) * 60.0
        guard abs(tempo - ninjamBPM) < 0.5 else { return }

        // Compute where we should be within the interval
        let bpi = Double(ninjamBPI)
        let beatWithinInterval = beatPosition.truncatingRemainder(dividingBy: bpi)
        let positiveBeat = beatWithinInterval >= 0 ? beatWithinInterval : beatWithinInterval + bpi
        let samplesPerBeat = 60.0 / tempo * sampleRate
        let targetPosition = Int(positiveBeat * samplesPerBeat)
        let clampedTarget = max(0, min(targetPosition, baseIntervalLength - 1))

        intervalBuffer?.snapSamplePosition(clampedTarget)
        remoteAudioMixer?.snapSamplePosition(clampedTarget)

        // Also reset drift correction to base after a snap
        correctedIntervalLength.store(baseIntervalLength, ordering: .relaxed)

        if initialSnap {
            needsInitialSnap.store(false, ordering: .releasing)
        }
    }

    /// Compute drift between host beat position and NINJAM interval boundary.
    /// Adjusts correctedIntervalLength by up to ±256 samples.
    private func computeDriftCorrection(hostBPM: Double, hostBeat: Double) {
        guard ninjamBPI > 0, baseIntervalLength > 0, hostBPM > 0 else { return }

        // Derive NINJAM's effective BPM from its interval length
        let ninjamBPM = Double(ninjamBPI) / (Double(baseIntervalLength) / sampleRate) * 60.0
        // Only correct when host BPM ≈ NINJAM BPM
        guard abs(hostBPM - ninjamBPM) < 0.5 else {
            correctedIntervalLength.store(baseIntervalLength, ordering: .relaxed)
            return
        }

        // Expected: beat position should be a multiple of BPI at interval boundary
        let bpi = Double(ninjamBPI)
        let expectedBeat = (hostBeat / bpi).rounded() * bpi
        let driftBeats = hostBeat - expectedBeat
        let samplesPerBeat = 60.0 / hostBPM * sampleRate
        let driftSamples = Int(driftBeats * samplesPerBeat)

        // Clamp to ±256 samples to avoid transport jump artifacts
        let correction = max(-256, min(256, -driftSamples))
        correctedIntervalLength.store(baseIntervalLength + correction, ordering: .relaxed)
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
        
        // Read host musical context (RT-safe: stack vars + atomic stores)
        var tempo: Double = 0
        var beatPosition: Double = 0
        if let contextBlock = musicalContextBlock {
            _ = contextBlock(&tempo, nil, nil, &beatPosition, nil, nil)
            hostTempo.store(tempo.bitPattern, ordering: .relaxed)
            hostBeatPosition.store(beatPosition.bitPattern, ordering: .relaxed)
        }

        // Detect transport start/seek and snap interval position to DAW beat grid
        snapToBeatGridIfNeeded(tempo: tempo, beatPosition: beatPosition, frameCount: Int(frameCount))

        let currentIntervalLength = correctedIntervalLength.load(ordering: .acquiring)

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

        // Check if output buffer already has audio (host pre-fill for in-place processing?)
        if outputBuffers.count >= 1, let outData = outputBuffers[0].mData {
            let outFloats = outData.assumingMemoryBound(to: Float.self)
            var peak: Float = 0
            for i in 0..<Int(frameCount) {
                let s = abs(outFloats[i])
                if s > peak { peak = s }
            }
            let peakBits = peak.bitPattern
            let currentBits = outputPeak.load(ordering: .relaxed)
            if peakBits > currentBits {
                outputPeak.store(peakBits, ordering: .relaxed)
            }
        }

        // Capture raw input for NINJAM upload (before envelope processing)
        var boundaryHit = false
        if let intervalBuffer = intervalBuffer,
           inputBuffers.count >= 1,
           let inputDataL = inputBuffers[0].mData {
            let inputL = inputDataL.assumingMemoryBound(to: Float.self)
            var inputR: UnsafePointer<Float>?
            if inputBuffers.count >= 2, let inputDataR = inputBuffers[1].mData {
                inputR = UnsafePointer(inputDataR.assumingMemoryBound(to: Float.self))
            }

            // Track peak input amplitude for diagnostics
            var peak: Float = 0
            for i in 0..<Int(frameCount) {
                let s = abs(inputL[i])
                if s > peak { peak = s }
            }
            let peakBits = peak.bitPattern
            let currentBits = inputPeak.load(ordering: .relaxed)
            if peakBits > currentBits {
                inputPeak.store(peakBits, ordering: .relaxed)
            }

            boundaryHit = intervalBuffer.captureAudio(
                inputL: inputL, inputR: inputR,
                frameCount: Int(frameCount), intervalLength: currentIntervalLength)
        }

        // At interval boundary, compute drift correction for the NEXT interval
        if boundaryHit, tempo > 0 {
            computeDriftCorrection(hostBPM: tempo, hostBeat: beatPosition)
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

        // Mix remote users' audio into the output
        userGains.withUnsafeBufferPointer { gainsPtr in
            remoteAudioMixer?.mixInto(
                outputBufferList: outputBufferList,
                frameCount: Int(frameCount),
                userGains: gainsPtr,
                intervalLength: currentIntervalLength)
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
