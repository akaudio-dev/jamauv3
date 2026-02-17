//
//  jamauv3ExtensionAudioUnit.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import AVFoundation
import CoreAudio
import os

private let log = Logger(subsystem: "jamauv3.com.jamauv3Extension", category: "AudioUnit")

public class jamauv3ExtensionAudioUnit: AUAudioUnit, @unchecked Sendable
{
    // Swift DSP Objects (no C++ needed)
    let kernel = DSPKernel()
    private var renderProcessor: RenderProcessor?
    private let inputBus = BufferedInputBus()

    private var outputBus: AUAudioUnitBus?
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    /// Track the last sample rate to detect changes across allocateRenderResources calls
    private var lastSampleRate: Double = 0

    /// Called when the host negotiates a different sample rate (e.g., user changes DAW sample rate)
    var onSampleRateChange: ((Double) -> Void)?

    /// Query the hardware output sample rate (cross-platform).
    private static func hardwareSampleRate() -> Double {
        #if os(iOS) || targetEnvironment(macCatalyst)
        return AVAudioSession.sharedInstance().sampleRate
        #else
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return 0 }

        var sampleRate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : 0
        #endif
    }

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        let defaultRate = Self.hardwareSampleRate()
        let format = AVAudioFormat(standardFormatWithSampleRate: defaultRate > 0 ? defaultRate : 48_000, channels: 2)!
        log.info("init: defaultRate=\(defaultRate, privacy: .public) Hz")
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus?.maximumChannelCount = 2
        
        // Create the input bus
        inputBus.initialize(format: format, maxChannels: 8)

        // Create the input and output bus arrays
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus.bus!])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus!])
        
        // Create render processor
        renderProcessor = RenderProcessor(kernel: kernel, inputBus: inputBus)
    }

    public override var inputBusses: AUAudioUnitBusArray {
        return _inputBusses
    }

    public override var outputBusses: AUAudioUnitBusArray {
        return _outputBusses
    }
    
    public override var channelCapabilities: [NSNumber] {
        get {
            // [-1, -1] means "any N-in, N-out where N matches" — maximum host flexibility
            return [NSNumber(value: -1), NSNumber(value: -1)]
        }
    }
    
    public override var maximumFramesToRender: AUAudioFrameCount {
        get {
            return kernel.maximumFramesToRender()
        }
        set {
            kernel.setMaximumFramesToRender(newValue)
        }
    }

    public override var canProcessInPlace: Bool { true }

    public override var shouldBypassEffect: Bool {
        get {
            return kernel.isBypassed()
        }
        set {
            kernel.setBypass(newValue)
        }
    }

    // MARK: - MIDI
    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        return kernel.audioUnitMIDIProtocol()
    }

    // MARK: - Rendering
    public override var internalRenderBlock: AUInternalRenderBlock {
        return renderProcessor!.internalRenderBlock()
    }

    // Allocate resources required to render.
    public override func allocateRenderResources() throws {
        let inFmt = self.inputBusses[0].format
        let outFmt = self.outputBusses[0].format
        let inputChannelCount = inFmt.channelCount
        let outputChannelCount = outFmt.channelCount

        log.info("allocateRenderResources: input=\(inFmt.sampleRate, privacy: .public)Hz/\(inputChannelCount, privacy: .public)ch output=\(outFmt.sampleRate, privacy: .public)Hz/\(outputChannelCount, privacy: .public)ch maxFrames=\(self.maximumFramesToRender, privacy: .public)")

        inputBus.allocateRenderResources(maxFrames: self.maximumFramesToRender)

        kernel.midiOutputEventBlock = self.midiOutputEventListBlock
        kernel.musicalContextBlock = self.musicalContextBlock
        kernel.transportStateBlock = self.transportStateBlock
        kernel.initialize(inputChannelCount: Int(inputChannelCount),
                         outputChannelCount: Int(outputChannelCount),
                         sampleRate: outFmt.sampleRate)
        renderProcessor?.setChannelCount(input: UInt32(inputChannelCount), output: UInt32(outputChannelCount))

        // Detect sample rate change and notify listener
        let newRate = outFmt.sampleRate
        if lastSampleRate > 0 && newRate != lastSampleRate {
            log.info("Sample rate changed: \(self.lastSampleRate, privacy: .public) → \(newRate, privacy: .public) Hz")
            onSampleRateChange?(newRate)
        }
        lastSampleRate = newRate

        try super.allocateRenderResources()
    }

    // Deallocate resources allocated in allocateRenderResourcesAndReturnError:
    public override func deallocateRenderResources() {
        kernel.deInitialize()
        inputBus.deallocateRenderResources()
        super.deallocateRenderResources()
    }

    public func setupParameterTree(_ parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree

        // Set the Parameter default values before setting up the parameter callbacks
        for param in parameterTree.allParameters {
            kernel.setParameter(address: param.address, value: param.value)
        }

        setupParameterCallbacks()
    }

    private func setupParameterCallbacks() {
        // implementorValueObserver is called when a parameter changes value.
        parameterTree?.implementorValueObserver = { [weak self] param, value -> Void in
            self?.kernel.setParameter(address: param.address, value: value)
        }

        // implementorValueProvider is called when the value needs to be refreshed.
        parameterTree?.implementorValueProvider = { [weak self] param in
            return self?.kernel.getParameter(address: param.address) ?? 0
        }

        // A function to provide string representations of parameter values.
        parameterTree?.implementorStringFromValueCallback = { param, valuePtr in
            guard let value = valuePtr?.pointee else {
                return "-"
            }
            return NSString.localizedStringWithFormat("%.f", value) as String
        }
    }
}
