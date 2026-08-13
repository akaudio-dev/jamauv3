// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  InputSourceBar.swift
//  jamauv3
//
//  Compact top bar showing current input source with picker access. iOS only.
//

#if os(iOS) || os(visionOS)

import SwiftUI
import AVFAudio

struct InputSourceBar: View {
    let inputSource: InputSourceModel
    let onSelect: (InputSourceType) -> Void

    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForSource(inputSource.selectedSource))
                .font(.callout)
            Text(nameForSource(inputSource.selectedSource))
                .font(.callout)
                .lineLimit(1)

            Spacer()

            Button(action: { showingPicker = true }) {
                Image(systemName: "chevron.down")
                    .font(.callout)
            }
            .buttonStyle(.borderless)

            if case .instrument = inputSource.selectedSource,
               inputSource.instrumentViewController != nil {
                Button(action: { inputSource.isShowingInstrumentUI.toggle() }) {
                    Image(systemName: "pianokeys")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .sheet(isPresented: $showingPicker) {
            InputSourcePickerView(
                inputSource: inputSource,
                onSelect: { source in
                    showingPicker = false
                    onSelect(source)
                }
            )
        }
    }

    private func iconForSource(_ source: InputSourceType) -> String {
        switch source {
        case .microphone: return "mic.fill"
        case .hardwareInput(let port): return iconForPort(port)
        case .instrument: return "pianokeys"
        }
    }

    private func nameForSource(_ source: InputSourceType) -> String {
        switch source {
        case .microphone: return "Microphone"
        case .hardwareInput(let port): return port.portName
        case .instrument(let desc):
            let components = AVAudioUnitComponentManager.shared().components(matching: desc)
            return components.first?.name ?? "Instrument"
        }
    }

    private func iconForPort(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic: return "mic.fill"
        case .headsetMic: return "headphones"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "wave.3.right"
        case .usbAudio: return "cable.connector"
        case .lineIn: return "cable.connector"
        default: return "waveform"
        }
    }
}

#endif
