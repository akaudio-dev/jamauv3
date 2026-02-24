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

    init() {
        loadAudioUnit()
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
            #endif
        }
    }
}
