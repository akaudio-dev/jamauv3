//
//  SimplePlayEngine.swift
//  jamauv3
//

import Foundation
import CoreAudio
import CoreAudioKit
import AVFoundation
@preconcurrency import AVFAudio
import os
import Synchronization

private let log = Logger(subsystem: "jamauv3.com.jamauv3", category: "SimplePlayEngine")

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension AVAudioUnit {

    var wantsAudioInput: Bool {
        let componentType = self.auAudioUnit.componentDescription.componentType
        return componentType == kAudioUnitType_MusicEffect || componentType == kAudioUnitType_Effect
    }

    static fileprivate func findComponent(type: String, subType: String, manufacturer: String) -> AVAudioUnitComponent? {
        let description = AudioComponentDescription(componentType: type.fourCharCode!,
                                                    componentSubType: subType.fourCharCode!,
                                                    componentManufacturer: manufacturer.fourCharCode!,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: description).first
    }

    fileprivate func loadAudioUnitViewController() async -> ViewController? {
        let viewController = await auAudioUnit.requestViewController()
        if #available(macOS 13.0, iOS 16.0, *) {
            if viewController == nil {
                let genericViewController = AUGenericViewController()
                await MainActor.run { genericViewController.auAudioUnit = self.auAudioUnit }
                return genericViewController
            }
        }
        return viewController
    }
}

/// Hosts an AUv3 audio unit, routing microphone input through it to the output.
@MainActor
@Observable
public class SimplePlayEngine {

    var avAudioUnit: AVAudioUnit?

    private let engine = AVAudioEngine()
    private(set) var isPlaying = false

    // MIDI: receive from CoreMIDI, forward to the AU's scheduleMIDIEventListBlock.
    // Protected by Mutex — written on @MainActor, read from CoreMIDI thread.
    private let _scheduleMIDIEventListBlock = Mutex<AUMIDIEventListBlock?>(nil)
    // Fallback for instruments that only support MIDI 1.0 scheduleMIDIEventBlock.
    private let _scheduleMIDIEventBlock = Mutex<AUScheduleMIDIEventBlock?>(nil)
    private let midiOutBlock: AUMIDIOutputEventBlock = { _, _, _, _ in return noErr }

    #if os(iOS) || os(visionOS)
    /// Currently loaded AUv3 instrument (input source for instrument mode).
    var instrumentAU: AVAudioUnit?
    #endif

    public init() {
        setupMIDI()
    }

    /// Check if the system has an audio input device before accessing engine.inputNode.
    private static func hasAudioInput() -> Bool {
        #if os(iOS) || os(visionOS)
        return AVAudioSession.sharedInstance().isInputAvailable
        #else
        return hasAudioDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        #endif
    }

    /// Check if the system has an audio output device.
    private static func hasAudioOutput() -> Bool {
        #if os(iOS) || os(visionOS)
        return true  // iOS always has output
        #else
        return hasAudioDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        #endif
    }

    #if os(macOS)
    private static func hasAudioDevice(selector: AudioObjectPropertySelector) -> Bool {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 && deviceID != kAudioObjectUnknown
    }
    #endif

    private func setupMIDI() {
        let ok = MIDIManager.shared.setupPort(midiProtocol: MIDIProtocolID._2_0, receiveBlock: { [weak self] eventList, _ in
            guard let self else { return }
            let block = self._scheduleMIDIEventListBlock.withLock { $0 }
            if block != nil {
                _ = block?(AUEventSampleTimeImmediate, 0, eventList)
            } else {
                // Fallback: convert MIDI 2.0 event list to MIDI 1.0 calls
                let midi1Block = self._scheduleMIDIEventBlock.withLock { $0 }
                if let midi1Block {
                    let list = eventList.pointee
                    withUnsafePointer(to: list) { listPtr in
                        var packetPtr: UnsafePointer<MIDIEventPacket>? = nil
                        for i in 0..<list.numPackets {
                            if i == 0 {
                                packetPtr = UnsafePointer(
                                    UnsafeRawPointer(listPtr)
                                        .advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
                                        .assumingMemoryBound(to: MIDIEventPacket.self))
                            } else if let current = packetPtr {
                                packetPtr = UnsafePointer(MIDIEventPacketNext(current))
                            }
                            guard let pkt = packetPtr else { break }
                            let wordCount = Int(pkt.pointee.wordCount)
                            guard wordCount > 0 else { continue }
                            let first = pkt.pointee.words.0
                            // Extract MIDI 1.0 from Universal MIDI Packet
                            let status = UInt8((first >> 16) & 0xFF)
                            let data1 = UInt8((first >> 8) & 0xFF)
                            let data2 = UInt8(first & 0xFF)
                            midi1Block(AUEventSampleTimeImmediate, 0, 3, [status, data1, data2])
                        }
                    }
                }
            }
        })
        if ok {
            log.notice("CoreMIDI setup succeeded")
        } else {
            log.error("CoreMIDI setup failed")
        }
    }

