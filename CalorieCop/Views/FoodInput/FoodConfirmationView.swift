import SwiftUI
import SwiftData

private enum ConfirmationEditField: Hashable {
    case foodName
    case grams
    case calories
    case protein
    case carbohydrates
    case fat
}

struct FoodConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]

    let rawInput: String
    let originalNutrition: NutritionInfo
    let initialCategory: FoodEntryCategory
    let initialMealType: FoodMealType?
    let onConfirm: (NutritionInfo, FoodEntryCategory, FoodMealType?) -> Void

    init(
        rawInput: String,
        originalNutrition: NutritionInfo,
        initialCategory: FoodEntryCategory = .meal,
        initialMealType: FoodMealType? = nil,
        onConfirm: @escaping (NutritionInfo, FoodEntryCategory, FoodMealType?) -> Void
    ) {
        self.rawInput = rawInput
        self.originalNutrition = originalNutrition
        self.initialCategory = initialCategory
        self.initialMealType = initialMealType
        self.onConfirm = onConfirm
    }

    // Editable fields
    @State private var foodName: String = ""
    @State private var brand: String = ""
    @State private var grams: String = ""
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var carbohydrates: String = ""
    @State private var fat: String = ""
    @State private var category: FoodEntryCategory = .meal
    @State private var mealType: FoodMealType = .lunch

    @State private var editingField: ConfirmationEditField?
    @FocusState private var focusedField: ConfirmationEditField?
    @State private var preferenceKeyword = ""
    @State private var preferenceDescription = ""
    @State private var preferenceSaveMessage: String?

    private var quantityUnit: String {
        category.quantityUnitSymbol
    }

    private var hasExistingPreference: Bool {
        let keyword = preferenceKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return existingPreferences.contains { $0.matches(keyword: keyword, brand: brand) }
    }

    private var canSavePreference: Bool {
        !preferenceKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasManualChanges: Bool {
        foodName.trimmingCharacters(in: .whitespacesAndNewlines) != originalNutrition.foodName
            || normalizedOptionalText(brand) != normalizedOptionalText(originalNutrition.brand)
            || numberChanged(grams, from: originalNutrition.grams)
            || numberChanged(calories, from: originalNutrition.calories)
            || numberChanged(protein, from: originalNutrition.protein)
            || numberChanged(carbohydrates, from: originalNutrition.carbohydrates)
            || numberChanged(fat, from: originalNutrition.fat)
    }

    private var editedNutrition: NutritionInfo {
        NutritionInfo(
            foodName: foodName,
            brand: brand,
            grams: Double(grams) ?? originalNutrition.grams,
            calories: Double(calories) ?? originalNutrition.calories,
            protein: Double(protein) ?? originalNutrition.protein,
            carbohydrates: Double(carbohydrates) ?? originalNutrition.carbohydrates,
            fat: Double(fat) ?? originalNutrition.fat,
            confidence: hasManualChanges ? "manual" : originalNutrition.confidence,
            notes: hasManualChanges ? "用户手动调整" : originalNutrition.notes,
            daysAgo: originalNutrition.daysAgo
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection

                    nutritionSection

                    categorySection

                    if !hasManualChanges, let notes = originalNutrition.notes, !notes.isEmpty {
                        notesSection(notes)
                    }

                    confidenceIndicator

                    // Save as preference section
                    preferenceSection

                    actionSection
                }
                .padding()
            }
            .navigationTitle("识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        finishEditing()
                    }
                }
            }
            .onAppear {
                // Initialize editable fields from original nutrition
                foodName = originalNutrition.foodName
                brand = originalNutrition.brand ?? ""
                grams = String(format: "%.1f", originalNutrition.grams)
                calories = String(format: "%.0f", originalNutrition.calories)
                protein = String(format: "%.1f", originalNutrition.protein)
                carbohydrates = String(format: "%.1f", originalNutrition.carbohydrates)
                fat = String(format: "%.1f", originalNutrition.fat)
                category = initialCategory
                mealType = initialMealType ?? FoodMealType.defaultType(for: originalNutrition.entryDate)

                // Pre-fill preference fields
                preferenceKeyword = originalNutrition.foodName
                preferenceDescription = "\(originalNutrition.grams.formattedGrams)\(quantityUnit)\(originalNutrition.foodName)"
            }
        }
    }

    private func beginEditing(_ field: ConfirmationEditField) {
        editingField = field
        DispatchQueue.main.async {
            focusedField = field
        }
    }

    private func finishEditing() {
        focusedField = nil
        editingField = nil
    }

    private func numberChanged(_ text: String, from originalValue: Double) -> Bool {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return abs(value - originalValue) > 0.05
    }

    private func normalizedOptionalText(_ text: String?) -> String? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private func recordIntake() {
        focusedField = nil
        editingField = nil
        onConfirm(
            editedNutrition,
            category,
            category == .meal ? mealType : nil
        )
        dismiss()
    }

    private func savePreference() {
        focusedField = nil
        editingField = nil

        let keyword = preferenceKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            preferenceSaveMessage = "请输入习惯关键词"
            return
        }

        let nutrition = editedNutrition
        let description = preferenceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = description.isEmpty
            ? "\(Int(nutrition.grams))\(quantityUnit), \(Int(nutrition.calories))kcal"
            : description

        // Check if preference already exists
        if let existing = existingPreferences.first(where: { $0.matches(keyword: keyword, brand: nutrition.brand) }) {
            // Update existing with new values
            existing.keyword = keyword
            existing.updateBrand(nutrition.brand)
            existing.defaultDescription = resolvedDescription
            existing.defaultGrams = nutrition.grams
            existing.defaultCalories = nutrition.calories
            existing.defaultProtein = nutrition.protein
            existing.defaultCarbs = nutrition.carbohydrates
            existing.defaultFat = nutrition.fat
            existing.usageCount += 1
            preferenceSaveMessage = "已更新食物习惯"
        } else {
            // Create new with nutrition values
            let preference = FoodPreference(keyword: keyword, brand: nutrition.brand, defaultDescription: resolvedDescription)
            preference.defaultGrams = nutrition.grams
            preference.defaultCalories = nutrition.calories
            preference.defaultProtein = nutrition.protein
            preference.defaultCarbs = nutrition.carbohydrates
            preference.defaultFat = nutrition.fat
            modelContext.insert(preference)
            preferenceSaveMessage = "已保存食物习惯"
        }

        // Save immediately so it appears in the preferences list
        do {
            try modelContext.save()
        } catch {
            preferenceSaveMessage = error.localizedDescription
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            if editingField == .foodName {
                TextField("食物名称", text: $foodName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .foodName)
                    .submitLabel(.done)
                    .onSubmit {
                        finishEditing()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 240)
                    .background(Color(.systemBackground).opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    }
            } else {
                Text(foodName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        beginEditing(.foodName)
                    }
            }

            if editingField == .grams {
                HStack(spacing: 8) {
                    TextField("摄入量", text: $grams)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .grams)
                        .frame(width: 76)
                    Text(quantityUnit)
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.systemBackground).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                }
            } else {
                HStack(spacing: 4) {
                    Text(grams)
                    Text(quantityUnit)
                }
                .font(.headline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    beginEditing(.grams)
                }
            }

            Text("原始输入: \(rawInput)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("品牌（可选）", text: $brand)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: 240)
                .background(Color(.systemBackground).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
            }

            HStack(spacing: 12) {
                nutritionValueCard(
                    title: "热量",
                    value: $calories,
                    unit: "kcal",
                    color: .orange,
                    field: .calories
                )
                nutritionValueCard(
                    title: "蛋白质",
                    value: $protein,
                    unit: "g",
                    color: .red,
                    field: .protein
                )
            }

            HStack(spacing: 12) {
                nutritionValueCard(
                    title: "碳水",
                    value: $carbohydrates,
                    unit: "g",
                    color: .blue,
                    field: .carbohydrates
                )
                nutritionValueCard(
                    title: "脂肪",
                    value: $fat,
                    unit: "g",
                    color: .yellow,
                    field: .fat
                )
            }
        }
    }

    @ViewBuilder
    private func nutritionValueCard(
        title: String,
        value: Binding<String>,
        unit: String,
        color: Color,
        field: ConfirmationEditField
    ) -> some View {
        if editingField == field {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 2) {
                    TextField("0", text: value)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .focused($focusedField, equals: field)
                        .frame(width: 64)

                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.35), lineWidth: 1.5)
            }
        } else {
            NutritionCard(
                title: title,
                value: value.wrappedValue,
                unit: unit,
                color: color
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                beginEditing(field)
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分类")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("类型")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Picker("类型", selection: $category) {
                    ForEach(FoodEntryCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.systemImage)
                            .tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }

            if category == .meal {
                VStack(alignment: .leading, spacing: 8) {
                    Text("餐次")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Picker("餐次", selection: $mealType) {
                        ForEach(FoodMealType.allCases) { mealType in
                            Label(mealType.rawValue, systemImage: mealType.systemImage)
                                .tag(mealType)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

            if hasManualChanges {
                Text("(手动调整)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var confidenceIcon: String {
        if hasManualChanges { return "hand.raised.fill" }
        switch originalNutrition.confidence {
        case "high": return "checkmark.circle.fill"
        case "medium": return "questionmark.circle.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var confidenceColor: Color {
        if hasManualChanges { return .blue }
        switch originalNutrition.confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }

    private var confidenceText: String {
        if hasManualChanges { return "手动" }
        switch originalNutrition.confidence {
        case "high": return "高"
        case "medium": return "中"
        default: return "低"
        }
    }

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                Text("食物习惯")
                    .font(.headline)
                Spacer()
            }

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

            if let preferenceSaveMessage {
                Label(preferenceSaveMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(preferenceSaveMessage.hasPrefix("已") ? .green : .red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button {
                savePreference()
            } label: {
                Label(hasExistingPreference ? "更新习惯" : "保存习惯", systemImage: "heart.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(canSavePreference ? Color.pink : Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(!canSavePreference)

            Button {
                recordIntake()
            } label: {
                Label("记录摄入", systemImage: "plus.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
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
    ) { nutrition, category, mealType in
        print("Confirmed: \(nutrition.foodName), \(category.rawValue), \(mealType?.rawValue ?? "")")
    }
}
