//
//  AudioUnitHostModel.swift
//  jamauv3
//

import SwiftUI
import CoreMIDI
import AudioToolbox
import AVFAudio

@MainActor
@Observable
class AudioUnitHostModel {
    private let playEngine = SimplePlayEngine()
    var viewModel = AudioUnitViewModel()

    #if os(iOS) || os(visionOS)
    let inputSource = InputSourceModel()
    #endif

    init() {
        loadAudioUnit()
        #if os(iOS) || os(visionOS)
        setupRouteChangeNotifications()
        #endif
    }

    private func loadAudioUnit() {
        Task {
            let viewController = await playEngine.initComponent(
                type: "aumf", subType: "jmv3", manufacturer: "jmv3")
            self.viewModel = AudioUnitViewModel(
                message: viewController == nil ? "Failed to load audio unit." : "",
                viewController: viewController,
                isLoaded: true)
            #if os(macOS)
            // macOS: start engine immediately (no battery concern)
            playEngine.connectAndStart()
            #else
            // iOS: wire graph but defer engine start until extension signals needsAudio
            playEngine.connectOnly()
            if let au = playEngine.avAudioUnit {
                playEngine.observeNeedsAudio(audioUnit: au)
            }
            inputSource.refreshAvailableInputs()
            inputSource.refreshAvailableInstruments()
            inputSource.restore()
            // Apply persisted input source if it's not the default mic
            if inputSource.selectedSource != .microphone {
                await applyInputSource(inputSource.selectedSource)
            }
            #endif
        }
    }

    // MARK: - Input Source (iOS)

    #if os(iOS) || os(visionOS)

    func switchInputSource(to source: InputSourceType) {
        Task {
            await applyInputSource(source)
            inputSource.selectedSource = source
            inputSource.save()

            if case .instrument = source {
                inputSource.instrumentViewController = await playEngine.loadInstrumentViewController()
            } else {
                inputSource.instrumentViewController = nil
                inputSource.isShowingInstrumentUI = false
                inputSource.isInstrumentMaximized = false
            }
        }
    }

    private func applyInputSource(_ source: InputSourceType) async {
        await playEngine.setInputSource(source)
    }

    private func setupRouteChangeNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputSource.refreshAvailableInputs()
                // If selected hardware port was disconnected, fall back to mic
                if case .hardwareInput(let port) = self.inputSource.selectedSource {
                    if !self.inputSource.availableInputs.contains(where: { $0.uid == port.uid }) {
                        self.switchInputSource(to: .microphone)
                    }
                }
            }
        }
    }

    #endif
}
