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
        }
    }
}
