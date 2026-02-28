//
//  jamauv3App.swift
//  jamauv3
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI

@main
struct jamauv3App: App {
    private let hostModel = AudioUnitHostModel()

    var body: some Scene {
        WindowGroup {
            ContentView(hostModel: hostModel)
                #if os(macOS)
                .frame(width: 530, height: 560)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(before: .appTermination) {
                Button("Close") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("w", modifiers: .control)
            }
        }
        #endif
    }
}
