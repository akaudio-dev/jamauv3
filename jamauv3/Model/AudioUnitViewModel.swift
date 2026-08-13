// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  AudioUnitViewModel.swift
//  jamauv3
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI
import AudioToolbox
import CoreAudioKit

struct AudioUnitViewModel {
    var showAudioControls: Bool = false
    var showMIDIContols: Bool = false
    var title: String = "-"
    var message: String = "No Audio Unit loaded.."
    var viewController: ViewController?
    var isLoaded: Bool = false
}
