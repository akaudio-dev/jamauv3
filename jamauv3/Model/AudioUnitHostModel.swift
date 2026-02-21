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
    var audioUnitCrashed = false

    private let instanceInvalidationNotification = Notification.Name(
        String(kAudioComponentInstanceInvalidationNotification))

    init() {
        setupNotifications()
        loadAudioUnit()
    }

    private func loadAudioUnit() {
        Task {
            let viewController = await playEngine.initComponent(
                type: "aumf", subType: "jmv3", manufacturer: "jmv3")
            self.viewModel = AudioUnitViewModel(
                message: "Failed to load audio unit.",
                viewController: viewController)
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: instanceInvalidationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            if notification.object is AUAudioUnit {
                Task { @MainActor in self.audioUnitCrashed = true }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: instanceInvalidationNotification, object: nil)
    }
}
