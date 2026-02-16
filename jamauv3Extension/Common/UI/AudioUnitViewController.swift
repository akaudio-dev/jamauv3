//
//  AudioUnitViewController.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Combine
import CoreAudioKit
import os
import Synchronization
import SwiftUI

private let log = Logger(subsystem: "jamauv3.com.jamauv3Extension", category: "AudioUnitViewController")

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?
    
    var hostingController: HostingController<jamauv3ExtensionMainView>?
    
    private var observation: NSKeyValueObservation?
    
    private let connectionSettings = ConnectionSettings()
    private let ninjamClient = NINJAMClient()
    private var intervalBuffer: IntervalBuffer?
    private var remoteAudioMixer: RemoteAudioMixer?
    private var diagnosticTask: Task<Void, Never>?

	/* iOS View lifcycle
	public override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		// Recreate any view related resources here..
	}

	public override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		// Destroy any view related content here..
	}
	*/

	/* macOS View lifcycle
	public override func viewWillAppear() {
		super.viewWillAppear()
		
		// Recreate any view related resources here..
	}

	public override func viewDidDisappear() {
		super.viewDidDisappear()

		// Destroy any view related content here..
	}
	*/

	deinit {
	}

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Accessing the `audioUnit` parameter prompts the AU to be created via createAudioUnit(with:)
        guard let audioUnit = self.audioUnit else {
            return
        }
        configureSwiftUIView(audioUnit: audioUnit)
    }
    
	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
		return try DispatchQueue.main.sync {
			
			audioUnit = try jamauv3ExtensionAudioUnit(componentDescription: componentDescription, options: [])
			
			guard let audioUnit = self.audioUnit as? jamauv3ExtensionAudioUnit else {
				log.error("Unable to create jamauv3ExtensionAudioUnit")
				return audioUnit!
			}
			
			defer {
				// Configure the SwiftUI view after creating the AU, instead of in viewDidLoad,
				// so that the parameter tree is set up before we build our @AUParameterUI properties
				DispatchQueue.main.async {
					self.ninjamClient.delegate = self
					self.configureSwiftUIView(audioUnit: audioUnit)
					self.attemptAutoConnect()
				}
			}
			
			audioUnit.setupParameterTree(jamauv3ExtensionParameterSpecs.createAUParameterTree())
			
			self.observation = audioUnit.observe(\.allParameterValues, options: [.new]) { object, change in
				guard let tree = audioUnit.parameterTree else { return }
				
				// This insures the Audio Unit gets initial values from the host.
				for param in tree.allParameters { param.value = param.value }
			}
			
			guard audioUnit.parameterTree != nil else {
				log.error("Unable to access AU ParameterTree")
				return audioUnit
			}
			
			return audioUnit
		}
	}
    
    // MARK: - Interval Buffer Wiring

    /// Start interval capture when connected with valid config
    private func startIntervalCapture() {
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else {
            log.error("startIntervalCapture: audioUnit is nil or wrong type (audioUnit=\(String(describing: self.audioUnit)))")
            return
        }
        let sampleRate = auUnit.kernel.sampleRate
        let bpm = ninjamClient.bpm
        let bpi = ninjamClient.bpi
        guard bpm > 0, bpi > 0 else {
            log.error("startIntervalCapture: invalid config bpm=\(bpm) bpi=\(bpi)")
            return
        }
        log.info("startIntervalCapture: sampleRate=\(sampleRate) bpm=\(bpm) bpi=\(bpi)")

        let config = IntervalConfig(bpm: bpm, bpi: bpi, sampleRate: sampleRate)
        let buffer = IntervalBuffer(config: config, stereo: connectionSettings.stereo)

        buffer.onUploadBegin = { [weak self] msg in
            self?.ninjamClient.sendUploadBegin(msg)
        }
        buffer.onUploadWrite = { [weak self] msg in
            self?.ninjamClient.sendUploadWrite(msg)
        }
        buffer.onIntervalBoundary = { [weak self] in
            // Reset the wall-clock interval timer for sample-accurate UI sync
            self?.ninjamClient.resetIntervalTimer()
        }

        auUnit.kernel.intervalBuffer = buffer
        auUnit.kernel.setIntervalConfig(bpi: bpi, intervalLength: config.intervalLengthInSamples)
        self.intervalBuffer = buffer
        buffer.start()

        startRemoteAudioMixer(config: config, kernel: auUnit.kernel)

        // Periodic diagnostic: log mixer pipeline counters every 5 seconds
        startMixerDiagnostics()
    }

    /// Stop interval capture on disconnect
    private func stopIntervalCapture() {
        intervalBuffer?.stop()
        if let auUnit = audioUnit as? jamauv3ExtensionAudioUnit {
            auUnit.kernel.intervalBuffer = nil
        }
        intervalBuffer = nil

        stopRemoteAudioMixer()
    }

    /// Update interval buffer config on BPM/BPI change
    private func updateIntervalConfig() {
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else { return }
        let sampleRate = auUnit.kernel.sampleRate
        let config = IntervalConfig(bpm: ninjamClient.bpm, bpi: ninjamClient.bpi, sampleRate: sampleRate)
        intervalBuffer?.updateConfig(config)
        remoteAudioMixer?.updateConfig(config)
        auUnit.kernel.setIntervalConfig(bpi: ninjamClient.bpi, intervalLength: config.intervalLengthInSamples)
    }

    // MARK: - Remote Audio Mixer Wiring

    private func startRemoteAudioMixer(config: IntervalConfig, kernel: DSPKernel) {
        let mixer = RemoteAudioMixer()
        kernel.remoteAudioMixer = mixer
        self.remoteAudioMixer = mixer
        mixer.start(config: config)
    }

    private func stopRemoteAudioMixer() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        remoteAudioMixer?.stop()
        if let auUnit = audioUnit as? jamauv3ExtensionAudioUnit {
            auUnit.kernel.remoteAudioMixer = nil
        }
        remoteAudioMixer = nil
    }

    private func startMixerDiagnostics() {
        diagnosticTask?.cancel()
        diagnosticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let mixer = self?.remoteAudioMixer else { break }
                let decodes = mixer.decodeCount.load(ordering: .relaxed)
                let swaps = mixer.bufferSwapCount.load(ordering: .relaxed)
                let mixed = mixer.samplesMixedCount.load(ordering: .relaxed)
                let mixCalls = mixer.mixCallCount.load(ordering: .relaxed)

                // Read and reset peaks from DSPKernel
                var inputPeakStr = "n/a"
                var outputPeakStr = "n/a"
                var hostTempoVal: Double = 0
                var correctedLen = 0
                if let kernel = (self?.audioUnit as? jamauv3ExtensionAudioUnit)?.kernel {
                    let inBits = kernel.inputPeak.exchange(0, ordering: .relaxed)
                    inputPeakStr = String(format: "%.6f", Float(bitPattern: inBits))
                    let outBits = kernel.outputPeak.exchange(0, ordering: .relaxed)
                    outputPeakStr = String(format: "%.6f", Float(bitPattern: outBits))

                    // Read host tempo from kernel and update HUD
                    let tempoBits = kernel.hostTempo.load(ordering: .relaxed)
                    hostTempoVal = Double(bitPattern: tempoBits)
                    if hostTempoVal > 0 {
                        self?.ninjamClient.hostBPM = hostTempoVal
                    }
                    correctedLen = kernel.correctedIntervalLength.load(ordering: .relaxed)
                }

                log.info("Mixer stats: decodes=\(decodes) swaps=\(swaps) mixed=\(mixed) mixCalls=\(mixCalls) inPeak=\(inputPeakStr, privacy: .public) outPeak=\(outputPeakStr, privacy: .public) hostBPM=\(String(format: "%.1f", hostTempoVal), privacy: .public) correctedInterval=\(correctedLen)")
            }
        }
    }

    // MARK: - SwiftUI Configuration

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        if let host = hostingController {
            host.removeFromParent()
            host.view.removeFromSuperview()
        }
        
        guard let observableParameterTree = audioUnit.observableParameterTree else {
            return
        }
        let content = jamauv3ExtensionMainView(
            parameterTree: observableParameterTree,
            connectionSettings: connectionSettings,
            ninjamClient: ninjamClient
        )
        let host = HostingController(rootView: content)
        self.addChild(host)
        host.view.frame = self.view.bounds
        self.view.addSubview(host.view)
        hostingController = host
        
        // Make sure the SwiftUI view fills the full area provided by the view controller
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
        self.view.bringSubviewToFront(host.view)
    }

    private func attemptAutoConnect() {
        guard !ninjamClient.isConnected,
              !connectionSettings.serverName.isEmpty,
              !connectionSettings.username.isEmpty,
              let port = UInt16(connectionSettings.port) else { return }

        log.info("Auto-reconnecting to \(self.connectionSettings.serverName, privacy: .public):\(port)")
        ninjamClient.connect(
            host: connectionSettings.serverName,
            port: port,
            username: connectionSettings.username,
            password: connectionSettings.password
        )
    }

}

