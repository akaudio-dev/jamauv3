// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  Parameters.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import AudioToolbox

let jamauv3ExtensionParameterSpecs = ParameterTreeSpec {
    ParameterGroupSpec(identifier: "users", name: "User Gains") {
        for i in 0..<Int(jamauv3ExtensionNumUsers) {
            ParameterSpec(
                address: jamauv3ExtensionParameterAddress_userGainBase + AUParameterAddress(i),
                identifier: "userGain\(i)",
                name: "User \(i + 1)",
                units: .linearGain,
                valueRange: 0.0...2.0,
                defaultValue: 1.0
            )
        }
    }
    ParameterGroupSpec(identifier: "system", name: "System") {
        ParameterSpec(
            address: jamauv3ExtensionParameterAddress_needsAudio,
            identifier: "needsAudio",
            name: "Needs Audio",
            units: .boolean,
            valueRange: 0.0...1.0,
            defaultValue: 0.0,
            flags: [.flag_IsWritable, .flag_IsReadable]
        )
    }
}
