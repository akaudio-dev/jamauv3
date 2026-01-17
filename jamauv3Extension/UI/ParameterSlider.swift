//
//  ParameterSlider.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI

/// A SwiftUI vertical Slider for user gain control
struct VerticalGainSlider: View {
    @State var param: ObservableAUParameter

    var body: some View {
        VStack(spacing: 4) {
            Text(param.displayName)
                .font(.caption2)
                .lineLimit(1)

            Slider(
                value: $param.value,
                in: param.min...param.max,
                onEditingChanged: param.onEditingChanged
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 100)

            Text("\(Int(param.value * 100))%")
                .font(.caption2)
                .monospacedDigit()
        }
        .frame(width: 44)
    }
}