    // MARK: - Load

    func initComponent(type: String, subType: String, manufacturer: String) async -> ViewController? {
        reset() 

        guard let component = AVAudioUnit.findComponent(type: type, subType: subType, manufacturer: manufacturer) else {
            log.error("AU component not found: type=\(type, privacy: .public) subType=\(subType, privacy: .public) mfr=\(manufacturer, privacy: .public)")
            return nil
        }

        do {
            // Load in-process for the test host app — avoids XPC rate-limit noise
            // and the NSRemoteView overhead of out-of-process hosting.
            // Real DAW hosts will load out-of-process with their own sandboxing.
            // Note: .loadInProcess is unavailable on iOS; [] lets the system decide
            // (typically in-process for the host's own embedded extension).
            #if os(macOS)
            let options: AudioComponentInstantiationOptions = .loadInProcess
            #else
            let options: AudioComponentInstantiationOptions = []
            #endif
            let audioUnit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription, options: options)
            self.avAudioUnit = audioUnit
            return await audioUnit.loadAudioUnitViewController()
        } catch {
            log.error("Failed to instantiate AU component: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Needs Audio (iOS deferred engine start)

    private let needsAudioParameterAddress: AUParameterAddress = 100
    private var needsAudioObserverToken: AUParameterObserverToken?
    private var needsAudioParam: AUParameter?
    private var stopDebounceTask: Task<Void, Never>?

    /// Wire the audio graph without starting the engine.
    /// Used on iOS to prepare the graph while deferring engine start for battery savings.
    func connectOnly() {
        guard let audioUnit = avAudioUnit else {
            log.error("connectOnly: no avAudioUnit")
            return
        }
        guard Self.hasAudioOutput() else {
            log.error("connectOnly: no audio output device")
            return
        }
        setSessionActive(true)
        connect(audioUnit)
    }

    /// Observe the extension's `needsAudio` parameter to start/stop the engine on demand.
    func observeNeedsAudio(audioUnit: AVAudioUnit) {
        guard let tree = audioUnit.auAudioUnit.parameterTree,
              let param = tree.parameter(withAddress: needsAudioParameterAddress) else {
            log.warning("observeNeedsAudio: parameter not found, starting engine immediately")
            startPlaying()
            return
        }
        self.needsAudioParam = param

        // Check current value in case the extension already set it (e.g., auto-reconnect)
        if param.value >= 0.5 {
            startPlaying()
        }

        needsAudioObserverToken = param.token(byAddingParameterObserver: { [weak self] _, value in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if value >= 0.5 {
                    self.stopDebounceTask?.cancel()
                    self.stopDebounceTask = nil
                    self.startPlaying()
                } else {
                    // Debounce stop to avoid rapid start/stop cycles
                    self.stopDebounceTask?.cancel()
                    self.stopDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        self?.stopPlaying()
                    }
                }
            }
        })
    }

    private func removeNeedsAudioObserver() {
        stopDebounceTask?.cancel()
        stopDebounceTask = nil
        if let token = needsAudioObserverToken, let param = needsAudioParam {
            param.removeParameterObserver(token)
        }
        needsAudioObserverToken = nil
        needsAudioParam = nil
    }

    func connectAndStart() {
        guard let audioUnit = avAudioUnit else {
            log.error("connectAndStart: no avAudioUnit")
            return
        }
        guard Self.hasAudioOutput() else {
            log.error("connectAndStart: no audio output device")
            return
        }
        // On iOS, activate the audio session BEFORE reading input/output formats —
        // otherwise engine.inputNode returns 0 Hz / 0 channels and connect() crashes.
        setSessionActive(true)
        connect(audioUnit)
        startPlaying()
    }

