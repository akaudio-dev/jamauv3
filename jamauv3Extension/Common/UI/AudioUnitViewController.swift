//
//  AudioUnitViewController.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Combine
import CoreAudioKit
import os
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

        ninjamClient.delegate = self

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
					self.configureSwiftUIView(audioUnit: audioUnit)
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
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else { return }
        let sampleRate = auUnit.kernel.sampleRate
        let bpm = ninjamClient.bpm
        let bpi = ninjamClient.bpi
        guard bpm > 0, bpi > 0 else { return }

        let config = IntervalConfig(bpm: bpm, bpi: bpi, sampleRate: sampleRate)
        let buffer = IntervalBuffer(config: config)

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
        self.intervalBuffer = buffer
        buffer.start()
    }

    /// Stop interval capture on disconnect
    private func stopIntervalCapture() {
        intervalBuffer?.stop()
        if let auUnit = audioUnit as? jamauv3ExtensionAudioUnit {
            auUnit.kernel.intervalBuffer = nil
        }
        intervalBuffer = nil
    }

    /// Update interval buffer config on BPM/BPI change
    private func updateIntervalConfig() {
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else { return }
        let sampleRate = auUnit.kernel.sampleRate
        let config = IntervalConfig(bpm: ninjamClient.bpm, bpi: ninjamClient.bpi, sampleRate: sampleRate)
        intervalBuffer?.updateConfig(config)
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

}

// MARK: - NINJAMClientDelegate

extension AudioUnitViewController: NINJAMClientDelegate {
    func client(_ client: NINJAMClient, didChangeState state: NINJAMConnectionState) {
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
        if intervalBuffer != nil {
            // Already capturing — update config
            updateIntervalConfig()
        } else if client.isConnected {
            // First config after connect — start capturing
            startIntervalCapture()
        }
    }

    func client(_ client: NINJAMClient, didReceiveUserInfo channels: [RemoteChannelInfo]) {
        // Will be used for audio mixing in a future step
    }

    func client(_ client: NINJAMClient, didReceiveChatMessage message: ServerChatMessage) {
        // Will be used for chat UI in a future step
    }
}
