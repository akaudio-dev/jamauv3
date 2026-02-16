//
//  ParameterSlider.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI

/// A SwiftUI vertical Slider for user gain control with level meter
struct VerticalGainSlider: View {
    @State var param: ObservableAUParameter
    var peakLevel: Float = 0
    var username: String = ""

    var body: some View {
        VStack(spacing: 2) {
            Text(username.isEmpty ? param.displayName : username)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 1) {
                // Level meter bar
                GeometryReader { geo in
                    let clampedLevel = min(CGFloat(peakLevel), 2.0) / 2.0
                    let fillHeight = geo.size.height * clampedLevel
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(peakLevel > 1.0 ? Color.red : Color.green)
                            .frame(height: fillHeight)
                    }
                }
                .frame(width: 4)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 1))

                // Gain slider
                Slider(
                    value: $param.value,
                    in: param.min...param.max,
                    onEditingChanged: param.onEditingChanged
                )
                .frame(width: 160)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 160)
            }
            .frame(height: 160)

            Text("\(Int(param.value * 100))%")
                .font(.caption2)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