    // MARK: - Audio Graph

    /// Wire the audio graph: inputNode → AU → mainMixerNode → outputNode.
    private func connect(_ audioUnit: AVAudioUnit) {
        engine.attach(audioUnit)

        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: 2)!

        if audioUnit.wantsAudioInput && Self.hasAudioInput() {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
                log.warning("Input format invalid (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch) — skipping input")
                engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
                return
            }
            // Pre-validate: set the AU's bus formats before connecting.
            // AVAudioEngine.connect() throws ObjC exceptions on format mismatch;
            // AUAudioUnitBus.setFormat() throws a Swift error we can handle.
            let au = audioUnit.auAudioUnit
            do {
                try au.inputBusses[0].setFormat(inputFormat)
                try au.outputBusses[0].setFormat(inputFormat)
            } catch {
                log.warning("AU rejected input format (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch): \(error.localizedDescription) — falling back to stereo hw format")
                // Fall back: connect without mic input, using the hardware output sample rate
                engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
                return
            }
            engine.connect(engine.inputNode, to: audioUnit, format: inputFormat)
            engine.connect(audioUnit, to: engine.mainMixerNode, format: inputFormat)
        } else {
            engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
        }

        let auAudioUnit = audioUnit.auAudioUnit
        if !auAudioUnit.midiOutputNames.isEmpty {
            auAudioUnit.midiOutputEventBlock = midiOutBlock
        }
        _scheduleMIDIEventListBlock.withLock { $0 = auAudioUnit.scheduleMIDIEventListBlock }
    }

    // MARK: - Playback State

    public func startPlaying() {
        guard !isPlaying, avAudioUnit != nil else { return }
        setSessionActive(true)
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hwFormat)
        do {
            try engine.start()
            isPlaying = true
            log.notice("Audio engine started: sampleRate=\(hwFormat.sampleRate, privacy: .public) Hz, channels=\(hwFormat.channelCount)")
        } catch {
            log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            isPlaying = false
        }
    }

    public func stopPlaying() {
        guard isPlaying else { return }
        engine.stop()
        isPlaying = false
        setSessionActive(false)
    }

    public func reset() {
        guard let audioUnit = avAudioUnit else { return }
        removeNeedsAudioObserver()
        stopPlaying()
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.detach(audioUnit)
        avAudioUnit = nil
    }

    @discardableResult
    private func setSessionActive(_ active: Bool, needsMic: Bool = true) -> Bool {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if needsMic {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(active)
            return true
        } catch {
            log.error("Could not set Audio Session active \(active): \(error.localizedDescription)")
            return false
        }
#else
        return true
#endif
    }

    // MARK: - Input Source Selection (iOS)

