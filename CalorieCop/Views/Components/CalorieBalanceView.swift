import SwiftUI

enum AppSurfaceStyle {
    static let pageBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black
            : UIColor.systemGroupedBackground
    })

    static let cardBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGray6
            : UIColor.systemBackground
    })

    // Grouped form modules sit one level above the page background and below
    // their white/light input surfaces, matching the record form hierarchy.
    static let moduleBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGray6
            : UIColor.systemGray5
    })
}

struct CalorieBalanceView<SupplementaryContent: View>: View {
    let consumed: Double
    let burned: Double
    var targetDeficit: Double? = nil  // The planned daily calorie deficit to reach weight goal
    let supplementaryContent: SupplementaryContent

    init(
        consumed: Double,
        burned: Double,
        targetDeficit: Double? = nil,
        @ViewBuilder supplementaryContent: () -> SupplementaryContent
    ) {
        self.consumed = consumed
        self.burned = burned
        self.targetDeficit = targetDeficit
        self.supplementaryContent = supplementaryContent()
    }

    // Current signed deficit. Positive means burned more than consumed;
    // negative means consumed more than burned.
    var currentDeficit: Double {
        burned - consumed
    }

    var isDeficit: Bool {
        currentDeficit >= 0
    }

    // Positive means the current deficit has not reached the target yet.
    // Negative means the current deficit is larger than the target deficit.
    private var targetDeficitDelta: Double? {
        guard let deficit = targetDeficit else { return nil }
        return deficit - currentDeficit
    }

    private var currentDeficitLabel: String {
        isDeficit ? "缺口" : "超出"
    }

    @ViewBuilder
    private var targetDeficitStatusLabel: some View {
        if let delta = targetDeficitDelta {
            let distance = abs(delta)

            if distance < 0.5 {
                Label("已达到目标缺口", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            } else if delta > 0 {
                Label("距目标缺口还差 \(Int(distance.rounded())) kcal", systemImage: "hourglass")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
            } else {
                Label("已超过目标缺口 \(Int(distance.rounded())) kcal", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            supplementaryContent

            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Image(systemName: "fork.knife")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(consumed.formattedCalories)
                        .font(.title)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("摄入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)

                Image(systemName: "minus")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(burned.formattedCalories)
                        .font(.title)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)

                Image(systemName: "equal")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Image(systemName: isDeficit ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isDeficit ? .green : .red)
                    Text(abs(currentDeficit).formattedCalories)
                        .font(.title)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isDeficit ? .green : .red)
                    Text(currentDeficitLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)
            }

            // Compare the signed current deficit with the planned target deficit.
            if let deficit = targetDeficit {
                Divider()

                HStack {
                    targetDeficitStatusLabel

                    Spacer()

                    Text("目标缺口 \(Int(deficit)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

extension CalorieBalanceView where SupplementaryContent == EmptyView {
    init(consumed: Double, burned: Double, targetDeficit: Double? = nil) {
        self.init(consumed: consumed, burned: burned, targetDeficit: targetDeficit) {
            EmptyView()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CalorieBalanceView(consumed: 1200, burned: 2000)
        CalorieBalanceView(consumed: 2500, burned: 2000)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
