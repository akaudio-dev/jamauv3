//
//  ContentView.swift
//  jamauv3
//

import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS) || os(visionOS)
            InputSourceBar(
                inputSource: hostModel.inputSource,
                onSelect: { source in
                    hostModel.switchInputSource(to: source)
                }
            )
            Divider()
            #endif

            if let viewController = hostModel.viewModel.viewController {
                AUViewControllerUI(viewController: viewController)
            } else if hostModel.viewModel.isLoaded {
                Text(hostModel.viewModel.message)
                    .foregroundColor(.red)
            } else {
                ProgressView("Loading\u{2026}")
            }

            #if os(iOS) || os(visionOS)
            if hostModel.inputSource.isShowingInstrumentUI,
               let instVC = hostModel.inputSource.instrumentViewController {
                Divider()
                InstrumentViewPanel(
                    viewController: instVC,
                    isShowing: Binding(
                        get: { hostModel.inputSource.isShowingInstrumentUI },
                        set: { hostModel.inputSource.isShowingInstrumentUI = $0 }
                    )
                )
            }
            #endif
        }
    }
}

// MARK: - Instrument View Panel (iOS)

#if os(iOS) || os(visionOS)

struct InstrumentViewPanel: View {
    let viewController: UIViewController
    @Binding var isShowing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Instrument")
                    .font(.callout.bold())
                Spacer()
                Button(action: { isShowing = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            AUViewControllerUI(viewController: viewController)
                .frame(height: 300)
        }
    }
}

#endif
