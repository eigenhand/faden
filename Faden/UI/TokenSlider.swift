import SwiftUI

/// A slider for token counts.
///
/// Token ranges span three orders of magnitude, so a linear slider spends most of its
/// travel in values nobody picks. This maps the position logarithmically, which gives
/// the small end the room it needs and still reaches the ceiling.
struct TokenSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int>
    /// Shown under the slider, e.g. where the ceiling comes from.
    var footnote: String?

    private var position: Binding<Double> {
        Binding(
            get: {
                let lo = log(Double(max(range.lowerBound, 1)))
                let hi = log(Double(max(range.upperBound, range.lowerBound + 1)))
                let v = log(Double(min(max(value, range.lowerBound), range.upperBound)))
                return hi > lo ? (v - lo) / (hi - lo) : 0
            },
            set: { p in
                let lo = log(Double(max(range.lowerBound, 1)))
                let hi = log(Double(max(range.upperBound, range.lowerBound + 1)))
                let raw = exp(lo + p * (hi - lo))
                value = Self.round(raw, within: range)
            }
        )
    }

    /// Snaps to values people recognise instead of 8_137.
    private static func round(_ raw: Double, within range: ClosedRange<Int>) -> Int {
        let step: Double
        switch raw {
        case ..<2_000:      step = 128
        case ..<16_000:     step = 512
        case ..<128_000:    step = 1_000
        case ..<1_000_000:  step = 5_000
        default:            step = 50_000
        }
        let snapped = (raw / step).rounded() * step
        return min(max(Int(snapped), range.lowerBound), range.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(EH.bodySmall).foregroundStyle(EH.slate)
                Spacer()
                Text(value.formatted(.number.grouping(.automatic)))
                    .font(EH.mono)
                    .monospacedDigit()
                    .foregroundStyle(EH.navy)
                    .contentTransition(.numericText())
            }
            Slider(value: position, in: 0...1)
                .tint(EH.navy)
            HStack {
                Text(RemoteModel.compact(range.lowerBound))
                Spacer()
                if let footnote { Text(footnote).multilineTextAlignment(.center) }
                Spacer()
                Text(RemoteModel.compact(range.upperBound))
            }
            .font(.eh(10, .caption2))
            .foregroundStyle(EH.muted)
        }
    }
}
