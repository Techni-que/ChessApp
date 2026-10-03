import SwiftUI

/// A vertical bar showing who's winning: the white part grows when White is better.
struct EvalBarView: View {
    let evaluation: Evaluation?

    var body: some View {
        GeometryReader { geo in
            let share = evaluation?.whiteShare ?? 0.5
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(white: 0.2))
                Rectangle()
                    .fill(Color(white: 0.95))
                    .frame(height: geo.size.height * share)
            }
            .animation(.easeInOut(duration: 0.25), value: share)
        }
        .frame(width: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
        .accessibilityElement()
        .accessibilityLabel("Evaluation")
        .accessibilityValue(evaluation?.text ?? "Not analysed yet")
    }
}
