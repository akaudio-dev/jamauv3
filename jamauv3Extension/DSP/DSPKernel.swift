//
//  DSPKernel.swift
//  jamauv3Extension
//
//  Pure Swift DSP kernel - replaces C++ jamauv3ExtensionDSPKernel.
//

import Foundation
import AudioToolbox
import CoreAudio
import CoreMIDI
import Synchronization

/// Pure Swift DSP kernel, safe for use from render thread.
/// Uses only value types and avoids allocations in the process() hot path.
final class DSPKernel: @unchecked Sendable {

    // MARK: - Properties

    private(set) var sampleRate: Double = 44100.0

    static let numUsers = Int(jamauv3ExtensionNumUsers)

    /// Per-user gains as Float bit patterns. Written from the main thread
    /// (implementorValueObserver → setParameter) and from parameter events on
    /// the render thread; read every render callback.
    private let userGainBits: UnsafeMutablePointer<Atomic<UInt32>> = {
        let ptr = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: numUsers)
        for i in 0..<numUsers {
            (ptr + i).initialize(to: Atomic(Float(1.0).bitPattern))
        }
        return ptr
    }()
    /// Render-thread-local gains copy filled from userGainBits each callback.
    private let userGainScratch: UnsafeMutablePointer<Float> = {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: numUsers)
        ptr.initialize(repeating: 1.0, count: numUsers)
        return ptr
    }()

    private var noteEnvelope: Float = 1.0  // Initialize to 1.0 so audio passes through even without MIDI
    private var bypassed: Bool = false
    private var maxFramesToRender: AUAudioFrameCount = 1024

    /// NINJAM capture, remote mix, and Icecast playback components. Published
    /// from the main thread, snapshotted once per render callback. Mutex
    /// (os_unfair_lock, nanosecond hold) rather than plain vars: a non-atomic
    /// strong-reference load on the render thread racing the main thread's
    /// release is a data race with a use-after-free window.
    private struct Components {
        var intervalBuffer: IntervalBuffer?
        var remoteAudioMixer: RemoteAudioMixer?
        var icecastPlayer: IcecastStreamPlayer?
    }
    private let components = Mutex<Components>(Components())

    /// Interval buffer for capturing local audio and encoding to OGG for NINJAM upload
    var intervalBuffer: IntervalBuffer? {
        get { components.withLock { $0.intervalBuffer } }
        set { components.withLock { $0.intervalBuffer = newValue } }
    }

    /// Remote audio mixer for decoding and playing back other users' audio
    var remoteAudioMixer: RemoteAudioMixer? {
        get { components.withLock { $0.remoteAudioMixer } }
        set { components.withLock { $0.remoteAudioMixer = newValue } }
    }

    /// Icecast stream player for listen-only mode (server browser)
    var icecastPlayer: IcecastStreamPlayer? {
        get { components.withLock { $0.icecastPlayer } }
        set { components.withLock { $0.icecastPlayer = newValue } }
    }

    /// Peak amplitude trackers (render thread writes, diagnostic timer reads)
    let inputPeak = Atomic<UInt32>(0)   // Float bits stored as UInt32 for atomic access
    let outputPeak = Atomic<UInt32>(0)

    /// Per-user output peaks: render thread max-accumulates each callback,
    /// main thread exchanges at ~5 Hz. Float bit patterns in UInt32 atomics.
    private let userPeakStorage: UnsafeMutablePointer<Atomic<UInt32>> = {
        let ptr = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: numUsers)
        for i in 0..<numUsers {
            (ptr + i).initialize(to: Atomic(0))
        }
        return ptr
    }()
    /// Scratch buffer for collecting peaks within a single render callback (render thread only).
    private let userPeakScratch: UnsafeMutablePointer<Float> = {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: numUsers)
        ptr.initialize(repeating: 0, count: numUsers)
        return ptr
    }()

    /// Read and reset peak for a user slot (called from main thread ~5 Hz).
    func exchangeUserPeak(slot: Int) -> Float {
        guard slot >= 0, slot < Self.numUsers else { return 0 }
        return Float(bitPattern: userPeakStorage[slot].exchange(0, ordering: .relaxed))
    }

    var musicalContextBlock: AUHostMusicalContextBlock?
    var transportStateBlock: AUHostTransportStateBlock?
    var midiOutputEventBlock: AUMIDIEventListBlock?

    /// Host tempo (Double.bitPattern), render thread writes, main thread reads via diagnostic timer
    let hostTempo = Atomic<UInt64>(0)
    /// Host beat position (Double.bitPattern)
    let hostBeatPosition = Atomic<UInt64>(0)

    // Tempo sync: interval length correction.
    // Atomics: written from the main thread (setIntervalConfig) and the render
    // thread (boundary apply below), read every render callback.
    private let baseIntervalLength = Atomic<Int>(0)
    private let ninjamBPI = Atomic<Int>(0)
    let correctedIntervalLength = Atomic<Int>(0)

    // A mid-session BPM/BPI change staged until the next interval boundary.
    // Applying instantly mid-interval fires a spurious boundary and re-anchors
    // the interval clock to the message's arrival time instead of the server's
    // grid (njclient applies config changes at the boundary too).
    private let pendingBPI = Atomic<Int>(0)
    private let pendingIntervalLength = Atomic<Int>(0)
    private let hasPendingConfig = Atomic<Bool>(false)

    // Transport sync: snap interval position to DAW beat grid
    private var wasTransportMoving: Bool = false
    private var previousBeatPosition: Double = 0
    let needsInitialSnap = Atomic<Bool>(false)

    // MARK: - Metronome Config (main thread writes, render thread reads)

    let metronomeEnabled = Atomic<UInt8>(0)
    let metronomeBeat1Only = Atomic<UInt8>(0)

    // Metronome render state (render thread only)
    private var metronomeSamplePos: Int = 0
    private var lastMetronomeBeatIndex: Int = -1
    private var clickSamplesRemaining: Int = 0
    private var clickPhase: Double = 0.0
    private var clickOmega: Double = 0.0
    private var clickIsBeat1: Bool = false
    
    // MARK: - Initialization
    
    func initialize(inputChannelCount: Int, outputChannelCount: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    func deInitialize() {
        // Peak buffers are fixed-size (8 elements) and live for the kernel's lifetime.
        // Do NOT deallocate here — deInitialize is called on every deallocateRenderResources,
        // but the kernel persists (it's a `let` on the AU). Deallocating would create dangling
        // pointers when the host re-allocates render resources (e.g., sample rate change).
    }
    
    // MARK: - Bypass
    
    func isBypassed() -> Bool {
        return bypassed
    }
    
    func setBypass(_ shouldBypass: Bool) {
        bypassed = shouldBypass
    }
    
    // MARK: - Parameters
    
    /// Float bit pattern; set from main or render, read from main.
    private let needsAudioBits = Atomic<UInt32>(0)

    func setParameter(address: AUParameterAddress, value: AUValue) {
        if address == jamauv3ExtensionParameterAddress_needsAudio {
            needsAudioBits.store(value.bitPattern, ordering: .relaxed)
            return
        }
        let index = Int(address - jamauv3ExtensionParameterAddress_userGainBase)
        if index >= 0 && index < Self.numUsers {
            userGainBits[index].store(value.bitPattern, ordering: .relaxed)
        }
    }

    func getParameter(address: AUParameterAddress) -> AUValue {
        if address == jamauv3ExtensionParameterAddress_needsAudio {
            return AUValue(Float(bitPattern: needsAudioBits.load(ordering: .relaxed)))
        }
        let index = Int(address - jamauv3ExtensionParameterAddress_userGainBase)
        if index >= 0 && index < Self.numUsers {
            return AUValue(Float(bitPattern: userGainBits[index].load(ordering: .relaxed)))
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
    /// With `immediate` (session start / sample-rate change) the config applies
    /// now; otherwise it is staged and applied at the next interval boundary so
    /// the current interval completes on the old grid.
    func setIntervalConfig(bpi: Int, intervalLength: Int, immediate: Bool = false) {
        if immediate || baseIntervalLength.load(ordering: .relaxed) <= 0 {
            hasPendingConfig.store(false, ordering: .releasing)
            ninjamBPI.store(bpi, ordering: .relaxed)
            baseIntervalLength.store(intervalLength, ordering: .relaxed)
            correctedIntervalLength.store(intervalLength, ordering: .releasing)
        } else {
            pendingBPI.store(bpi, ordering: .relaxed)
            pendingIntervalLength.store(intervalLength, ordering: .relaxed)
            hasPendingConfig.store(true, ordering: .releasing)
        }
        needsInitialSnap.store(true, ordering: .releasing)
    }

    /// Detect transport start, seek, or initial connect and snap interval position to DAW beat grid.
    /// Called from process() — RT-safe (atomics only, no allocations).
    private func snapToBeatGridIfNeeded(tempo: Double, beatPosition: Double, frameCount: Int,
                                        capture: IntervalBuffer?, mixer: RemoteAudioMixer?) {
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
        let bpiValue = ninjamBPI.load(ordering: .relaxed)
        let baseLength = baseIntervalLength.load(ordering: .relaxed)
        guard bpiValue > 0, baseLength > 0, tempo > 0 else { return }

        // Only snap when host BPM ≈ NINJAM BPM
        let ninjamBPM = Double(bpiValue) / (Double(baseLength) / sampleRate) * 60.0
        guard abs(tempo - ninjamBPM) < 0.5 else { return }

        // Compute where we should be within the interval
        let bpi = Double(bpiValue)
        let beatWithinInterval = beatPosition.truncatingRemainder(dividingBy: bpi)
        let positiveBeat = beatWithinInterval >= 0 ? beatWithinInterval : beatWithinInterval + bpi
        let samplesPerBeat = 60.0 / tempo * sampleRate
        let targetPosition = Int(positiveBeat * samplesPerBeat)
        let clampedTarget = max(0, min(targetPosition, baseLength - 1))

        capture?.snapSamplePosition(clampedTarget)
        mixer?.snapSamplePosition(clampedTarget)
        snapMetronomePosition(clampedTarget)

        // Also reset drift correction to base after a snap
        correctedIntervalLength.store(baseLength, ordering: .relaxed)

        if initialSnap {
            needsInitialSnap.store(false, ordering: .releasing)
        }
    }

    /// Compute drift between host beat position and NINJAM interval boundary.
    /// Adjusts correctedIntervalLength by up to ±256 samples.
    private func computeDriftCorrection(hostBPM: Double, hostBeat: Double) {
        let bpiValue = ninjamBPI.load(ordering: .relaxed)
        let baseLength = baseIntervalLength.load(ordering: .relaxed)
        guard bpiValue > 0, baseLength > 0, hostBPM > 0 else { return }

        // Derive NINJAM's effective BPM from its interval length
        let ninjamBPM = Double(bpiValue) / (Double(baseLength) / sampleRate) * 60.0
        // Only correct when host BPM ≈ NINJAM BPM
        guard abs(hostBPM - ninjamBPM) < 0.5 else {
            correctedIntervalLength.store(baseLength, ordering: .relaxed)
            return
        }

        // Expected: beat position should be a multiple of BPI at interval boundary
        let bpi = Double(bpiValue)
        let expectedBeat = (hostBeat / bpi).rounded() * bpi
        let driftBeats = hostBeat - expectedBeat
        let samplesPerBeat = 60.0 / hostBPM * sampleRate
        let driftSamples = Int(driftBeats * samplesPerBeat)

        // Clamp to ±256 samples to avoid transport jump artifacts
        let correction = max(-256, min(256, -driftSamples))
        correctedIntervalLength.store(baseLength + correction, ordering: .relaxed)
    }

    // MARK: - Metronome

    /// Snap metronome position to align with beat grid (called from snapToBeatGridIfNeeded).
    private func snapMetronomePosition(_ newPosition: Int) {
        metronomeSamplePos = newPosition
        lastMetronomeBeatIndex = -1
        clickSamplesRemaining = 0
    }

    /// Mix metronome clicks into the output buffer. RT-safe: no allocations, no locks.
    /// When host tempo is available, derives beat timing from host beat position
    /// to stay locked to the DAW grid. Falls back to sample counting otherwise.
    private func mixMetronome(outputBufferList: UnsafeMutablePointer<AudioBufferList>,
                              frameCount: Int,
                              intervalLength: Int,
                              hostTempo: Double,
                              hostBeat: Double,
                              captureActive: Bool) {
        guard metronomeEnabled.load(ordering: .relaxed) != 0 else { return }
        let bpi = ninjamBPI.load(ordering: .relaxed)
        guard captureActive, bpi > 0, sampleRate > 0 else { return }

        let beat1Only = metronomeBeat1Only.load(ordering: .relaxed) != 0
        let clickDuration = Int(sampleRate) / 100  // ~10ms, matches njclient.cpp
        let gain: Float = 0.5

        let buffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        guard buffers.count >= 1,
              let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let outR = buffers.count >= 2 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        // Host-synced mode: derive beat timing from host beat position
        let useHostSync = hostTempo > 0
        let beatsPerSample = useHostSync ? (hostTempo / 60.0) / sampleRate : 0.0
        let bpiDouble = Double(bpi)

        // Fallback mode needs samplesPerBeat
        let samplesPerBeat = intervalLength > 0 ? intervalLength / bpi : 0

        for i in 0..<frameCount {
            var beatIndex: Int
            var triggerClick = false

            if useHostSync {
                // Compute beat position at this sample from host
                let currentBeat = hostBeat + Double(i) * beatsPerSample
                let beatInBPI = currentBeat.truncatingRemainder(dividingBy: bpiDouble)
                let positiveBeat = beatInBPI >= 0 ? beatInBPI : beatInBPI + bpiDouble
                beatIndex = Int(floor(positiveBeat)) % bpi

                // Detect beat boundary crossing
                if beatIndex != lastMetronomeBeatIndex {
                    lastMetronomeBeatIndex = beatIndex
                    triggerClick = true
                }
            } else {
                // Fallback: sample counting (no host tempo available)
                guard intervalLength > 0, samplesPerBeat > 0 else {
                    metronomeSamplePos = (metronomeSamplePos + 1) % max(intervalLength, 1)
                    continue
                }
                let pos = metronomeSamplePos
                beatIndex = pos / samplesPerBeat
                let posInBeat = pos % samplesPerBeat
                if posInBeat == 0 {
                    triggerClick = true
                }
                metronomeSamplePos = (pos + 1) % intervalLength
            }

            if triggerClick {
                let isBeat1 = (beatIndex == 0)
                let shouldClick = isBeat1 || !beat1Only

                if shouldClick {
                    clickSamplesRemaining = clickDuration
                    clickPhase = 0.0
                    clickIsBeat1 = isBeat1
                    let freq = isBeat1 ? 1000.0 : 800.0
                    clickOmega = 2.0 * .pi * freq / sampleRate
                }
            }

            // Generate click sample
            if clickSamplesRemaining > 0 {
                let t = Double(clickDuration - clickSamplesRemaining) / Double(clickDuration)
                let envelope = Float(exp(-3.0 * t))
                let amplitude: Float = clickIsBeat1 ? gain : gain * 0.25
                let sample = Float(sin(clickPhase)) * envelope * amplitude

                outL[i] += sample
                outR?[i] += sample

                clickPhase += clickOmega
                clickSamplesRemaining -= 1
            }
        }
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
        // Snapshot the audio components once per callback (brief os_unfair_lock)
        let (capture, mixer, icecast) = components.withLock {
            ($0.intervalBuffer, $0.remoteAudioMixer, $0.icecastPlayer)
        }

        // Read host musical context (RT-safe: stack vars + atomic stores)
        var tempo: Double = 0
        var beatPosition: Double = 0
        if let contextBlock = musicalContextBlock {
            _ = contextBlock(&tempo, nil, nil, &beatPosition, nil, nil)
            hostTempo.store(tempo.bitPattern, ordering: .relaxed)
            hostBeatPosition.store(beatPosition.bitPattern, ordering: .relaxed)
        }

        // Detect transport start/seek and snap interval position to DAW beat grid
        snapToBeatGridIfNeeded(tempo: tempo, beatPosition: beatPosition, frameCount: Int(frameCount),
                               capture: capture, mixer: mixer)

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
        if let intervalBuffer = capture,
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

        // At interval boundary, apply any staged BPM/BPI change, then compute
        // drift correction for the NEXT interval
        if boundaryHit {
            if hasPendingConfig.exchange(false, ordering: .acquiringAndReleasing) {
                let newBPI = pendingBPI.load(ordering: .relaxed)
                let newLength = pendingIntervalLength.load(ordering: .relaxed)
                ninjamBPI.store(newBPI, ordering: .relaxed)
                baseIntervalLength.store(newLength, ordering: .relaxed)
                correctedIntervalLength.store(newLength, ordering: .releasing)
            }
            metronomeSamplePos = 0
            lastMetronomeBeatIndex = -1
            if tempo > 0 {
                computeDriftCorrection(hostBPM: tempo, hostBeat: beatPosition)
            }
        }

        // Zero output buffers — only remote audio and Icecast will be heard.
        // Input was already captured by IntervalBuffer above for NINJAM upload.
        // We don't pass mic through to output to avoid feedback on speakers.
        for channelIndex in 0..<outputBuffers.count {
            guard let outputData = outputBuffers[channelIndex].mData else { continue }
            memset(outputData, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }

        // Mix metronome click track (host-synced when tempo available)
        mixMetronome(outputBufferList: outputBufferList,
                     frameCount: Int(frameCount),
                     intervalLength: currentIntervalLength,
                     hostTempo: tempo,
                     hostBeat: beatPosition,
                     captureActive: capture != nil)

        // Mix remote users' audio into the output
        // Reset per-user peak scratch buffer, collect peaks during mix, then publish to atomics
        let scratch = userPeakScratch
        let gains = userGainScratch
        for i in 0..<Self.numUsers {
            scratch[i] = 0
            gains[i] = Float(bitPattern: userGainBits[i].load(ordering: .relaxed))
        }
        mixer?.mixInto(
            outputBufferList: outputBufferList,
            frameCount: Int(frameCount),
            userGains: UnsafeBufferPointer(start: gains, count: Self.numUsers),
            outPeaks: scratch,
            intervalLength: currentIntervalLength)
        // Publish peaks from this render callback (max-accumulate into atomic storage;
        // the load/compare/store pair may lose an update racing exchangeUserPeak — a
        // one-tick meter blip, not a correctness issue)
        for i in 0..<Self.numUsers {
            let peakBits = scratch[i].bitPattern
            if peakBits > userPeakStorage[i].load(ordering: .relaxed) {
                userPeakStorage[i].store(peakBits, ordering: .relaxed)
            }
        }

        // Mix Icecast listener audio (server browser listen mode)
        icecast?.mixInto(outputBufferList: outputBufferList, frameCount: Int(frameCount))
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
        let iterator = event.pointee.eventList.packet
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
