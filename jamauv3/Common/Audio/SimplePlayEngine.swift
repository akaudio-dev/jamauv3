//
//  SimplePlayEngine.swift
//  jamauv3
//

import Foundation
import CoreAudioKit
import AVFoundation
@preconcurrency import AVFAudio
import Synchronization

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
                let genericViewController = await AUGenericViewController()
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
    private let midiOutBlock: AUMIDIOutputEventBlock = { _, _, _, _ in return noErr }

    public init() {
        engine.prepare()
        setupMIDI()
    }

    private func setupMIDI() {
        MIDIManager.shared.setupPort(midiProtocol: MIDIProtocolID._2_0, receiveBlock: { [weak self] eventList, _ in
            guard let self else { return }
            let block = self._scheduleMIDIEventListBlock.withLock { $0 }
            block?(AUEventSampleTimeImmediate, 0, eventList)
        })
    }

    // MARK: - Load

    func initComponent(type: String, subType: String, manufacturer: String) async -> ViewController? {
        reset()

        guard let component = AVAudioUnit.findComponent(type: type, subType: subType, manufacturer: manufacturer) else {
            return nil
        }

        do {
            let audioUnit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription, options: .loadOutOfProcess)
            self.avAudioUnit = audioUnit
            connect(audioUnit)
            startPlaying()
            return await audioUnit.loadAudioUnitViewController()
        } catch {
            return nil
        }
    }

    // MARK: - Audio Graph

    /// Wire the audio graph: inputNode → AU → mainMixerNode → outputNode.
    private func connect(_ audioUnit: AVAudioUnit) {
        engine.attach(audioUnit)

        if audioUnit.wantsAudioInput {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            engine.connect(engine.inputNode, to: audioUnit, format: inputFormat)
            engine.connect(audioUnit, to: engine.mainMixerNode, format: inputFormat)
        } else {
            let hwFormat = engine.outputNode.outputFormat(forBus: 0)
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hwFormat.sampleRate, channels: 2)
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
        } catch {
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
        stopPlaying()
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.detach(audioUnit)
        avAudioUnit = nil
    }

    private func setSessionActive(_ active: Bool) {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(active)
        } catch {
            print("Could not set Audio Session active \(active). error: \(error).")
        }
#endif
    }
}
