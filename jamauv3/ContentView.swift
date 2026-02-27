//
//  ContentView.swift
//  jamauv3
//

import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel

    var body: some View {
        if let viewController = hostModel.viewModel.viewController {
            AUViewControllerUI(viewController: viewController)
        } else if hostModel.viewModel.isLoaded {
            Text(hostModel.viewModel.message)
                .foregroundColor(.red)
        } else {
            ProgressView("Loading…")
        }
    }
}
