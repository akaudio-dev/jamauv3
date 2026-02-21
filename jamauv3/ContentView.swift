//
//  ContentView.swift
//  jamauv3
//

import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel

    var body: some View {
        if hostModel.audioUnitCrashed {
            Text("Audio Unit crashed.")
                .foregroundColor(.red)
                .frame(minWidth: 300, minHeight: 400)
        } else if let viewController = hostModel.viewModel.viewController {
            AUViewControllerUI(viewController: viewController)
        } else {
            ProgressView("Loading…")
                .frame(minWidth: 300, minHeight: 400)
        }
    }
}
