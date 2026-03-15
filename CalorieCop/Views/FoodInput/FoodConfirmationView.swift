import SwiftUI
import SwiftData

struct FoodConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]

    let rawInput: String
    let originalNutrition: NutritionInfo
    let onConfirm: (NutritionInfo) -> Void

    // Editable fields
    @State private var foodName: String = ""
    @State private var grams: String = ""
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var carbohydrates: String = ""
    @State private var fat: String = ""

    @State private var isEditing = false
    @State private var saveAsPreference = false
    @State private var preferenceKeyword = ""
    @State private var preferenceDescription = ""

    private var hasExistingPreference: Bool {
        existingPreferences.contains { $0.keyword.lowercased() == preferenceKeyword.lowercased() }
    }

    private var editedNutrition: NutritionInfo {
        NutritionInfo(
            foodName: foodName,
            grams: Double(grams) ?? originalNutrition.grams,
            calories: Double(calories) ?? originalNutrition.calories,
            protein: Double(protein) ?? originalNutrition.protein,
            carbohydrates: Double(carbohydrates) ?? originalNutrition.carbohydrates,
            fat: Double(fat) ?? originalNutrition.fat,
            confidence: isEditing ? "manual" : originalNutrition.confidence,
            notes: isEditing ? "用户手动调整" : originalNutrition.notes,
            daysAgo: originalNutrition.daysAgo
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection

                    nutritionSection

                    if !isEditing, let notes = originalNutrition.notes, !notes.isEmpty {
                        notesSection(notes)
                    }

                    confidenceIndicator

                    // Save as preference section
                    preferenceSection
                }
                .padding()
            }
            .navigationTitle("确认食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        if saveAsPreference && !preferenceKeyword.isEmpty {
                            savePreference()
                        }
                        onConfirm(editedNutrition)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Initialize editable fields from original nutrition
                foodName = originalNutrition.foodName
                grams = String(format: "%.1f", originalNutrition.grams)
                calories = String(format: "%.0f", originalNutrition.calories)
                protein = String(format: "%.1f", originalNutrition.protein)
                carbohydrates = String(format: "%.1f", originalNutrition.carbohydrates)
                fat = String(format: "%.1f", originalNutrition.fat)

                // Pre-fill preference fields
                preferenceKeyword = originalNutrition.foodName
                preferenceDescription = "\(originalNutrition.grams.formattedGrams)g\(originalNutrition.foodName)"
            }
        }
    }

    private func savePreference() {
        let nutrition = editedNutrition

        // Check if preference already exists
        if let existing = existingPreferences.first(where: { $0.keyword.lowercased() == preferenceKeyword.lowercased() }) {
            // Update existing with new values
            existing.defaultDescription = preferenceDescription
            existing.defaultGrams = nutrition.grams
            existing.defaultCalories = nutrition.calories
            existing.defaultProtein = nutrition.protein
            existing.defaultCarbs = nutrition.carbohydrates
            existing.defaultFat = nutrition.fat
            existing.usageCount += 1
        } else {
            // Create new with nutrition values
            let preference = FoodPreference(
                keyword: preferenceKeyword,
                grams: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbs: nutrition.carbohydrates,
                fat: nutrition.fat
            )
            modelContext.insert(preference)
        }

        // Save immediately so it appears in the preferences list
        try? modelContext.save()
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            if isEditing {
                TextField("食物名称", text: $foodName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            } else {
                Text(foodName)
                    .font(.title2)
                    .fontWeight(.bold)
            }

            if isEditing {
                HStack {
                    TextField("克重", text: $grams)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("g")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(grams)g")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Text("原始输入: \(rawInput)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Edit toggle button
            Button {
                withAnimation {
                    isEditing.toggle()
                }
            } label: {
                Label(isEditing ? "完成编辑" : "手动调整", systemImage: isEditing ? "checkmark.circle" : "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(isEditing ? .green : .blue)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var nutritionSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("营养成分")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Text("点击数值可编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if isEditing {
                    EditableNutritionCard(
                        title: "热量",
                        value: $calories,
                        unit: "kcal",
                        color: .orange
                    )
                    EditableNutritionCard(
                        title: "蛋白质",
                        value: $protein,
                        unit: "g",
                        color: .red
                    )
                } else {
                    NutritionCard(
                        title: "热量",
                        value: calories,
                        unit: "kcal",
                        color: .orange
                    )
                    NutritionCard(
                        title: "蛋白质",
                        value: protein,
                        unit: "g",
                        color: .red
                    )
                }
            }

            HStack(spacing: 12) {
                if isEditing {
                    EditableNutritionCard(
                        title: "碳水",
                        value: $carbohydrates,
                        unit: "g",
                        color: .blue
                    )
                    EditableNutritionCard(
                        title: "脂肪",
                        value: $fat,
                        unit: "g",
                        color: .yellow
                    )
                } else {
                    NutritionCard(
                        title: "碳水",
                        value: carbohydrates,
                        unit: "g",
                        color: .blue
                    )
                    NutritionCard(
                        title: "脂肪",
                        value: fat,
                        unit: "g",
                        color: .yellow
                    )
                }
            }
        }
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备注")
                .font(.headline)

            Text(notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var confidenceIndicator: some View {
        HStack {
            Image(systemName: confidenceIcon)
                .foregroundStyle(confidenceColor)
            Text("置信度: \(confidenceText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isEditing {
                Text("(手动调整)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var confidenceIcon: String {
        if isEditing { return "hand.raised.fill" }
        switch originalNutrition.confidence {
        case "high": return "checkmark.circle.fill"
        case "medium": return "questionmark.circle.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var confidenceColor: Color {
        if isEditing { return .blue }
        switch originalNutrition.confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }

    private var confidenceText: String {
        if isEditing { return "手动" }
        switch originalNutrition.confidence {
        case "high": return "高"
        case "medium": return "中"
        default: return "低"
        }
    }

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $saveAsPreference) {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                    Text("记住这个习惯")
                        .font(.subheadline)
                }
            }

            if saveAsPreference {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当我说...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("关键词，如：咖啡牛奶", text: $preferenceKeyword)
                        .textFieldStyle(.roundedBorder)

                    Text("默认是指...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("描述，如：150ml全脂牛奶", text: $preferenceDescription)
                        .textFieldStyle(.roundedBorder)

                    if hasExistingPreference {
                        Label("将更新现有的习惯设定", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Editable Nutrition Card

struct EditableNutritionCard: View {
    let title: String
    @Binding var value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                TextField("0", text: $value)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(width: 60)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    FoodConfirmationView(
        rawInput: "一碗米饭",
        originalNutrition: NutritionInfo(
            foodName: "米饭",
            grams: 200,
            calories: 232,
            protein: 4.3,
            carbohydrates: 50.8,
            fat: 0.6,
            confidence: "high",
            notes: "按照普通家用碗估算份量"
        )
    ) { nutrition in
        print("Confirmed: \(nutrition.foodName)")
    }
}
