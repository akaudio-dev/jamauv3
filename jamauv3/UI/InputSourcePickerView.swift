//
//  InputSourcePickerView.swift
//  jamauv3
//
//  Full input source picker with hardware inputs and AUv3 instruments. iOS only.
//

#if os(iOS) || os(visionOS)

import SwiftUI
import AVFAudio
import AudioToolbox

struct InputSourcePickerView: View {
    let inputSource: InputSourceModel
    let onSelect: (InputSourceType) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Hardware Inputs") {
                    Button(action: { onSelect(.microphone) }) {
                        HStack {
                            Image(systemName: "mic.fill")
                            Text("Default Microphone")
                            Spacer()
                            if inputSource.selectedSource == .microphone {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)

                    ForEach(inputSource.availableInputs, id: \.uid) { port in
                        Button(action: { onSelect(.hardwareInput(port)) }) {
                            HStack {
                                Image(systemName: iconForPort(port))
                                Text(port.portName)
                                Spacer()
                                if case .hardwareInput(let selected) = inputSource.selectedSource,
                                   selected.uid == port.uid {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Section("AUv3 Instruments") {
                    if inputSource.availableInstruments.isEmpty {
                        Text("No AUv3 instruments installed")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(inputSource.availableInstruments, id: \.name) { component in
                            Button(action: { onSelect(.instrument(component.audioComponentDescription)) }) {
                                HStack {
                                    if let icon = component.icon {
                                        Image(uiImage: icon)
                                            .resizable()
                                            .frame(width: 28, height: 28)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        Image(systemName: "pianokeys")
                                            .frame(width: 28, height: 28)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(component.name)
                                        Text(component.manufacturerName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if case .instrument(let desc) = inputSource.selectedSource,
                                       desc.componentType == component.audioComponentDescription.componentType
                                        && desc.componentSubType == component.audioComponentDescription.componentSubType
                                        && desc.componentManufacturer == component.audioComponentDescription.componentManufacturer {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Input Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
