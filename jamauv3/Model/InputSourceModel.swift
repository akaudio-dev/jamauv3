// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  InputSourceModel.swift
//  jamauv3
//
//  Audio input source model for iOS — hardware port selection + AUv3 instrument hosting.
//

#if os(iOS) || os(visionOS)

import Foundation
import AVFAudio
import AudioToolbox

/// Represents the selected audio input source.
enum InputSourceType: Equatable {
    case microphone
    case hardwareInput(AVAudioSessionPortDescription)
    case instrument(AudioComponentDescription)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.microphone, .microphone):
            return true
        case (.hardwareInput(let a), .hardwareInput(let b)):
            return a.uid == b.uid
        case (.instrument(let a), .instrument(let b)):
            return a.componentType == b.componentType
                && a.componentSubType == b.componentSubType
                && a.componentManufacturer == b.componentManufacturer
        default:
            return false
        }
    }
}

@MainActor
@Observable
class InputSourceModel {
    var selectedSource: InputSourceType = .microphone
    var availableInputs: [AVAudioSessionPortDescription] = []
    var availableInstruments: [AVAudioUnitComponent] = []
    var instrumentViewController: ViewController?
    var instrumentAU: AVAudioUnit?
    var isShowingInstrumentUI: Bool = false
    var isInstrumentMaximized: Bool = false

    // MARK: - Refresh

    func refreshAvailableInputs() {
        availableInputs = AVAudioSession.sharedInstance().availableInputs ?? []
    }

    func refreshAvailableInstruments() {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0)
        availableInstruments = AVAudioUnitComponentManager.shared().components(matching: desc)
    }

    // MARK: - Persistence

    private static let sourceTypeKey = "jamauv3.inputSource.type"
    private static let instrumentTypeKey = "jamauv3.inputSource.inst.type"
    private static let instrumentSubTypeKey = "jamauv3.inputSource.inst.subType"
    private static let instrumentMfrKey = "jamauv3.inputSource.inst.mfr"

    func save() {
        let defaults = UserDefaults.standard
        switch selectedSource {
        case .microphone:
            defaults.set("microphone", forKey: Self.sourceTypeKey)
        case .hardwareInput(let port):
            defaults.set("hardware:\(port.uid)", forKey: Self.sourceTypeKey)
        case .instrument:
            defaults.set("instrument", forKey: Self.sourceTypeKey)
            if case .instrument(let desc) = selectedSource {
                defaults.set(Int(desc.componentType), forKey: Self.instrumentTypeKey)
                defaults.set(Int(desc.componentSubType), forKey: Self.instrumentSubTypeKey)
                defaults.set(Int(desc.componentManufacturer), forKey: Self.instrumentMfrKey)
            }
        }
    }

    func restore() {
        let defaults = UserDefaults.standard
        guard let typeStr = defaults.string(forKey: Self.sourceTypeKey) else { return }

        if typeStr == "microphone" {
            selectedSource = .microphone
        } else if typeStr.hasPrefix("hardware:") {
            let uid = String(typeStr.dropFirst("hardware:".count))
            if let port = availableInputs.first(where: { $0.uid == uid }) {
                selectedSource = .hardwareInput(port)
            } else {
                selectedSource = .microphone
            }
        } else if typeStr == "instrument" {
            let type = UInt32(defaults.integer(forKey: Self.instrumentTypeKey))
            let subType = UInt32(defaults.integer(forKey: Self.instrumentSubTypeKey))
            let mfr = UInt32(defaults.integer(forKey: Self.instrumentMfrKey))
            guard type != 0 else { return }
            let desc = AudioComponentDescription(
                componentType: type,
                componentSubType: subType,
                componentManufacturer: mfr,
                componentFlags: 0,
                componentFlagsMask: 0)
            // Verify the component still exists on the device
            let components = AVAudioUnitComponentManager.shared().components(matching: desc)
            if !components.isEmpty {
                selectedSource = .instrument(desc)
            } else {
                selectedSource = .microphone
            }
        }
    }
}

#endif
