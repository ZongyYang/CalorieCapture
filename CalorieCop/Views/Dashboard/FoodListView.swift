import SwiftUI
import SwiftData

struct FoodListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]
    @Query private var foodPreferences: [FoodPreference]

    @State private var entryToEdit: FoodEntry?
    @State private var showingAllEntries = false
    @State private var autofillingNutritionEntryID: UUID?
    @State private var nutritionAutofillMessage: String?
    @State private var showingSettings = false

    private let collapsedEntryLimit = 3
    private let nutritionAutofillService = NutritionAutofillService()

    private var todayEntries: [FoodEntry] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return allEntries.filter { $0.createdAt >= startOfDay }
    }

    private var visibleEntries: [FoodEntry] {
        showingAllEntries ? todayEntries : Array(todayEntries.prefix(collapsedEntryLimit))
    }

    var body: some View {
        Group {
            if todayEntries.isEmpty {
                emptyState
            } else {
                foodList
            }
        }
        .sheet(item: $entryToEdit) { entry in
            FoodEntryEditView(entry: entry)
        }
        .sheet(isPresented: $showingSettings) {
            AppSettingsView()
        }
        .alert(
            "营养补全",
            isPresented: Binding(
                get: { nutritionAutofillMessage != nil },
                set: { if !$0 { nutritionAutofillMessage = nil } }
            )
        ) {
            Button("好的", role: .cancel) {
                nutritionAutofillMessage = nil
            }
        } message: {
            Text(nutritionAutofillMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("今天还没有记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击下方按钮记录你的第一餐")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var foodList: some View {
        VStack(spacing: 12) {
            ForEach(visibleEntries) { entry in
                SwipeableFoodEntryRow(
                    entry: entry,
                    showsPreferenceControl: true,
                    isSavedAsPreference: isSavedAsPreference(entry),
                    isAutofillingNutrition: autofillingNutritionEntryID == entry.id,
                    inlineActionDeletes: true,
                    onEdit: {
                        entryToEdit = entry
                    },
                    onTogglePreference: {
                        togglePreference(for: entry)
                    },
                    onAutofillNutrition: {
                        autofillNutrition(for: entry)
                    },
                    onDelete: {
                        deleteEntry(entry)
                    }
                )
                .contextMenu {
                    Button {
                        autofillNutrition(for: entry)
                    } label: {
                        Label("AI识别", systemImage: "sparkles")
                    }

                    Button {
                        entryToEdit = entry
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        deleteEntry(entry)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            if todayEntries.count > collapsedEntryLimit {
                FoodEntryListExpansionButton(
                    isExpanded: showingAllEntries,
                    totalCount: todayEntries.count
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingAllEntries.toggle()
                    }
                }
            }
        }
    }

    private func autofillNutrition(for entry: FoodEntry) {
        guard autofillingNutritionEntryID == nil else { return }
        autofillingNutritionEntryID = entry.id

        Task {
            do {
                let shouldEstimateQuantity = entry.grams <= 0
                let estimate = try await nutritionAutofillService.estimateUnitNutrition(
                    for: entry,
                    preferences: foodPreferences
                )
                let quantity = entry.grams > 0 ? entry.grams : estimate.estimatedQuantity
                entry.grams = quantity
                let scale = quantity / 100
                entry.protein = estimate.proteinPer100 * scale
                entry.carbohydrates = estimate.carbsPer100 * scale
                entry.fat = estimate.fatPer100 * scale
                entry.nutritionEstimatedByAI = true
                updatePreferenceNutrition(for: entry, estimate: estimate)
                try modelContext.save()
                nutritionAutofillMessage = shouldEstimateQuantity
                    ? "已估算摄入量，并填入蛋白质、碳水和脂肪。"
                    : "已按当前摄入量填入蛋白质、碳水和脂肪。"
            } catch {
                if let aiError = error as? AIServiceError,
                   case .apiKeyNotConfigured = aiError {
                    showingSettings = true
                }
                nutritionAutofillMessage = error.localizedDescription
            }
            autofillingNutritionEntryID = nil
        }
    }

    private func deleteEntry(_ entry: FoodEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func updatePreferenceNutrition(for entry: FoodEntry, estimate: UnitNutritionEstimate) {
        guard let preference = foodPreferences.first(where: {
            $0.matches(keyword: entry.foodName, brand: entry.brand)
        }) else { return }

        if preference.proteinPer100 == nil || preference.proteinPer100 == 0 {
            preference.proteinPer100 = estimate.proteinPer100
        }
        if preference.carbsPer100 == nil || preference.carbsPer100 == 0 {
            preference.carbsPer100 = estimate.carbsPer100
        }
        if preference.fatPer100 == nil || preference.fatPer100 == 0 {
            preference.fatPer100 = estimate.fatPer100
        }
    }

    private func isSavedAsPreference(_ entry: FoodEntry) -> Bool {
        preference(for: entry) != nil
    }

    private func preference(for entry: FoodEntry) -> FoodPreference? {
        foodPreferences.first {
            $0.matches(keyword: entry.foodName, brand: entry.brand)
        }
    }

    private func togglePreference(for entry: FoodEntry) {
        if let existing = preference(for: entry) {
            modelContext.delete(existing)
        } else {
            let preference = FoodPreference(
                keyword: entry.foodName,
                brand: entry.brand,
                defaultDescription: "\(entry.grams.formattedGrams)\(entry.category.quantityUnitSymbol), \(entry.displayedEnergy.formattedCalories)\(entry.energyUnit.symbol)",
                category: entry.category,
                energyUnit: entry.energyUnit
            )
            preference.updateNutritionReference(
                quantity: entry.grams,
                calories: entry.calories,
                protein: entry.protein,
                carbs: entry.carbohydrates,
                fat: entry.fat
            )
            modelContext.insert(preference)
        }

        try? modelContext.save()
    }
}

#Preview {
    FoodListView()
        .modelContainer(for: [FoodEntry.self, FoodPreference.self], inMemory: true)
}
