//
//  jamauv3ExtensionAudioUnit.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import AVFoundation
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

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
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
        kernel.initialize(inputChannelCount: Int(inputChannelCount),
                         outputChannelCount: Int(outputChannelCount),
                         sampleRate: outFmt.sampleRate)
        renderProcessor?.setChannelCount(input: UInt32(inputChannelCount), output: UInt32(outputChannelCount))

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
