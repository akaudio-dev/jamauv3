// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

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
    
    private let connectionSettings = ConnectionSettings()
    private let ninjamClient = NINJAMClient()
    private var intervalBuffer: IntervalBuffer?
    private var remoteAudioMixer: RemoteAudioMixer?
    private var icecastPlayer: IcecastStreamPlayer?
    private var diagnosticTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var metronomeCancellables = Set<AnyCancellable>()

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

        preferredContentSize = CGSize(width: 320, height: 480)

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

			// Reconcile the interval config whenever the real render rate is (re)established.
			// Fires from allocateRenderResources (possibly off the main thread), so hop to
			// the main actor before touching interval/mixer state. On iOS the engine starts
			// after connect, so this is what corrects a capture that was built from the
			// kernel's default rate before the true rate was known.
			audioUnit.onSampleRateChange = { [weak self] newRate in
				Task { @MainActor in
					guard let self else { return }
					log.debug("Render sample rate established/changed to \(newRate) Hz")
					if self.intervalBuffer != nil {
						self.updateIntervalConfig(immediate: true)
					}
				}
			}
			
			audioUnit.setupParameterTree(jamauv3ExtensionParameterSpecs.createAUParameterTree())

			// Note: setupParameterTree already initializes kernel parameters from the tree.
			// Do NOT add a parameter value sync loop here — in out-of-process AU on iOS,
			// each param.value = param.value generates an XPC round-trip, and the burst
			// of N parameter writes can exceed the 32 Hz XPC rate limit.

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
        log.debug("startIntervalCapture: sampleRate=\(sampleRate) bpm=\(bpm) bpi=\(bpi)")

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
        auUnit.kernel.setIntervalConfig(bpi: bpi, intervalLength: config.intervalLengthInSamples,
                                        immediate: true)
        self.intervalBuffer = buffer
        buffer.start()

        // Wire metronome settings to kernel
        let kernel = auUnit.kernel
        kernel.metronomeEnabled.store(connectionSettings.metronomeEnabled ? 1 : 0, ordering: .releasing)
        kernel.metronomeBeat1Only.store(connectionSettings.metronomeBeat1Only ? 1 : 0, ordering: .releasing)

        connectionSettings.$metronomeEnabled
            .sink { [weak kernel] enabled in
                kernel?.metronomeEnabled.store(enabled ? 1 : 0, ordering: .releasing)
            }
            .store(in: &metronomeCancellables)

        connectionSettings.$metronomeBeat1Only
            .sink { [weak kernel] beat1Only in
                kernel?.metronomeBeat1Only.store(beat1Only ? 1 : 0, ordering: .releasing)
            }
            .store(in: &metronomeCancellables)

        startRemoteAudioMixer(config: config, kernel: auUnit.kernel)

        // Periodic diagnostic: log mixer pipeline counters every 5 seconds
        startMixerDiagnostics()
        startMeterTimer()
        updateNeedsAudio()
    }

    /// Stop interval capture on disconnect
    private func stopIntervalCapture() {
        metronomeCancellables.removeAll()
        intervalBuffer?.stop()
        if let auUnit = audioUnit as? jamauv3ExtensionAudioUnit {
            auUnit.kernel.intervalBuffer = nil
        }
        intervalBuffer = nil

        stopRemoteAudioMixer()
        updateNeedsAudio()
    }

    /// Update interval buffer config on BPM/BPI change (applied at the next
    /// interval boundary) or on a host sample-rate change (`immediate`).
    private func updateIntervalConfig(immediate: Bool = false) {
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else { return }
        let sampleRate = auUnit.kernel.sampleRate
        let config = IntervalConfig(bpm: ninjamClient.bpm, bpi: ninjamClient.bpi, sampleRate: sampleRate)
        intervalBuffer?.updateConfig(config)
        remoteAudioMixer?.updateConfig(config)
        auUnit.kernel.setIntervalConfig(bpi: ninjamClient.bpi, intervalLength: config.intervalLengthInSamples,
                                        immediate: immediate)
    }

    // MARK: - Remote Audio Mixer Wiring

    private func startRemoteAudioMixer(config: IntervalConfig, kernel: DSPKernel) {
        let mixer = RemoteAudioMixer()
        kernel.remoteAudioMixer = mixer
        self.remoteAudioMixer = mixer
        mixer.start(config: config)
    }

    private func stopRemoteAudioMixer() {
        meterTask?.cancel()
        meterTask = nil
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
        var prevFramesRendered = 0
        let windowSeconds = 5.0
        diagnosticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let mixer = self?.remoteAudioMixer else { break }
                let decodes = mixer.decodeCount.load(ordering: .relaxed)
                let swaps = mixer.bufferSwapCount.load(ordering: .relaxed)
                let mixed = mixer.samplesMixedCount.load(ordering: .relaxed)
                let mixCalls = mixer.mixCallCount.load(ordering: .relaxed)

                // Clock-drift diagnostic: the render thread's TRUE sample rate is the
                // frames it actually consumed over this window. If it differs from the
                // config rate the interval math uses, the boundary grid drifts against
                // remote-interval arrivals and intervals drop periodically.
                let framesNow = mixer.framesRenderedCount.load(ordering: .relaxed)
                let observedRate = Double(framesNow - prevFramesRendered) / windowSeconds
                prevFramesRendered = framesNow
                let swapMisses = mixer.swapMissCount.load(ordering: .relaxed)
                let overwrites = mixer.overwriteCount.load(ordering: .relaxed)
                let lastDecodedFrames = mixer.lastDecodedFrames.load(ordering: .relaxed)
                let mixerRate = mixer.configuredSampleRate()
                let mixerIntervalLen = mixer.configuredIntervalLength()

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

                let configRate = (self?.audioUnit as? jamauv3ExtensionAudioUnit)?.kernel.sampleRate ?? 0

                log.notice("""
                    Mixer stats: decodes=\(decodes, privacy: .public) swaps=\(swaps, privacy: .public) \
                    swapMisses=\(swapMisses, privacy: .public) overwrites=\(overwrites, privacy: .public) \
                    mixed=\(mixed, privacy: .public) mixCalls=\(mixCalls, privacy: .public) \
                    observedRenderRate=\(String(format: "%.1f", observedRate), privacy: .public) \
                    configRate=\(String(format: "%.1f", configRate), privacy: .public) \
                    mixerRate=\(mixerRate, privacy: .public) mixerIntervalLen=\(mixerIntervalLen, privacy: .public) \
                    lastDecodedFrames=\(lastDecodedFrames, privacy: .public) correctedInterval=\(correctedLen, privacy: .public) \
                    inPeak=\(inputPeakStr, privacy: .public) outPeak=\(outputPeakStr, privacy: .public) \
                    hostBPM=\(String(format: "%.1f", hostTempoVal), privacy: .public)
                    """)
            }
        }
    }

    private func startMeterTimer() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))  // ~5 Hz
                guard let self,
                      let kernel = (self.audioUnit as? jamauv3ExtensionAudioUnit)?.kernel,
                      let mixer = self.remoteAudioMixer else { continue }

                // Build new peaks array locally, assign once to trigger single objectWillChange
                var newPeaks = self.ninjamClient.userPeaks
                var peaksChanged = false
                for i in 0..<8 {
                    let peak = kernel.exchangeUserPeak(slot: i)
                    let current = newPeaks[i]
                    let updated = peak > current ? peak : current * 0.85
                    if abs(updated - current) > 0.005 {
                        newPeaks[i] = updated
                        peaksChanged = true
                    }
                }
                if peaksChanged {
                    self.ninjamClient.userPeaks = newPeaks
                }

                let newUsernames = mixer.slotUsernames()
                if newUsernames != self.ninjamClient.slotUsernames {
                    self.ninjamClient.slotUsernames = newUsernames
                }
            }
        }
    }

    // MARK: - Icecast Listener

    private func startIcecastListener(url: URL) {
        stopIcecastListener()
        guard let auUnit = audioUnit as? jamauv3ExtensionAudioUnit else { return }
        let sampleRate = auUnit.kernel.sampleRate
        log.debug("Starting Icecast listener: \(url.absoluteString) @ \(sampleRate) Hz")
        let player = IcecastStreamPlayer(sampleRate: sampleRate)
        auUnit.kernel.icecastPlayer = player
        self.icecastPlayer = player
        player.start(url: url)
        updateNeedsAudio()
    }

    private func stopIcecastListener() {
        icecastPlayer?.stop()
        if let auUnit = audioUnit as? jamauv3ExtensionAudioUnit {
            auUnit.kernel.icecastPlayer = nil
        }
        icecastPlayer = nil
        updateNeedsAudio()
    }

    // MARK: - Needs Audio Signal

    /// Signal the host whether the AU needs the audio engine running.
    /// Set to 1.0 when NINJAM connected or Icecast listening, 0.0 when idle.
    private func updateNeedsAudio() {
        let needs: Bool = (intervalBuffer != nil) || (icecastPlayer != nil)
        guard let tree = audioUnit?.parameterTree,
              let param = tree.parameter(withAddress: jamauv3ExtensionParameterAddress_needsAudio) else {
            return
        }
        let newValue: AUValue = needs ? 1.0 : 0.0
        if param.value != newValue {
            param.value = newValue
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
            ninjamClient: ninjamClient,
            onListenStart: { [weak self] url in self?.startIcecastListener(url: url) },
            onListenStop: { [weak self] in self?.stopIcecastListener() },
            icecastPeakReader: { [weak self] in self?.icecastPlayer?.exchangePeak() ?? 0 },
            icecastIsAlive: { [weak self] in
                guard let player = self?.icecastPlayer else { return false }
                return !player.hasEnded
            }
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

        log.debug("Auto-reconnecting to \(self.connectionSettings.serverName):\(port)")
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
        log.debug("didChangeState: \(String(describing: state))")
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
        log.debug("didReceiveConfig: bpm=\(bpm) bpi=\(bpi)")
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