// MARK: - NINJAMClientDelegate

extension AudioUnitViewController: NINJAMClientDelegate {
    func client(_ client: NINJAMClient, didChangeState state: NINJAMConnectionState) {
        log.info("didChangeState: \(String(describing: state))")
        switch state {
        case .connected:
            // Start interval capture once we have config (triggered by didReceiveConfig)
            break
        case .disconnected, .error:
            stopIntervalCapture()
        default:
            break
        }
    }

    func client(_ client: NINJAMClient, didReceiveConfig bpm: Int, bpi: Int) {
        log.info("didReceiveConfig: bpm=\(bpm) bpi=\(bpi) intervalBuffer=\(self.intervalBuffer != nil ? "exists" : "nil") isConnected=\(client.isConnected)")
        if intervalBuffer != nil {
            // Already capturing — update config
            updateIntervalConfig()
        } else if client.isConnected {
            // First config after connect — start capturing
            startIntervalCapture()
        }
    }

    func client(_ client: NINJAMClient, didReceiveUserInfo channels: [RemoteChannelInfo]) {
        remoteAudioMixer?.updateUserInfo(channels: channels)
    }

    func client(_ client: NINJAMClient, didReceiveAudioBegin guid: Data, username: String, channelIndex: Int, fourCC: UInt32) {
        remoteAudioMixer?.beginDownload(guid: guid, username: username, channelIndex: channelIndex, fourCC: fourCC)
    }

    func client(_ client: NINJAMClient, didReceiveAudioData guid: Data, data: Data, isEnd: Bool) {
        remoteAudioMixer?.receiveData(guid: guid, data: data, isEnd: isEnd)
    }

    func client(_ client: NINJAMClient, didReceiveChatMessage message: ServerChatMessage) {
        switch message.messageType {
        case .message(let from, let text):
            client.addChatEntry(ChatEntry(timestamp: Date(), type: .message(from: from, text: text)))
        case .topicChange(let topic):
            client.serverTopic = topic
            client.addChatEntry(ChatEntry(timestamp: Date(), type: .topic(text: topic)))
        case .join(let username):
            client.addChatEntry(ChatEntry(timestamp: Date(), type: .join(username: username)))
        case .part(let username):
            client.addChatEntry(ChatEntry(timestamp: Date(), type: .part(username: username)))
        default:
            break
        }
    }
}
