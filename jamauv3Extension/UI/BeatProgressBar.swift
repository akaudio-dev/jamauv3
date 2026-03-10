//
//  BeatProgressBar.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 3/10/26.
//

import SwiftUI

// MARK: - Meter Grouping Logic

/// Determines how to group BPI beats into measures for the beat progress bar.
enum MeterGrouping: Equatable {
    /// Single grouping (e.g., 16 BPI → 4 measures of 4 beats).
    case single(beatsPerMeasure: Int)
    /// Dual grouping for ambiguous BPIs (e.g., 12 BPI → show both 4/4 and 3/4).
    case dual(primary: Int, secondary: Int)

    static func forBPI(_ bpi: Int) -> MeterGrouping {
        guard bpi > 1 else { return .single(beatsPerMeasure: 1) }

        let divBy4 = bpi % 4 == 0
        let divBy3 = bpi % 3 == 0

        if divBy4 && divBy3 {
            // Ambiguous: could be 4/4 or 3/4 — show both
            return .dual(primary: 4, secondary: 3)
        } else if divBy4 {
            return .single(beatsPerMeasure: 4)
        } else {
            // Find smallest factor >= 3
            let factor = smallestFactor(of: bpi, atLeast: 3)
            return .single(beatsPerMeasure: factor)
        }
    }

    /// Smallest factor of `n` that is >= `min`. Returns `n` itself if prime.
    private static func smallestFactor(of n: Int, atLeast min: Int) -> Int {
        guard n > min else { return n }
        for f in min...n where n % f == 0 {
            return f
        }
        return n
    }
}

// MARK: - Beat Progress Bar

/// A segmented beat progress bar with measure grouping.
/// Beats fill discretely (jump, not crawl). Beat 1 is accented.
struct BeatProgressBar: View {
    let currentBeat: Int       // 0-based
    let bpi: Int
    let beatsPerMeasure: Int

    /// Colors
    private let accentColor = Color.primary            // Beat 1 of interval (black/white, always visible)
    private let filledColor = Color.green              // Past beats
    private let currentColor = Color.green.opacity(0.9) // Current beat
    private let emptyColor = Color.primary.opacity(0.15) // Future beats (visible track)

    private let measureGap: CGFloat = 4    // Gap between measures
    private let beatGap: CGFloat = 1.5     // Gap between beats within a measure

    var body: some View {
        GeometryReader { geo in
            let measureCount = beatsPerMeasure >= bpi ? 1 : bpi / beatsPerMeasure
            let remainder = bpi % beatsPerMeasure
            let totalMeasures = measureCount + (remainder > 0 ? 1 : 0)

            // Calculate available width after measure gaps
            let totalMeasureGaps = max(0, CGFloat(totalMeasures - 1)) * measureGap
            let availableWidth = geo.size.width - totalMeasureGaps

            // Each beat gets equal width (accounting for beat gaps within measures)
            let totalBeatGaps: CGFloat = {
                var gaps: CGFloat = 0
                for m in 0..<totalMeasures {
                    let beatsInThisMeasure = (m < measureCount) ? beatsPerMeasure : remainder
                    gaps += CGFloat(max(0, beatsInThisMeasure - 1)) * beatGap
                }
                return gaps
            }()

            let beatWidth = max(1, (availableWidth - totalBeatGaps) / CGFloat(bpi))

            HStack(spacing: 0) {
                ForEach(0..<totalMeasures, id: \.self) { measureIndex in
                    let beatsInMeasure = (measureIndex < measureCount) ? beatsPerMeasure : remainder

                    if measureIndex > 0 {
                        Spacer().frame(width: measureGap)
                    }

                    HStack(spacing: beatGap) {
                        ForEach(0..<beatsInMeasure, id: \.self) { beatInMeasure in
                            let globalBeat = measureIndex * beatsPerMeasure + beatInMeasure
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(beatColor(for: globalBeat))
                                .frame(width: beatWidth)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func beatColor(for beat: Int) -> Color {
        if beat == 0 && beat <= currentBeat {
            return accentColor  // Beat 1 accent (always bright when reached)
        } else if beat < currentBeat {
            return filledColor  // Past beats
        } else if beat == currentBeat {
            return beat == 0 ? accentColor : currentColor
        } else {
            return emptyColor   // Future beats
        }
    }
}

// MARK: - Preview

#Preview("16 BPI - 4/4") {
    VStack(spacing: 8) {
        BeatProgressBar(currentBeat: 5, bpi: 16, beatsPerMeasure: 4)
            .frame(height: 14)
        BeatProgressBar(currentBeat: 0, bpi: 16, beatsPerMeasure: 4)
            .frame(height: 14)
        BeatProgressBar(currentBeat: 15, bpi: 16, beatsPerMeasure: 4)
            .frame(height: 14)
    }
    .padding()
}

#Preview("12 BPI - dual") {
    VStack(spacing: 4) {
        BeatProgressBar(currentBeat: 7, bpi: 12, beatsPerMeasure: 4)
            .frame(height: 12)
        BeatProgressBar(currentBeat: 7, bpi: 12, beatsPerMeasure: 3)
            .frame(height: 12)
    }
    .padding()
}
