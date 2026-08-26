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
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var existingEntries: [FoodEntry]

    let rawInput: String
    let originalNutrition: NutritionInfo
    let initialCategory: FoodEntryCategory
    let initialMealType: FoodMealType?
    let initialEnergyUnit: EnergyUnit
    let onConfirm: (NutritionInfo, FoodEntryCategory, FoodMealType?) -> FoodEntry?

    init(
        rawInput: String,
        originalNutrition: NutritionInfo,
        initialCategory: FoodEntryCategory = .meal,
        initialMealType: FoodMealType? = nil,
        initialEnergyUnit: EnergyUnit = .kilocalorie,
        onConfirm: @escaping (NutritionInfo, FoodEntryCategory, FoodMealType?) -> FoodEntry?
    ) {
        self.rawInput = rawInput
        self.originalNutrition = originalNutrition
        self.initialCategory = initialCategory
        self.initialMealType = initialMealType
        self.initialEnergyUnit = initialEnergyUnit
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
    @State private var matchedPreferenceID: UUID?
    @State private var matchedPreferenceKind: FoodPreferenceMatchKind?
    @State private var addAsNewPreference = false
    @State private var savedPreference: FoodPreference?
    @State private var recordedEntry: FoodEntry?
    @State private var actionToastMessage: String?
    @State private var actionToastID = UUID()

    private var quantityUnit: String {
        category.quantityUnitSymbol
    }

    private var knownBrands: [String] {
        BrandSuggestionCatalog.brands(
            entries: existingEntries,
            preferences: existingPreferences
        )
    }

    private var matchedPreference: FoodPreference? {
        guard let matchedPreferenceID else { return nil }
        return existingPreferences.first { $0.id == matchedPreferenceID }
    }

    private var targetExistingPreference: FoodPreference? {
        addAsNewPreference ? nil : matchedPreference
    }

    private var isPreferenceSaved: Bool {
        savedPreference != nil
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
                }
                .padding()
            }
            .background(AppSurfaceStyle.pageBackground)
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
                applyOriginalNutrition()

                if let match = existingPreferences.bestMatch(
                    foodName: originalNutrition.foodName,
                    brand: originalNutrition.brand
                ) {
                    matchedPreferenceID = match.preference.id
                    matchedPreferenceKind = match.kind
                    savedPreference = match.preference
                    applyMatchedPreference(match.preference)
                }
            }
            .onChange(of: addAsNewPreference) { _, shouldCreateNew in
                if shouldCreateNew {
                    savedPreference = nil
                    applyOriginalNutrition()
                } else if let matchedPreference {
                    savedPreference = matchedPreference
                    applyMatchedPreference(matchedPreference)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionSection
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(.regularMaterial)
            }
        }
        .overlay {
            if let actionToastMessage {
                Text(actionToastMessage)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(Color.black.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
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

    private func applyOriginalNutrition() {
        foodName = originalNutrition.foodName
        brand = originalNutrition.brand ?? ""
        grams = String(format: "%.1f", originalNutrition.grams)
        calories = String(format: "%.0f", originalNutrition.calories)
        protein = String(format: "%.1f", originalNutrition.protein)
        carbohydrates = String(format: "%.1f", originalNutrition.carbohydrates)
        fat = String(format: "%.1f", originalNutrition.fat)
        category = initialCategory
        mealType = initialMealType ?? FoodMealType.defaultType(for: originalNutrition.entryDate)
        preferenceKeyword = originalNutrition.foodName
        preferenceDescription = "\(originalNutrition.grams.formattedGrams)\(initialCategory.quantityUnitSymbol)\(originalNutrition.foodName)"
    }

    private func applyMatchedPreference(_ preference: FoodPreference) {
        let quantity = preference.defaultGrams ?? originalNutrition.grams
        let scale = quantity > 0 ? quantity / 100 : 1

        foodName = preference.keyword
        brand = preference.brand ?? ""
        grams = String(format: "%.1f", quantity)
        calories = String(
            format: "%.0f",
            preference.resolvedCaloriesPer100.map { $0 * scale }
                ?? preference.defaultCalories
                ?? originalNutrition.calories
        )
        protein = String(
            format: "%.1f",
            preference.resolvedProteinPer100.map { $0 * scale }
                ?? preference.defaultProtein
                ?? originalNutrition.protein
        )
        carbohydrates = String(
            format: "%.1f",
            preference.resolvedCarbsPer100.map { $0 * scale }
                ?? preference.defaultCarbs
                ?? originalNutrition.carbohydrates
        )
        fat = String(
            format: "%.1f",
            preference.resolvedFatPer100.map { $0 * scale }
                ?? preference.defaultFat
                ?? originalNutrition.fat
        )
        category = preference.category
        preferenceKeyword = preference.keyword
        preferenceDescription = preference.defaultDescription
    }

    private func recordIntake() {
        focusedField = nil
        editingField = nil

        guard let entry = onConfirm(
            editedNutrition,
            category,
            category == .meal ? mealType : nil
        ) else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            recordedEntry = entry
        }
        dismiss()
    }

    private func deleteRecordedIntake() {
        focusedField = nil
        editingField = nil

        guard let recordedEntry else { return }
        modelContext.delete(recordedEntry)

        do {
            try modelContext.save()
            withAnimation(.easeInOut(duration: 0.18)) {
                self.recordedEntry = nil
            }
            showActionToast("已删除摄入")
        } catch {
            preferenceSaveMessage = error.localizedDescription
        }
    }

    private func savePreference() {
        focusedField = nil
        editingField = nil
        preferenceSaveMessage = nil

        let keyword = preferenceKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            preferenceSaveMessage = "请输入习惯关键词"
            return
        }

        if addAsNewPreference,
           existingPreferences.contains(where: { $0.matches(keyword: keyword, brand: editedNutrition.brand) }) {
            preferenceSaveMessage = "请修改习惯关键词或品牌后再新建"
            return
        }

        let nutrition = editedNutrition
        let description = preferenceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = description.isEmpty
            ? "\(Int(nutrition.grams))\(quantityUnit), \(Int(nutrition.calories))kcal"
            : description

        // Update an exact/similar match when selected; otherwise create a new habit.
        let preferenceToSave: FoodPreference
        if let existing = targetExistingPreference {
            let isSimilarMatch = matchedPreferenceKind == .similar
            // Update existing with new values
            if !isSimilarMatch {
                existing.keyword = keyword
                existing.updateBrand(nutrition.brand)
            }
            existing.category = category
            existing.energyUnit = initialEnergyUnit
            existing.defaultDescription = resolvedDescription
            existing.updateNutritionReference(
                quantity: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbs: nutrition.carbohydrates,
                fat: nutrition.fat
            )
            existing.usageCount += 1
            preferenceToSave = existing
        } else {
            // Create new with nutrition values
            let preference = FoodPreference(
                keyword: keyword,
                brand: nutrition.brand,
                defaultDescription: resolvedDescription,
                category: category,
                energyUnit: initialEnergyUnit
            )
            preference.updateNutritionReference(
                quantity: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbs: nutrition.carbohydrates,
                fat: nutrition.fat
            )
            modelContext.insert(preference)
            preferenceToSave = preference
        }

        // Save immediately so it appears in the preferences list
        do {
            try modelContext.save()
            withAnimation(.easeInOut(duration: 0.18)) {
                savedPreference = preferenceToSave
                matchedPreferenceID = preferenceToSave.id
                matchedPreferenceKind = .exact
                addAsNewPreference = false
            }
            showActionToast("已保存习惯")
        } catch {
            preferenceSaveMessage = error.localizedDescription
        }
    }

    private func deleteSavedPreference() {
        focusedField = nil
        editingField = nil
        preferenceSaveMessage = nil

        guard let savedPreference else { return }
        modelContext.delete(savedPreference)

        do {
            try modelContext.save()
            withAnimation(.easeInOut(duration: 0.18)) {
                self.savedPreference = nil
                matchedPreferenceID = nil
                matchedPreferenceKind = nil
                addAsNewPreference = false
            }
            showActionToast("已删除习惯")
        } catch {
            preferenceSaveMessage = error.localizedDescription
        }
    }

    private func showActionToast(_ message: String) {
        let toastID = UUID()
        actionToastID = toastID

        withAnimation(.easeInOut(duration: 0.2)) {
            actionToastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard actionToastID == toastID else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                actionToastMessage = nil
            }
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
                    .background(AppSurfaceStyle.formInputBackground)
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
                        .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                }
                .font(.headline)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(AppSurfaceStyle.formInputBackground)
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
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                .contentShape(Rectangle())
                .onTapGesture {
                    beginEditing(.grams)
                }
            }

            Text("原始输入: \(rawInput)")
                .font(.caption)
                .foregroundStyle(AppSurfaceStyle.formTertiaryText)

            BrandAutocompleteField(
                text: $brand,
                brands: knownBrands,
                inputBackground: AppSurfaceStyle.formInputBackground,
                textAlignment: .center
            )
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
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

            if let quantity = Double(grams), quantity > 0 {
                Divider()

                Text("单位数据")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    unitNutritionValue(title: "热量", value: calories, quantity: quantity, unit: "kcal")
                    unitNutritionValue(title: "蛋白质", value: protein, quantity: quantity, unit: "g")
                    unitNutritionValue(title: "碳水", value: carbohydrates, quantity: quantity, unit: "g")
                    unitNutritionValue(title: "脂肪", value: fat, quantity: quantity, unit: "g")
                }
            }
        }
    }

    private func unitNutritionValue(title: String, value: String, quantity: Double, unit: String) -> some View {
        let totalValue = Double(value) ?? 0
        let unitValue = totalValue * 100 / quantity

        return HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
            Spacer()
            Text("\(unitValue.formattedGrams) \(unit)/100\(quantityUnit)")
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .background(AppSurfaceStyle.formInputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppSurfaceStyle.inputBorder, lineWidth: 1)
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
                    .foregroundStyle(AppSurfaceStyle.formSecondaryText)

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
                        .foregroundStyle(AppSurfaceStyle.formSecondaryText)
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
                    .foregroundStyle(AppSurfaceStyle.formSecondaryText)

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
                        .foregroundStyle(AppSurfaceStyle.formSecondaryText)

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
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("备注")
                .font(.headline)

            Text(notes)
                .font(.subheadline)
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
    }

    private var confidenceIndicator: some View {
        HStack {
            Image(systemName: confidenceIcon)
                .foregroundStyle(confidenceColor)
            Text("置信度: \(confidenceText)")
                .font(.caption)
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)

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
                    .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                TextField("关键词，如：咖啡牛奶", text: $preferenceKeyword)
                    .textFieldStyle(.roundedBorder)

                Text("默认是指...")
                    .font(.caption)
                    .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                TextField("描述，如：150ml全脂牛奶", text: $preferenceDescription)
                    .textFieldStyle(.roundedBorder)

                if matchedPreference != nil {
                    Toggle("添加为新的食物习惯", isOn: $addAsNewPreference)
                        .font(.subheadline)
                } else {
                    Label("尚未保存到食物习惯，可新建习惯", systemImage: "heart")
                        .font(.caption)
                        .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                }
            }
            .padding(.top, 4)

            if let preferenceSaveMessage {
                Label(preferenceSaveMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button {
                if recordedEntry == nil {
                    recordIntake()
                } else {
                    deleteRecordedIntake()
                }
            } label: {
                Label(
                    recordedEntry == nil ? "记录摄入" : "删除摄入",
                    systemImage: recordedEntry == nil ? "plus.circle.fill" : "minus.circle.fill"
                )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(recordedEntry == nil ? Color.gray : Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                if isPreferenceSaved {
                    deleteSavedPreference()
                } else {
                    savePreference()
                }
            } label: {
                Label(
                    isPreferenceSaved ? "删除习惯" : "保存习惯",
                    systemImage: isPreferenceSaved ? "heart.fill" : "heart"
                )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(isPreferenceSaved || canSavePreference ? Color.pink : Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(!isPreferenceSaved && !canSavePreference)
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
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)

            HStack(spacing: 2) {
                TextField("0", text: $value)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(width: 60)

                Text(unit)
                    .font(.caption)
                    .foregroundStyle(AppSurfaceStyle.formSecondaryText)
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
        return nil
    }
}
