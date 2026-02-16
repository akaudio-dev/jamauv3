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
        VStack(spacing: 2) {
            Text(param.displayName)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Slider(
                value: $param.value,
                in: param.min...param.max,
                onEditingChanged: param.onEditingChanged
            )
            .frame(width: 160)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 160)

            Text("\(Int(param.value * 100))%")
                .font(.caption2)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
