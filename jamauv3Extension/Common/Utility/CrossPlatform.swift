// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  CrossPlatform.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import SwiftUI

#if os(iOS) || os(visionOS)
typealias HostingController = UIHostingController
#elseif os(macOS)
typealias HostingController = NSHostingController

extension NSView {
	
	func bringSubviewToFront(_ view: NSView) {
		// This function is a no-opp for macOS
	}
}
#endif