#if os(iOS) || os(visionOS)

    /// Switch the audio input source. Rewires the AVAudioEngine graph.
    func setInputSource(_ source: InputSourceType) async {
        guard let audioUnit = avAudioUnit else {
            log.error("setInputSource: no avAudioUnit")
            return
        }

        let wasPlaying = isPlaying
        if isPlaying { stopPlaying() }

        // Disconnect existing graph (keep jamauv3 AU attached)
        engine.disconnectNodeInput(audioUnit)
        engine.disconnectNodeOutput(audioUnit)
        engine.disconnectNodeInput(engine.mainMixerNode)

        // Detach previous instrument if any
        if let oldInst = instrumentAU {
            engine.disconnectNodeInput(oldInst)
            engine.disconnectNodeOutput(oldInst)
            engine.detach(oldInst)
            instrumentAU = nil
        }

        switch source {
        case .microphone:
            setPreferredInput(nil)
            setSessionActive(true, needsMic: true)
            connectMicToAU(audioUnit)
            setMIDITargetJamauv3()

        case .hardwareInput(let port):
            setPreferredInput(port)
            setSessionActive(true, needsMic: true)
            connectMicToAU(audioUnit)
            setMIDITargetJamauv3()

        case .instrument(let desc):
            guard setSessionActive(true, needsMic: false) else {
                log.error("Session activation failed for instrument — falling back to mic")
                setSessionActive(true, needsMic: true)
                connectMicToAU(audioUnit)
                setMIDITargetJamauv3()
                break
            }
            do {
                let instAU = try await AVAudioUnit.instantiate(with: desc, options: [])
                self.instrumentAU = instAU
                connectInstrumentToAU(instAU, jamauv3: audioUnit)
                setMIDITargetInstrument(instAU)
            } catch {
                log.error("Failed to load instrument: \(error.localizedDescription)")
                // Fall back to mic
                setSessionActive(true, needsMic: true)
                connectMicToAU(audioUnit)
                setMIDITargetJamauv3()
            }
        }

        if wasPlaying { startPlaying() }
    }

    /// Load the instrument AU's view controller for display.
    func loadInstrumentViewController() async -> ViewController? {
        guard let instAU = instrumentAU else { return nil }
        return await instAU.loadAudioUnitViewController()
    }

    // MARK: - Graph Wiring Helpers

    /// Wire: inputNode (mic) → jamauv3 AU → mainMixer
    private func connectMicToAU(_ audioUnit: AVAudioUnit) {
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: 2)!

        if Self.hasAudioInput() {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
                log.warning("Input format invalid — skipping mic input")
                engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
                return
            }
            let au = audioUnit.auAudioUnit
            do {
                try au.inputBusses[0].setFormat(inputFormat)
                try au.outputBusses[0].setFormat(inputFormat)
            } catch {
                log.warning("AU rejected input format: \(error.localizedDescription) — falling back to stereo hw format")
                engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
                return
            }
            engine.connect(engine.inputNode, to: audioUnit, format: inputFormat)
            engine.connect(audioUnit, to: engine.mainMixerNode, format: inputFormat)
        } else {
            engine.connect(audioUnit, to: engine.mainMixerNode, format: stereoFormat)
        }
    }

    /// Wire: instrument AU → jamauv3 AU (for NINJAM capture) + instrument AU → mainMixer (for local monitoring).
    /// jamauv3 zeroes its output (no passthrough) so the instrument must also be routed directly to the mixer.
    private func connectInstrumentToAU(_ instAU: AVAudioUnit, jamauv3 audioUnit: AVAudioUnit) {
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            log.warning("Output format invalid (\(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch) — cannot connect instrument")
            return
        }
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: 2)!

        engine.attach(instAU)

        // Pre-validate: set bus formats before connecting to avoid ObjC exceptions
        let au = audioUnit.auAudioUnit
        do {
            try au.inputBusses[0].setFormat(stereoFormat)
            try au.outputBusses[0].setFormat(stereoFormat)
        } catch {
            log.warning("AU rejected instrument format: \(error.localizedDescription)")
        }

        // Fan out instrument: bus 0 → jamauv3 (capture), bus 1 → mainMixer (monitoring)
        engine.connect(instAU, to: [
            AVAudioConnectionPoint(node: audioUnit, bus: 0),
            AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 1)
        ], fromBus: 0, format: stereoFormat)
        // jamauv3 output (remote audio + metronome) → mainMixer bus 0
        engine.connect(audioUnit, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: stereoFormat)
    }

    private func setPreferredInput(_ port: AVAudioSessionPortDescription?) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(port)
        } catch {
            log.error("Failed to set preferred input: \(error.localizedDescription)")
        }
    }

    // MARK: - MIDI Target

    private func setMIDITargetJamauv3() {
        guard let au = avAudioUnit else { return }
        _scheduleMIDIEventListBlock.withLock { $0 = au.auAudioUnit.scheduleMIDIEventListBlock }
        _scheduleMIDIEventBlock.withLock { $0 = au.auAudioUnit.scheduleMIDIEventBlock }
    }

    private func setMIDITargetInstrument(_ instAU: AVAudioUnit) {
        let listBlock = instAU.auAudioUnit.scheduleMIDIEventListBlock
        let eventBlock = instAU.auAudioUnit.scheduleMIDIEventBlock
        _scheduleMIDIEventListBlock.withLock { $0 = listBlock }
        _scheduleMIDIEventBlock.withLock { $0 = eventBlock }
        if listBlock != nil {
            log.notice("MIDI target: instrument (MIDI 2.0 event list)")
        } else if eventBlock != nil {
            log.notice("MIDI target: instrument (MIDI 1.0 fallback)")
        } else {
            log.warning("MIDI target: instrument has no MIDI schedule block")
        }
    }

#endif
}
