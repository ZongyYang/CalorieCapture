import SwiftUI

struct NutritionCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)

            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)

            Text(unit)
                .font(.caption2)
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }
}

#Preview {
    HStack {
        NutritionCard(title: "Calories", value: "450", unit: "kcal", color: .orange)
        NutritionCard(title: "Protein", value: "25.5", unit: "g", color: .red)
        NutritionCard(title: "Carbs", value: "60.0", unit: "g", color: .blue)
        NutritionCard(title: "Fat", value: "15.2", unit: "g", color: .yellow)
    }
    .padding()
}
