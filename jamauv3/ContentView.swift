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
            let instrumentMaximized = hostModel.inputSource.isInstrumentMaximized
                && hostModel.inputSource.isShowingInstrumentUI
            if !instrumentMaximized {
                InputSourceBar(
                    inputSource: hostModel.inputSource,
                    onSelect: { source in
                        hostModel.switchInputSource(to: source)
                    }
                )
                Divider()
            }
            #endif

            #if os(iOS) || os(visionOS)
            let hideMainView = instrumentMaximized
            #else
            let hideMainView = false
            #endif

            if !hideMainView {
                if let viewController = hostModel.viewModel.viewController {
                    AUViewControllerUI(viewController: viewController)
                } else if hostModel.viewModel.isLoaded {
                    Text(hostModel.viewModel.message)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Loading\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            #if os(iOS) || os(visionOS)
            if hostModel.inputSource.isShowingInstrumentUI,
               let instVC = hostModel.inputSource.instrumentViewController {
                if !instrumentMaximized { Divider() }
                InstrumentViewPanel(
                    viewController: instVC,
                    isShowing: Binding(
                        get: { hostModel.inputSource.isShowingInstrumentUI },
                        set: { hostModel.inputSource.isShowingInstrumentUI = $0 }
                    ),
                    isMaximized: Binding(
                        get: { hostModel.inputSource.isInstrumentMaximized },
                        set: { hostModel.inputSource.isInstrumentMaximized = $0 }
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
    @Binding var isMaximized: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Instrument")
                    .font(.callout.bold())
                Spacer()
                Button(action: { withAnimation { isMaximized.toggle() } }) {
                    Image(systemName: isMaximized
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                Button(action: {
                    isMaximized = false
                    isShowing = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            AUViewControllerUI(viewController: viewController)
                .frame(maxHeight: isMaximized ? .infinity : 300)
        }
    }
}

#endif
