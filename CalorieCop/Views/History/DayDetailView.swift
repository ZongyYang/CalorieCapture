import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct DayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var healthKitService = HealthKitService()
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Query private var foodPreferences: [FoodPreference]

    let date: Date
    let energyBurned: DailyEnergyBurned?
    @State private var entries: [FoodEntry]
    @State private var entryToEdit: FoodEntry?
    @State private var fetchedEnergyBurned: DailyEnergyBurned?
    @State private var showingBackfillSheet = false
    @State private var showingAIAdvisor = false
    @State private var showingSettings = false
    @State private var showingDailyBriefing = false
    @State private var showingAllFoodEntries = false
    @State private var isPreparingDailyBriefing = false
    @State private var dailyBriefingAIStatus: String?
    @State private var autofillingNutritionEntryID: UUID?
    @State private var nutritionAutofillMessage: String?

    private let collapsedFoodEntryLimit = 3
    private let aiService = MiniMaxService()
    private let nutritionAutofillService = NutritionAutofillService()

    init(date: Date, entries: [FoodEntry], energyBurned: DailyEnergyBurned? = nil) {
        self.date = date
        self.energyBurned = energyBurned
        self._entries = State(initialValue: entries)
    }

    private var totalCalories: Double {
        entries.reduce(0) { $0 + $1.calories }
    }

    private var totalProtein: Double {
        entries.reduce(0) { $0 + $1.protein }
    }

    private var totalCarbs: Double {
        entries.reduce(0) { $0 + $1.carbohydrates }
    }

    private var totalFat: Double {
        entries.reduce(0) { $0 + $1.fat }
    }

    private var sortedFoodEntries: [FoodEntry] {
        entries.sorted { $0.createdAt < $1.createdAt }
    }

    private var visibleFoodEntries: [FoodEntry] {
        showingAllFoodEntries
            ? sortedFoodEntries
            : Array(sortedFoodEntries.prefix(collapsedFoodEntryLimit))
    }

    private var displayedEnergyBurned: DailyEnergyBurned? {
        fetchedEnergyBurned ?? energyBurned
    }

    private var currentGoal: UserGoal? { goals.first }

    private var currentWeight: Double? {
        let latestManual = weightEntries.first?.weight
        let latestHealthKit = healthKitService.currentWeight

        if let manual = latestManual,
           let healthKit = latestHealthKit,
           let manualDate = weightEntries.first?.date,
           let healthKitDate = healthKitService.weightHistory.first?.date {
            return manualDate > healthKitDate ? manual : healthKit
        }

        return latestManual ?? latestHealthKit
    }

    private var combinedWeightHistory: [WeightRecord] {
        var records = healthKitService.dailyWeights
        records.append(contentsOf: weightEntries.map { WeightRecord(date: $0.date, weight: $0.weight) })

        let grouped = Dictionary(grouping: records) { record in
            Calendar.current.startOfDay(for: record.date)
        }

        return grouped.map { (_, records) in
            records.first!
        }.sorted { $0.date > $1.date }
    }

    private var deficit: Double? {
        guard let energyBurned = displayedEnergyBurned else { return nil }
        return energyBurned.totalCalories - totalCalories
    }

    private var dailyBriefing: DailyBriefing {
        DailyBriefing(
            date: date,
            entries: entries,
            energyBurned: displayedEnergyBurned,
            aiStatusMessage: dailyBriefingAIStatus
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Summary card
                VStack(spacing: 16) {
                    Text("当日汇总")
                        .font(.headline)

                    HStack(spacing: 12) {
                        summaryMetric(
                            title: "总摄入",
                            value: totalCalories.formattedCalories,
                            unit: "kcal",
                            systemImage: "fork.knife",
                            color: .orange
                        )

                        summaryMetric(
                            title: "总消耗",
                            value: displayedEnergyBurned.map { $0.totalCalories.formattedCalories } ?? "--",
                            unit: "kcal",
                            systemImage: "flame.fill",
                            color: .red
                        )
                    }

                    if let energyBurned = displayedEnergyBurned {
                        VStack(spacing: 8) {
                            HStack {
                                Label("静息 \(Int(energyBurned.restingCalories)) kcal", systemImage: "bed.double.fill")
                                    .foregroundStyle(.purple)
                                Spacer()
                                Label("活动 \(Int(energyBurned.activeCalories)) kcal", systemImage: "applewatch")
                                    .foregroundStyle(.green)
                            }
                            .font(.caption)

                            if let deficit {
                                Label(
                                    deficit >= 0 ? "缺口 \(Int(deficit)) kcal" : "超出 \(Int(abs(deficit))) kcal",
                                    systemImage: deficit >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                                )
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(deficit >= 0 ? .green : .red)
                            }
                        }
                    } else {
                        Text("暂无健康 App 当日消耗数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        NutritionCard(
                            title: "蛋白质",
                            value: totalProtein.formattedGrams,
                            unit: "g",
                            color: .red
                        )
                        NutritionCard(
                            title: "碳水",
                            value: totalCarbs.formattedGrams,
                            unit: "g",
                            color: .blue
                        )
                        NutritionCard(
                            title: "脂肪",
                            value: totalFat.formattedGrams,
                            unit: "g",
                            color: .yellow
                        )
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)

                Button {
                    Task {
                        await prepareAndShowDailyBriefing()
                    }
                } label: {
                    DailyBriefingPreviewCard(
                        briefing: dailyBriefing,
                        isLoading: isPreparingDailyBriefing
                    )
                }
                .buttonStyle(.plain)
                .disabled(isPreparingDailyBriefing)

                // Food list
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text("食物明细")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingBackfillSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("补录")
                    }

                    ForEach(visibleFoodEntries) { entry in
                        SwipeableFoodEntryRow(
                            entry: entry,
                            showsPreferenceControl: true,
                            isSavedAsPreference: isSavedAsPreference(entry),
                            isAutofillingNutrition: autofillingNutritionEntryID == entry.id,
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

                    if sortedFoodEntries.count > collapsedFoodEntryLimit {
                        FoodEntryListExpansionButton(
                            isExpanded: showingAllFoodEntries,
                            totalCount: sortedFoodEntries.count
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingAllFoodEntries.toggle()
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(formatDate(date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AIAdvisorToolbarButton(isPresented: $showingAIAdvisor)
            }
            ToolbarItem(placement: .topBarTrailing) {
                AppSettingsToolbarButton(isPresented: $showingSettings)
            }
        }
        .sheet(isPresented: $showingAIAdvisor) {
            AIAdvisorView(
                foodEntries: allEntries,
                userGoal: currentGoal,
                currentWeight: currentWeight,
                weightHistory: combinedWeightHistory
            )
        }
        .sheet(isPresented: $showingSettings) {
            AppSettingsView()
        }
        .sheet(isPresented: $showingDailyBriefing) {
            DailyBriefingDetailView(briefing: dailyBriefing)
        }
        .sheet(isPresented: $showingBackfillSheet) {
            NavigationStack {
                FoodInputView(targetDate: date) {
                    // Refresh entries after saving
                    refreshEntries()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showingBackfillSheet = false
                        }
                    }
                }
            }
        }
        .sheet(item: $entryToEdit) { entry in
            FoodEntryEditView(entry: entry) {
                refreshEntries()
            }
        }
        .task(id: Calendar.current.startOfDay(for: date)) {
            await refreshEnergyBurned()
        }
        .refreshable {
            await refreshEnergyBurned()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await refreshEnergyBurned()
            }
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

    private func summaryMetric(title: String, value: String, unit: String, systemImage: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func deleteEntry(_ entry: FoodEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        entries.removeAll { $0.id == entry.id }
    }

    private func togglePreference(for entry: FoodEntry) {
        if let existing = preference(for: entry) {
            modelContext.delete(existing)
        } else {
            savePreference(for: entry)
        }

        try? modelContext.save()
    }

    private func savePreference(for entry: FoodEntry) {
        let preference = FoodPreference(
            keyword: entry.foodName,
            brand: entry.brand,
            defaultDescription: "\(Self.trimmedNumber(entry.grams))\(entry.category.quantityUnitSymbol), \(Self.trimmedNumber(entry.displayedEnergy))\(entry.energyUnit.symbol)",
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

    private func refreshEntries() {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate<FoodEntry> { entry in
                entry.createdAt >= startOfDay && entry.createdAt < endOfDay
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )

        if let fetchedEntries = try? modelContext.fetch(descriptor) {
            entries = fetchedEntries
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
                updatePreferenceUnitNutrition(
                    for: entry,
                    protein: estimate.proteinPer100,
                    carbs: estimate.carbsPer100,
                    fat: estimate.fatPer100
                )
                try modelContext.save()
                refreshEntries()
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

    @MainActor
    private func prepareAndShowDailyBriefing() async {
        guard !isPreparingDailyBriefing else { return }

        let missingEntries = entries.filter {
            $0.grams > 0 && $0.protein <= 0 && $0.carbohydrates <= 0 && $0.fat <= 0
        }
        guard !missingEntries.isEmpty else {
            dailyBriefingAIStatus = nil
            showingDailyBriefing = true
            return
        }

        isPreparingDailyBriefing = true
        dailyBriefingAIStatus = nil
        var completedCount = 0
        var aiEstimatedCount = 0
        var failedCount = 0
        let canUseTextAI = APIKeyManager.isDeepSeekConfigured
            || APIKeyManager.isMiniMaxConfigured
            || APIKeyManager.isQwenConfigured

        for entry in missingEntries {
            if applySavedPreferenceNutrition(to: entry) {
                completedCount += 1
                continue
            }

            guard canUseTextAI else {
                failedCount += 1
                continue
            }

            do {
                let unit = entry.category.quantityUnitSymbol
                let brandDescription = entry.brand.map { "，品牌：\($0)" } ?? ""
                let prompt = """
                请估算以下食物每100\(unit)的营养成分：\(entry.foodName)\(brandDescription)。
                已知本次摄入量为\(entry.grams.formattedGrams)\(unit)，记录总热量为\(entry.calories.formattedCalories)kcal。
                请按100\(unit)返回结果，grams字段返回100，重点给出蛋白质、碳水化合物和脂肪。
                """
                let estimate = try await aiService.parseFoodInput(prompt, preferences: foodPreferences)
                let estimatedQuantity = estimate.grams > 0 ? estimate.grams : 100
                let unitScale = 100 / estimatedQuantity
                let proteinPer100 = max(0, estimate.protein * unitScale)
                let carbsPer100 = max(0, estimate.carbohydrates * unitScale)
                let fatPer100 = max(0, estimate.fat * unitScale)

                if entry.calories > 0 && proteinPer100 + carbsPer100 + fatPer100 <= 0 {
                    failedCount += 1
                    continue
                }

                let intakeScale = entry.grams / 100
                entry.protein = proteinPer100 * intakeScale
                entry.carbohydrates = carbsPer100 * intakeScale
                entry.fat = fatPer100 * intakeScale
                entry.nutritionEstimatedByAI = true
                updatePreferenceUnitNutrition(
                    for: entry,
                    protein: proteinPer100,
                    carbs: carbsPer100,
                    fat: fatPer100
                )
                completedCount += 1
                aiEstimatedCount += 1
            } catch {
                failedCount += 1
            }
        }

        if completedCount > 0 {
            try? modelContext.save()
            refreshEntries()
        }

        if failedCount == 0 {
            dailyBriefingAIStatus = aiEstimatedCount > 0
                ? "已补全\(completedCount)项缺失营养数据，其中\(aiEstimatedCount)项为AI估算。"
                : "已根据保存的食物习惯补全\(completedCount)项营养数据。"
        } else if completedCount > 0 {
            dailyBriefingAIStatus = "已补全\(completedCount)项营养数据，仍有\(failedCount)项缺少相关信息。"
        } else {
            dailyBriefingAIStatus = canUseTextAI
                ? "AI未能补全\(failedCount)项缺失营养数据。"
                : "仍有\(failedCount)项缺少营养数据；配置文字AI后可自动补全。"
        }

        isPreparingDailyBriefing = false
        showingDailyBriefing = true
    }

    private func applySavedPreferenceNutrition(to entry: FoodEntry) -> Bool {
        guard let preference = preference(for: entry) else { return false }
        let proteinPer100 = preference.resolvedProteinPer100 ?? 0
        let carbsPer100 = preference.resolvedCarbsPer100 ?? 0
        let fatPer100 = preference.resolvedFatPer100 ?? 0
        guard proteinPer100 + carbsPer100 + fatPer100 > 0 else { return false }

        let scale = entry.grams / 100
        entry.protein = proteinPer100 * scale
        entry.carbohydrates = carbsPer100 * scale
        entry.fat = fatPer100 * scale
        entry.nutritionEstimatedByAI = false
        return true
    }

    private func updatePreferenceUnitNutrition(
        for entry: FoodEntry,
        protein: Double,
        carbs: Double,
        fat: Double
    ) {
        guard let preference = preference(for: entry) else { return }
        if preference.proteinPer100 == nil || preference.proteinPer100 == 0 {
            preference.proteinPer100 = protein
        }
        if preference.carbsPer100 == nil || preference.carbsPer100 == 0 {
            preference.carbsPer100 = carbs
        }
        if preference.fatPer100 == nil || preference.fatPer100 == 0 {
            preference.fatPer100 = fat
        }
    }

    private func refreshEnergyBurned() async {
        await healthKitService.requestAuthorization()
        fetchedEnergyBurned = await healthKitService.fetchCaloriesBurned(for: date)
    }

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }

    private func isSavedAsPreference(_ entry: FoodEntry) -> Bool {
        preference(for: entry) != nil
    }

    private func preference(for entry: FoodEntry) -> FoodPreference? {
        let normalizedName = Self.normalizedPreferenceName(entry.foodName)
        let normalizedBrand = Self.normalizedOptionalText(entry.brand)
        guard !normalizedName.isEmpty else { return nil }
        return foodPreferences.first {
            Self.normalizedPreferenceName($0.keyword) == normalizedName
                && Self.normalizedOptionalText($0.brand) == normalizedBrand
        }
    }

    private static func normalizedPreferenceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private static func trimmedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

private struct DailyBriefing {
    let date: Date
    let entries: [FoodEntry]
    let energyBurned: DailyEnergyBurned?
    let aiStatusMessage: String?

    init(
        date: Date,
        entries: [FoodEntry],
        energyBurned: DailyEnergyBurned?,
        aiStatusMessage: String? = nil
    ) {
        self.date = date
        self.entries = entries
        self.energyBurned = energyBurned
        self.aiStatusMessage = aiStatusMessage
    }

    var totalCalories: Double {
        entries.reduce(0) { $0 + $1.calories }
    }

    var totalProtein: Double {
        entries.reduce(0) { $0 + $1.protein }
    }

    var totalCarbs: Double {
        entries.reduce(0) { $0 + $1.carbohydrates }
    }

    var totalFat: Double {
        entries.reduce(0) { $0 + $1.fat }
    }

    var macroCalories: Double {
        totalProtein * 4 + totalCarbs * 4 + totalFat * 9
    }

    var proteinRatio: Double {
        macroCalories > 0 ? totalProtein * 4 / macroCalories : 0
    }

    var carbsRatio: Double {
        macroCalories > 0 ? totalCarbs * 4 / macroCalories : 0
    }

    var fatRatio: Double {
        macroCalories > 0 ? totalFat * 9 / macroCalories : 0
    }

    var deficit: Double? {
        guard let energyBurned else { return nil }
        return energyBurned.totalCalories - totalCalories
    }

    var title: String {
        if Calendar.current.isDateInToday(date) {
            return "今日简报"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨日简报"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日简报"
        return formatter.string(from: date)
    }

    var headline: String {
        guard !entries.isEmpty else {
            return "这一天暂无摄入记录"
        }

        if let deficit {
            if deficit >= 0 {
                return "摄入 \(Int(totalCalories)) kcal，形成 \(Int(deficit)) kcal 缺口"
            }
            return "摄入 \(Int(totalCalories)) kcal，超出 \(Int(abs(deficit))) kcal"
        }

        return "摄入 \(Int(totalCalories)) kcal，等待消耗数据同步"
    }

    var macroSummary: String {
        guard macroCalories > 0 else {
            return "暂无可分析的营养结构"
        }

        return "蛋白 \(ratioText(proteinRatio)) · 碳水 \(ratioText(carbsRatio)) · 脂肪 \(ratioText(fatRatio))"
    }

    var insights: [DailyBriefingInsight] {
        var result: [DailyBriefingInsight] = []

        if entries.isEmpty {
            result.append(
                DailyBriefingInsight(
                    systemImage: "tray",
                    title: "记录完整度",
                    body: "这一天没有摄入记录，暂时无法判断摄入和营养结构。",
                    color: .secondary
                )
            )
            return result
        }

        if let aiStatusMessage {
            result.append(
                DailyBriefingInsight(
                    systemImage: "sparkles",
                    title: "营养补全",
                    body: aiStatusMessage,
                    color: .blue
                )
            )
        } else {
            let estimatedCount = entries.filter { $0.nutritionEstimatedByAI == true }.count
            if estimatedCount > 0 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "sparkles",
                        title: "营养数据",
                        body: "当前有\(estimatedCount)项营养数据为AI估算值。",
                        color: .blue
                    )
                )
            }
        }

        if let energyBurned {
            let balance = energyBurned.totalCalories - totalCalories
            if balance >= 300 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "arrow.down.circle.fill",
                        title: "热量平衡",
                        body: "当天消耗高于摄入 \(Int(balance)) kcal，形成比较明确的热量缺口。",
                        color: .green
                    )
                )
            } else if balance >= 0 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "equal.circle.fill",
                        title: "热量平衡",
                        body: "当天消耗略高于摄入 \(Int(balance)) kcal，整体接近平衡。",
                        color: .blue
                    )
                )
            } else {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "arrow.up.circle.fill",
                        title: "热量平衡",
                        body: "当天摄入高于消耗 \(Int(abs(balance))) kcal，如目标是减脂，需要留意晚间或饮品摄入。",
                        color: .red
                    )
                )
            }
        } else {
            result.append(
                DailyBriefingInsight(
                    systemImage: "flame",
                    title: "消耗数据",
                    body: "这一天还没有同步到 HealthKit 总消耗，暂不判断热量缺口。",
                    color: .secondary
                )
            )
        }

        if macroCalories > 0 {
            if proteinRatio < 0.15 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "bolt.heart",
                        title: "蛋白质",
                        body: "蛋白质供能约 \(ratioText(proteinRatio))，占比偏低；后续可增加鱼肉蛋奶或豆制品。",
                        color: .red
                    )
                )
            } else {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "bolt.heart.fill",
                        title: "蛋白质",
                        body: "蛋白质 \(totalProtein.formattedGrams)g，供能约 \(ratioText(proteinRatio))。",
                        color: .red
                    )
                )
            }

            if carbsRatio > 0.60 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "leaf",
                        title: "碳水结构",
                        body: "碳水供能约 \(ratioText(carbsRatio))，占比较高；可以检查主食、甜饮和零食来源。",
                        color: .blue
                    )
                )
            } else if fatRatio > 0.35 {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "drop.fill",
                        title: "脂肪结构",
                        body: "脂肪供能约 \(ratioText(fatRatio))，占比较高；可以留意烹调用油、坚果和高脂肉类。",
                        color: .yellow
                    )
                )
            } else {
                result.append(
                    DailyBriefingInsight(
                        systemImage: "chart.pie.fill",
                        title: "营养结构",
                        body: "三大营养素占比相对平衡：\(macroSummary)。",
                        color: .green
                    )
                )
            }
        } else {
            result.append(
                DailyBriefingInsight(
                    systemImage: "chart.pie",
                    title: "营养结构",
                    body: "当前记录缺少蛋白质、碳水和脂肪数据，无法分析营养结构。",
                    color: .secondary
                )
            )
        }

        result.append(
            DailyBriefingInsight(
                systemImage: "list.bullet.clipboard",
                title: "记录概况",
                body: "当天记录了 \(entries.count) 项食物，总摄入 \(Int(totalCalories)) kcal。",
                color: .orange
            )
        )

        return result
    }

    func ratioText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct DailyBriefingInsight: Identifiable {
    let id = UUID()
    let systemImage: String
    let title: String
    let body: String
    let color: Color
}

private struct DailyBriefingPreviewCard: View {
    let briefing: DailyBriefing
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("当日简报")
                    .font(.headline)

                Text(briefing.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(briefing.macroSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct DailyBriefingDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let briefing: DailyBriefing

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(briefing.headline)
                            .font(.title3)
                            .fontWeight(.bold)

                        Text(briefing.macroSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    briefingMetrics

                    if briefing.macroCalories > 0 {
                        macroStructure
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("简报")
                            .font(.headline)

                        ForEach(briefing.insights) { insight in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: insight.systemImage)
                                    .font(.headline)
                                    .foregroundStyle(insight.color)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(insight.title)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)

                                    Text(insight.body)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(briefing.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var briefingMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关键数据")
                .font(.headline)

            HStack(spacing: 10) {
                metricPill(title: "摄入", value: "\(Int(briefing.totalCalories))", unit: "kcal", color: .orange)
                metricPill(title: "消耗", value: briefing.energyBurned.map { "\(Int($0.totalCalories))" } ?? "--", unit: "kcal", color: .red)
                metricPill(title: "缺口", value: deficitText, unit: "kcal", color: deficitColor)
            }
        }
    }

    private var macroStructure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("营养结构")
                .font(.headline)

            macroRow(title: "蛋白质", grams: briefing.totalProtein, ratio: briefing.proteinRatio, color: .red)
            macroRow(title: "碳水", grams: briefing.totalCarbs, ratio: briefing.carbsRatio, color: .blue)
            macroRow(title: "脂肪", grams: briefing.totalFat, ratio: briefing.fatRatio, color: .yellow)
        }
        .padding()
        .background(AppSurfaceStyle.moduleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var deficitText: String {
        guard let deficit = briefing.deficit else { return "--" }
        return "\(Int(abs(deficit)))"
    }

    private var deficitColor: Color {
        guard let deficit = briefing.deficit else { return .secondary }
        return deficit >= 0 ? .green : .red
    }

    private func metricPill(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func macroRow(title: String, grams: Double, ratio: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(grams.formattedGrams)g · \(briefing.ratioText(ratio))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: 8)
        }
    }
}

struct HorizontalPanGestureBridge: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        let coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.onSuperviewChange = { [weak coordinator] superview in
            coordinator?.attach(to: superview)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.attach(to: uiView.superview)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onSuperviewChange: ((UIView?) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onSuperviewChange?(superview)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        private weak var attachedView: UIView?
        private lazy var panGesture: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            gesture.delegate = self
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            return gesture
        }()

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(to view: UIView?) {
            guard let view, attachedView !== view else { return }
            detach()
            attachedView = view
            view.addGestureRecognizer(panGesture)
        }

        func detach() {
            attachedView?.removeGestureRecognizer(panGesture)
            attachedView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = panGesture.view else {
                return false
            }
            let velocity = panGesture.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y) * 1.15
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view).x

            switch gesture.state {
            case .began, .changed:
                onChanged(translation)
            case .ended, .cancelled, .failed:
                onEnded(translation, gesture.velocity(in: view).x)
            default:
                break
            }
        }
    }
}

struct SwipeableFoodEntryRow: View {
    let entry: FoodEntry
    let showsPreferenceControl: Bool
    let isSavedAsPreference: Bool
    let isAutofillingNutrition: Bool
    let onEdit: () -> Void
    let onTogglePreference: () -> Void
    let onAutofillNutrition: () -> Void
    let onDelete: () -> Void

    @State private var settledOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    private let deleteButtonWidth: CGFloat = 88

    private var currentOffset: CGFloat {
        min(0, max(-deleteButtonWidth, settledOffset + dragOffset))
    }

    private var deleteRevealProgress: Double {
        min(1, max(0, Double(-currentOffset / deleteButtonWidth)))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    settledOffset = 0
                }
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.headline)
                    Text("删除")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .frame(width: deleteButtonWidth)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.red)
            .opacity(deleteRevealProgress)
            .contentShape(Rectangle())
            .allowsHitTesting(deleteRevealProgress > 0.5)
            .zIndex(2)

            FoodEntryDetailRow(
                entry: entry,
                showsPreferenceControl: showsPreferenceControl,
                isSavedAsPreference: isSavedAsPreference,
                isAutofillingNutrition: isAutofillingNutrition,
                onTogglePreference: onTogglePreference,
                onAutofillNutrition: onAutofillNutrition,
                onEdit: onEdit
            )
            .offset(x: currentOffset)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if settledOffset == 0 {
                    onEdit()
                } else {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        settledOffset = 0
                    }
                }
            }
            .zIndex(1)
        }
        .background {
            HorizontalPanGestureBridge(
                onChanged: { dragOffset = $0 },
                onEnded: finishSwipe
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: settledOffset)
    }

    private func finishSwipe(translation: CGFloat, velocity: CGFloat) {
        let projectedOffset = settledOffset + translation + velocity * 0.12
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            dragOffset = 0
            settledOffset = projectedOffset < -deleteButtonWidth / 2 ? -deleteButtonWidth : 0
        }
    }
}

private struct FoodEntryDetailRow: View {
    let entry: FoodEntry
    let showsPreferenceControl: Bool
    let isSavedAsPreference: Bool
    let isAutofillingNutrition: Bool
    let onTogglePreference: () -> Void
    let onAutofillNutrition: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(entry.displayCategoryName, systemImage: entry.displayCategorySystemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())

                    Text(entry.createdAt.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(entry.foodName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let brand = entry.brand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(entry.grams.formattedGrams)\(entry.category.quantityUnitSymbol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(entry.displayedEnergy.formattedCalories) \(entry.energyUnit.symbol)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)

                HStack(spacing: 2) {
                    Button {
                        onAutofillNutrition()
                    } label: {
                        AIRecognitionStatusIcon(
                            isComplete: entry.hasCompleteNutritionInfo,
                            isProcessing: isAutofillingNutrition
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAutofillingNutrition)
                    .accessibilityLabel("AI识别")
                    .accessibilityValue(entry.hasCompleteNutritionInfo ? "营养信息完整" : "营养信息待补全")

                    if showsPreferenceControl {
                        Button {
                            onTogglePreference()
                        } label: {
                            Image(systemName: isSavedAsPreference ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 44, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSavedAsPreference ? "取消保存习惯" : "保存习惯")
                    }

                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑")
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.22), lineWidth: 0.5)
        }
    }
}

struct FoodEntryListExpansionButton: View {
    let isExpanded: Bool
    let totalCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(isExpanded ? "收起" : "展开全部 \(totalCount) 项")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起食物明细" : "展开全部食物明细")
    }
}

struct AIRecognitionActionBar: View {
    let isProcessing: Bool
    let onRecognize: () -> Void
    let onCamera: () -> Void
    let onPasteImage: (UIImage) -> Void
    let onPasteFailure: () -> Void
    @Binding var inputText: String
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 8) {
            ImagePasteTextField(
                text: $inputText,
                placeholder: "补充说明或修改要求",
                isEnabled: !isProcessing,
                returnKeyType: .go,
                onSubmit: onRecognize,
                onPasteImage: onPasteImage,
                onPasteFailure: onPasteFailure
            )

            if !inputText.isEmpty {
                Button {
                    inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 22)

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("正在识别")
            } else {
                Button(action: onRecognize) {
                    Image(systemName: "sparkles")
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("AI识别")
            }

            Button(action: onCamera) {
                Image(systemName: "camera.fill")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(isProcessing)
            .accessibilityLabel("拍照识别")

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo.fill")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(isProcessing)
            .accessibilityLabel("从相册选择照片")

        }
        .foodSearchBarSurface()
    }
}

struct FoodSearchBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

extension View {
    func foodSearchBarSurface() -> some View {
        modifier(FoodSearchBarSurface())
    }
}

struct ImagePasteTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEnabled = true
    var returnKeyType: UIReturnKeyType = .search
    var focusBinding: Binding<Bool>?
    let onSubmit: () -> Void
    let onPasteImage: (UIImage) -> Void
    let onPasteFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ClipboardImageTextField {
        let textField = ClipboardImageTextField()
        textField.delegate = context.coordinator
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocorrectionType = .default
        textField.clearButtonMode = .never
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        configure(textField, context: context)
        return textField
    }

    func updateUIView(_ textField: ClipboardImageTextField, context: Context) {
        context.coordinator.parent = self
        configure(textField, context: context)

        if textField.text != text {
            textField.text = text
        }

        if let focusBinding {
            if focusBinding.wrappedValue, !textField.isFirstResponder {
                DispatchQueue.main.async {
                    textField.becomeFirstResponder()
                }
            } else if !focusBinding.wrappedValue, textField.isFirstResponder {
                textField.resignFirstResponder()
            }
        }
    }

    private func configure(_ textField: ClipboardImageTextField, context: Context) {
        textField.placeholder = placeholder
        textField.isEnabled = isEnabled
        textField.returnKeyType = returnKeyType
        textField.onPasteImage = onPasteImage
        textField.onPasteFailure = onPasteFailure
        textField.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.image.identifier,
                UTType.text.identifier
            ]
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ImagePasteTextField

        init(parent: ImagePasteTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focusBinding?.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.focusBinding?.wrappedValue = false
        }
    }
}

final class ClipboardImageTextField: UITextField {
    var onPasteImage: ((UIImage) -> Void)?
    var onPasteFailure: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard UIPasteboard.general.hasImages else {
            super.paste(sender)
            return
        }

        ClipboardImageLoader.load { [weak self] image in
            self?.completeImagePaste(image)
        }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard itemProviders.contains(where: ClipboardImageLoader.supportsImage) else {
            super.paste(itemProviders: itemProviders)
            return
        }

        ClipboardImageLoader.load(from: itemProviders) { [weak self] image in
            self?.completeImagePaste(image)
        }
    }

    private func completeImagePaste(_ image: UIImage?) {
        if let image {
            onPasteImage?(image)
        } else {
            onPasteFailure?()
        }
    }
}

enum ClipboardImageLoader {
    static func load(completion: @escaping (UIImage?) -> Void) {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else {
            deliver(nil, completion: completion)
            return
        }

        if let image = pasteboard.image {
            deliver(image, completion: completion)
        } else {
            load(from: pasteboard.itemProviders, completion: completion)
        }
    }

    static func load(
        from providers: [NSItemProvider],
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let provider = providers.first(where: supportsImage) else {
            deliver(nil, completion: completion)
            return
        }

        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                if let image = object as? UIImage {
                    deliver(image, completion: completion)
                } else {
                    loadImageData(from: provider, completion: completion)
                }
            }
        } else {
            loadImageData(from: provider, completion: completion)
        }
    }

    static func supportsImage(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: UIImage.self)
            || provider.registeredTypeIdentifiers.contains { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            }
    }

    private static func loadImageData(
        from provider: NSItemProvider,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            deliver(nil, completion: completion)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            guard let data, let image = UIImage(data: data) else {
                deliver(nil, completion: completion)
                return
            }
            deliver(image, completion: completion)
        }
    }

    private static func deliver(
        _ image: UIImage?,
        completion: @escaping (UIImage?) -> Void
    ) {
        DispatchQueue.main.async {
            completion(image)
        }
    }
}

struct AIRecognitionStatusIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    let isComplete: Bool
    var isProcessing = false

    private var statusColor: Color {
        if isComplete {
            return .blue
        }
        return colorScheme == .light ? .black : .white
    }

    var body: some View {
        ZStack {
            if isProcessing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
            } else {
                Image(systemName: "sparkles")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .shadow(
                        color: !isComplete && colorScheme == .dark
                            ? .black.opacity(0.35)
                            : .clear,
                        radius: 1
                    )
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}

private enum FoodEntryEditEnergyInputMode: String, CaseIterable, Identifiable {
    case total
    case per100

    var id: Self { self }

    var title: String {
        switch self {
        case .total:
            return "总热量"
        case .per100:
            return "单位热量"
        }
    }
}

private struct FoodPreferenceBrandGroup: Identifiable {
    let brand: String
    let preferences: [FoodPreference]

    var id: String { brand }
}

struct FoodEntryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var existingEntries: [FoodEntry]

    let entry: FoodEntry
    var onSaved: (() -> Void)?

    @State private var foodName = ""
    @State private var brand = ""
    @State private var grams = ""
    @State private var calories = ""
    @State private var energyUnit: EnergyUnit = .kilocalorie
    @State private var energyInputMode: FoodEntryEditEnergyInputMode = .total
    @State private var nutritionInputMode: FoodEntryEditEnergyInputMode = .total
    @State private var protein = ""
    @State private var carbohydrates = ""
    @State private var fat = ""
    @State private var category: FoodEntryCategory = .meal
    @State private var mealType: FoodMealType = .lunch
    @State private var errorMessage: String?
    @State private var isInitializing = true
    @State private var isApplyingAIResult = false
    @State private var isProcessingAI = false
    @State private var aiStatusMessage: String?
    @State private var showingSettings = false
    @State private var nutritionWasEstimatedByAI = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingCamera = false
    @State private var showingCameraAlert = false
    @State private var aiInputText = ""
    @State private var mergeTargetPreferenceID: UUID?
    @State private var mergePreferenceSearchText = ""
    @State private var isMergePreferenceListExpanded = false
    @FocusState private var isMergePreferenceSearchFocused: Bool

    private let aiService = MiniMaxService()

    private var knownBrands: [String] {
        BrandSuggestionCatalog.brands(
            entries: existingEntries,
            preferences: existingPreferences
        )
    }

    private var quantityUnit: String {
        category.quantityUnitSymbol
    }

    private var energyInputTitle: String {
        switch energyInputMode {
        case .total:
            return "总热量"
        case .per100:
            return "热量"
        }
    }

    private func nutrientInputTitle(_ nutrient: String) -> String {
        nutrient
    }

    private var energyInputUnit: String {
        energyInputMode == .per100
            ? "\(energyUnit.symbol)/100\(quantityUnit)"
            : energyUnit.symbol
    }

    private var nutrientInputUnit: String {
        nutritionInputMode == .per100
            ? "g/100\(quantityUnit)"
            : "g"
    }

    private var computedCalories: Double? {
        totalCalories(
            fromEnergyText: calories,
            mode: energyInputMode,
            unit: energyUnit,
            gramsText: grams
        )
    }

    private var totalEnergyText: String? {
        guard let totalCalories = computedCalories else {
            return nil
        }

        let kilojoules = EnergyUnit.kilojoule.fromKilocalories(totalCalories)
        return "总摄入约 \(totalCalories.formattedCalories) kcal / \(kilojoules.formattedCalories) kJ"
    }

    private var isSavedAsPreference: Bool {
        existingPreference(for: foodName, brand: brand) != nil
    }

    private var mergeTargetPreference: FoodPreference? {
        guard let mergeTargetPreferenceID else { return nil }
        return existingPreferences.first { $0.id == mergeTargetPreferenceID }
    }

    private var sortedPreferences: [FoodPreference] {
        existingPreferences.sorted {
            if $0.usageCount == $1.usageCount {
                return $0.keyword.localizedCompare($1.keyword) == .orderedAscending
            }
            return $0.usageCount > $1.usageCount
        }
    }

    private var filteredMergePreferences: [FoodPreference] {
        let query = mergePreferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedPreferences }

        return sortedPreferences.filter { preference in
            preference.keyword.localizedCaseInsensitiveContains(query)
                || (preference.brand?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var groupedMergePreferences: [FoodPreferenceBrandGroup] {
        let grouped = Dictionary(grouping: filteredMergePreferences) { preference in
            let brand = preference.brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return brand.isEmpty ? "无品牌" : brand
        }

        return grouped.map { brand, preferences in
            FoodPreferenceBrandGroup(
                brand: brand,
                preferences: preferences.sorted {
                    $0.keyword.localizedCompare($1.keyword) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.brand == "无品牌" { return false }
            if rhs.brand == "无品牌" { return true }
            return lhs.brand.localizedCompare(rhs.brand) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AIRecognitionActionBar(
                        isProcessing: isProcessingAI,
                        onRecognize: { recognizeWithAI(image: selectedImage) },
                        onCamera: { openCamera() },
                        onPasteImage: { image in
                            selectedImage = image
                            errorMessage = nil
                            aiStatusMessage = "已粘贴图片，可补充说明后点 AI 识别。"
                        },
                        onPasteFailure: {
                            errorMessage = "剪贴板中没有可用图片，请重新拷贝照片后重试。"
                        },
                        inputText: $aiInputText,
                        selectedPhoto: $selectedPhoto
                    )

                    if let aiStatusMessage {
                        Label(aiStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    editFormModule(title: "食物信息", systemImage: "fork.knife") {
                        VStack(spacing: 10) {
                            TextField("名称", text: $foodName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(editInputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            BrandAutocompleteField(
                                text: $brand,
                                brands: knownBrands,
                                inputBackground: editInputBackground
                            )
                        }
                    }

                    editFormModule(title: "分类", systemImage: "tag.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            editPickerLabel("类型")

                            Picker("类型", selection: $category) {
                                ForEach(FoodEntryCategory.allCases) { category in
                                    Label(category.rawValue, systemImage: category.systemImage)
                                        .tag(category)
                                }
                            }
                            .pickerStyle(.segmented)

                            if category == .meal {
                                Divider()

                                editPickerLabel("餐次")

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

                    editFormModule(title: "热量设置", systemImage: "flame.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            editPickerLabel("热量单位")

                            Picker("热量单位", selection: $energyUnit) {
                                ForEach(EnergyUnit.allCases) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)

                            Divider()

                            editPickerLabel("热量输入")

                            Picker("热量输入", selection: $energyInputMode) {
                                ForEach(FoodEntryEditEnergyInputMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    editFormModule(title: "摄入信息", systemImage: "scalemass.fill") {
                        VStack(spacing: 10) {
                            numberField(
                                title: "摄入量",
                                text: $grams,
                                unit: quantityUnit,
                                isRequired: energyInputMode == .per100 || nutritionInputMode == .per100
                            )
                            numberField(
                                title: energyInputTitle,
                                text: $calories,
                                unit: energyInputUnit,
                                isRequired: true
                            )

                            if let totalEnergyText {
                                Label(totalEnergyText, systemImage: "equal.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    editFormModule(title: "营养成分", systemImage: "chart.pie.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            editPickerLabel("营养输入")

                            Picker("营养输入", selection: $nutritionInputMode) {
                                Text("总量").tag(FoodEntryEditEnergyInputMode.total)
                                Text("单位营养").tag(FoodEntryEditEnergyInputMode.per100)
                            }
                            .pickerStyle(.segmented)

                            Divider()

                            numberField(title: nutrientInputTitle("蛋白质"), text: $protein, unit: nutrientInputUnit)
                            numberField(title: nutrientInputTitle("碳水化合物"), text: $carbohydrates, unit: nutrientInputUnit)
                            numberField(title: nutrientInputTitle("脂肪"), text: $fat, unit: nutrientInputUnit)
                        }
                    }

                    editFormModule(title: "食物习惯", systemImage: "heart.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let currentPreference = existingPreference(for: foodName, brand: brand),
                               mergeTargetPreference == nil {
                                Label("当前属于：\(currentPreference.keyword)", systemImage: "heart.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.pink)
                            }

                            HStack(spacing: 8) {
                                TextField("输入名称或品牌", text: $mergePreferenceSearchText)
                                    .textFieldStyle(.plain)
                                    .focused($isMergePreferenceSearchFocused)
                                    .onTapGesture {
                                        isMergePreferenceListExpanded = true
                                    }

                                if !mergePreferenceSearchText.isEmpty {
                                    Button {
                                        mergePreferenceSearchText = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("清空搜索")
                                }

                                Button {
                                    isMergePreferenceListExpanded.toggle()
                                    if isMergePreferenceListExpanded {
                                        isMergePreferenceSearchFocused = true
                                    } else {
                                        isMergePreferenceSearchFocused = false
                                    }
                                } label: {
                                    Image(systemName: isMergePreferenceListExpanded ? "chevron.up" : "chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isMergePreferenceListExpanded ? "收起食物习惯" : "展开食物习惯")
                            }
                            .padding(12)
                            .background(editInputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onChange(of: isMergePreferenceSearchFocused) { _, isFocused in
                                if isFocused {
                                    isMergePreferenceListExpanded = true
                                }
                            }
                            .onChange(of: mergePreferenceSearchText) { _, _ in
                                if isMergePreferenceSearchFocused {
                                    isMergePreferenceListExpanded = true
                                }
                            }

                            if isMergePreferenceListExpanded {
                                if groupedMergePreferences.isEmpty {
                                    Text("没有匹配的食物习惯")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 14)
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(groupedMergePreferences) { group in
                                            Text(group.brand)
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 12)
                                                .padding(.top, 12)
                                                .padding(.bottom, 4)

                                            ForEach(group.preferences, id: \.id) { preference in
                                                Button {
                                                    mergeTargetPreferenceID = preference.id
                                                    mergePreferenceSearchText = ""
                                                    isMergePreferenceListExpanded = false
                                                    isMergePreferenceSearchFocused = false
                                                } label: {
                                                    HStack(spacing: 10) {
                                                        VStack(alignment: .leading, spacing: 3) {
                                                            Text(preference.keyword)
                                                                .foregroundStyle(.primary)
                                                            Text(preference.defaultDescription)
                                                                .font(.caption2)
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                        }

                                                        Spacer(minLength: 8)

                                                        if mergeTargetPreferenceID == preference.id {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .foregroundStyle(.green)
                                                        }
                                                    }
                                                    .contentShape(Rectangle())
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 9)
                                                }
                                                .buttonStyle(.plain)

                                                if preference.id != group.preferences.last?.id {
                                                    Divider()
                                                        .padding(.leading, 12)
                                                }
                                            }
                                        }
                                    }
                                    .background(editInputBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }

                            if let mergeTargetPreference {
                                Label(
                                    "保存后将与“\(mergeTargetPreference.keyword)”合并；本次摄入量、热量和营养数据保持不变。",
                                    systemImage: "arrow.triangle.merge"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Button("取消合并") {
                                    mergeTargetPreferenceID = nil
                                }
                                .font(.caption)
                                .foregroundStyle(.blue)
                            } else if sortedPreferences.isEmpty {
                                Text("当前还没有可合并的食物习惯。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("名称不同但属于同一种食物时，可合并到已有习惯。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if mergeTargetPreference == nil {
                        Button {
                            togglePreference()
                        } label: {
                            Label(isSavedAsPreference ? "取消保存习惯" : "保存习惯", systemImage: isSavedAsPreference ? "heart.fill" : "heart")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSavedAsPreference ? .white : .pink)
                        .background(isSavedAsPreference ? Color.pink : AppSurfaceStyle.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
            .background(AppSurfaceStyle.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingSettings) {
                AppSettingsView()
            }
            .sheet(isPresented: $showingCamera, onDismiss: recognizeCapturedImage) {
                CameraView(image: $selectedImage)
            }
            .alert("相机不可用", isPresented: $showingCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请在真机上使用相机功能，或从相册选择图片。")
            }
            .onAppear {
                foodName = entry.foodName
                brand = entry.brand ?? ""
                grams = String(format: "%.1f", entry.grams)
                energyUnit = entry.energyUnit
                calories = String(format: "%.0f", entry.displayedEnergy)
                energyInputMode = .total
                nutritionInputMode = .total
                protein = String(format: "%.1f", entry.protein)
                carbohydrates = String(format: "%.1f", entry.carbohydrates)
                fat = String(format: "%.1f", entry.fat)
                category = entry.category
                mealType = entry.mealType ?? FoodMealType.defaultType(for: entry.createdAt)
                nutritionWasEstimatedByAI = entry.nutritionEstimatedByAI == true
                DispatchQueue.main.async {
                    isInitializing = false
                }
            }
            .onChange(of: energyUnit) { oldUnit, newUnit in
                guard !isInitializing, !isApplyingAIResult else { return }
                convertEnergyUnit(from: oldUnit, to: newUnit)
            }
            .onChange(of: energyInputMode) { oldMode, newMode in
                guard !isInitializing, !isApplyingAIResult else { return }
                convertEnergyInputMode(from: oldMode, to: newMode)
            }
            .onChange(of: nutritionInputMode) { oldMode, newMode in
                guard !isInitializing, !isApplyingAIResult else { return }
                convertNutritionInputMode(from: oldMode, to: newMode)
            }
            .onChange(of: selectedPhoto) { _, newPhoto in
                guard let newPhoto else { return }
                Task {
                    guard let data = try? await newPhoto.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        await MainActor.run {
                            errorMessage = "无法读取所选图片，请重试。"
                            selectedPhoto = nil
                        }
                        return
                    }
                    await MainActor.run {
                        selectedPhoto = nil
                        recognizeWithAI(image: image)
                    }
                }
            }
        }
    }

    private func editFormModule<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .frame(width: 18)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            content()
        }
        .padding(14)
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func editPickerLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

    private var editInputBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .black : .systemBackground
        })
    }

    private func numberField(title: String, text: Binding<String>, unit: String, isRequired: Bool = false) -> some View {
        HStack {
            Text(title + (isRequired ? " *" : ""))
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
        }
        .padding(12)
        .background(editInputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func convertEnergyUnit(from oldUnit: EnergyUnit, to newUnit: EnergyUnit) {
        guard oldUnit != newUnit,
              let currentValue = parsedRawNumber(calories),
              currentValue >= 0 else {
            return
        }

        let currentKilocalories = oldUnit.toKilocalories(currentValue)
        calories = Self.trimmedNumber(newUnit.fromKilocalories(currentKilocalories))
    }

    private func convertEnergyInputMode(from oldMode: FoodEntryEditEnergyInputMode, to newMode: FoodEntryEditEnergyInputMode) {
        guard oldMode != newMode,
              let currentTotalCalories = totalCalories(
                fromEnergyText: calories,
                mode: oldMode,
                unit: energyUnit,
                gramsText: grams
              ),
              let displayValue = displayEnergyValue(
                totalCalories: currentTotalCalories,
                mode: newMode,
                unit: energyUnit,
                gramsText: grams
              ) else {
            return
        }

        calories = Self.trimmedNumber(displayValue)
    }

    private func convertNutritionInputMode(
        from oldMode: FoodEntryEditEnergyInputMode,
        to newMode: FoodEntryEditEnergyInputMode
    ) {
        guard oldMode != newMode,
              let quantity = parsedRawNumber(grams),
              quantity > 0 else {
            return
        }

        protein = convertedNutrientText(protein, from: oldMode, to: newMode, quantity: quantity)
        carbohydrates = convertedNutrientText(carbohydrates, from: oldMode, to: newMode, quantity: quantity)
        fat = convertedNutrientText(fat, from: oldMode, to: newMode, quantity: quantity)
    }

    private func convertedNutrientText(
        _ text: String,
        from oldMode: FoodEntryEditEnergyInputMode,
        to newMode: FoodEntryEditEnergyInputMode,
        quantity: Double
    ) -> String {
        guard let value = parsedRawNumber(text), value >= 0 else {
            return text
        }

        let totalValue = oldMode == .per100 ? value * quantity / 100 : value
        let displayValue = newMode == .per100 ? totalValue * 100 / quantity : totalValue
        return Self.trimmedNumber(displayValue)
    }

    private func totalCalories(
        fromEnergyText energyText: String,
        mode: FoodEntryEditEnergyInputMode,
        unit: EnergyUnit,
        gramsText: String
    ) -> Double? {
        guard let energyValue = parsedRawNumber(energyText), energyValue >= 0 else {
            return nil
        }

        let energyInKilocalories = unit.toKilocalories(energyValue)

        switch mode {
        case .total:
            return energyInKilocalories
        case .per100:
            guard let quantity = parsedRawNumber(gramsText), quantity >= 0 else {
                return nil
            }
            return energyInKilocalories * quantity / 100
        }
    }

    private func displayEnergyValue(
        totalCalories: Double,
        mode: FoodEntryEditEnergyInputMode,
        unit: EnergyUnit,
        gramsText: String
    ) -> Double? {
        switch mode {
        case .total:
            return unit.fromKilocalories(totalCalories)
        case .per100:
            guard let quantity = parsedRawNumber(gramsText), quantity > 0 else {
                return nil
            }
            return unit.fromKilocalories(totalCalories * 100 / quantity)
        }
    }

    @MainActor
    private func recognizeWithAI(image: UIImage? = nil) {
        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "请先填写食物名称"
            aiStatusMessage = nil
            return
        }

        if image != nil, !APIKeyManager.isQwenConfigured {
            errorMessage = "图片识别需要设置 Qwen API 密钥。"
            aiStatusMessage = nil
            showingSettings = true
            return
        }

        let currentQuantity = max(0, parsedRawNumber(grams) ?? 0)
        let currentEnergyValue = max(0, parsedRawNumber(calories) ?? 0)
        let brandDescription = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityDescription = currentQuantity > 0
            ? "本次摄入量：\(Self.trimmedNumber(currentQuantity))\(quantityUnit)"
            : "本次摄入量：未知，请估算常见单次摄入量"
        let energyDescription: String

        if currentEnergyValue > 0 {
            let energyInKilocalories = energyUnit.toKilocalories(currentEnergyValue)
            energyDescription = energyInputMode == .total
                ? "本次总热量：\(Self.trimmedNumber(energyInKilocalories))kcal"
                : "单位热量：\(Self.trimmedNumber(energyInKilocalories))kcal/100\(quantityUnit)"
        } else {
            energyDescription = "热量：未知，请一并估算"
        }

        let prompt = """
        请识别并补全这条食物记录：
        食物名称：\(trimmedName)
        品牌：\(brandDescription.isEmpty ? "未知" : brandDescription)
        类型：\(category.rawValue)
        \(quantityDescription)
        \(energyDescription)
        补充说明：\(aiInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无" : aiInputText.trimmingCharacters(in: .whitespacesAndNewlines))

        用户提供的数据优先于估算。请返回本次实际摄入的一条记录：grams为本次摄入量，calories、protein、carbohydrates和fat均为本次摄入总量。摄入量未知时，请根据食物和已知热量估算常见份量。
        """

        errorMessage = nil
        aiStatusMessage = nil
        isProcessingAI = true

        Task {
            defer { isProcessingAI = false }

            do {
                let nutritionPreferences = existingPreferences.filter {
                    ($0.resolvedProteinPer100 ?? 0)
                        + ($0.resolvedCarbsPer100 ?? 0)
                        + ($0.resolvedFatPer100 ?? 0) > 0
                }
                let estimate: NutritionInfo
                if let image {
                    estimate = try await aiService.parseFoodImage(
                        image,
                        additionalContext: prompt,
                        preferences: nutritionPreferences
                    )
                } else {
                    estimate = try await aiService.parseFoodInput(
                        prompt,
                        preferences: nutritionPreferences
                    )
                }
                applyAIEstimate(estimate, currentQuantity: currentQuantity)
            } catch {
                if let aiError = error as? AIServiceError,
                   case .apiKeyNotConfigured = aiError {
                    showingSettings = true
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            selectedImage = nil
            showingCamera = true
        } else {
            showingCameraAlert = true
        }
    }

    private func recognizeCapturedImage() {
        guard let image = selectedImage else { return }
        selectedImage = nil
        recognizeWithAI(image: image)
    }

    @MainActor
    private func applyAIEstimate(_ estimate: NutritionInfo, currentQuantity: Double) {
        let estimatedQuantity = max(0, estimate.grams)
        let resolvedQuantity = currentQuantity > 0 ? currentQuantity : estimatedQuantity

        guard resolvedQuantity > 0 else {
            errorMessage = "AI 未能估算摄入量，请手动填写后重试。"
            return
        }

        let sourceQuantity = estimatedQuantity > 0 ? estimatedQuantity : resolvedQuantity
        let scale = resolvedQuantity / sourceQuantity
        let resolvedProtein = max(0, estimate.protein * scale)
        let resolvedCarbs = max(0, estimate.carbohydrates * scale)
        let resolvedFat = max(0, estimate.fat * scale)
        let resolvedCalories = max(0, estimate.calories * scale)
        let knownTotalCalories = computedCalories ?? 0

        if resolvedProtein + resolvedCarbs + resolvedFat <= 0,
           max(knownTotalCalories, resolvedCalories) > 5 {
            errorMessage = "AI 未返回有效的营养成分，请重试。"
            return
        }

        isApplyingAIResult = true

        if currentQuantity <= 0 {
            grams = Self.trimmedNumber(resolvedQuantity)
        }

        if (parsedRawNumber(calories) ?? 0) <= 0, resolvedCalories > 0 {
            energyInputMode = .total
            calories = Self.trimmedNumber(energyUnit.fromKilocalories(resolvedCalories))
        }

        if brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let estimatedBrand = estimate.brand {
            brand = estimatedBrand
        }

        nutritionInputMode = .total
        protein = Self.trimmedNumber(resolvedProtein)
        carbohydrates = Self.trimmedNumber(resolvedCarbs)
        fat = Self.trimmedNumber(resolvedFat)
        nutritionWasEstimatedByAI = true
        errorMessage = nil
        selectedImage = nil
        aiStatusMessage = currentQuantity > 0
            ? "已填入营养成分，请确认后保存。"
            : "已估算摄入量和营养成分，请确认后保存。"

        DispatchQueue.main.async {
            isApplyingAIResult = false
        }
    }

    private func saveChanges() {
        guard let values = validatedValues() else { return }

        entry.foodName = mergeTargetPreference?.keyword ?? values.name
        entry.brand = mergeTargetPreference?.brand ?? values.brand
        entry.grams = values.grams
        entry.calories = values.calories
        entry.protein = values.protein
        entry.carbohydrates = values.carbohydrates
        entry.fat = values.fat
        entry.category = category
        entry.mealType = category == .meal ? mealType : nil
        entry.energyUnit = energyUnit
        entry.nutritionEstimatedByAI = nutritionWasEstimatedByAI

        do {
            try modelContext.save()
            onSaved?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePreference() {
        if let existing = existingPreference(for: foodName, brand: brand) {
            removePreference(existing)
        } else {
            saveCurrentAsPreference()
        }
    }

    private func saveCurrentAsPreference() {
        guard let values = validatedValues() else { return }

        if let existing = existingPreference(for: values.name, brand: values.brand) {
            existing.keyword = values.name
            existing.updateBrand(values.brand)
            existing.category = category
            existing.energyUnit = energyUnit
            existing.defaultDescription = "\(Self.trimmedNumber(values.grams))\(quantityUnit), \(Self.trimmedNumber(energyUnit.fromKilocalories(values.calories)))\(energyUnit.symbol)"
            existing.updateNutritionReference(
                quantity: values.grams,
                calories: values.calories,
                protein: values.protein,
                carbs: values.carbohydrates,
                fat: values.fat
            )
            applyEditedPer100Values(to: existing)
            existing.usageCount += 1
        } else {
            let preference = FoodPreference(
                keyword: values.name,
                brand: values.brand,
                defaultDescription: "\(Self.trimmedNumber(values.grams))\(quantityUnit), \(Self.trimmedNumber(energyUnit.fromKilocalories(values.calories)))\(energyUnit.symbol)",
                category: category,
                energyUnit: energyUnit
            )
            preference.updateNutritionReference(
                quantity: values.grams,
                calories: values.calories,
                protein: values.protein,
                carbs: values.carbohydrates,
                fat: values.fat
            )
            applyEditedPer100Values(to: preference)
            modelContext.insert(preference)
        }

        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyEditedPer100Values(to preference: FoodPreference) {
        if energyInputMode == .per100,
           let displayedEnergy = parsedRawNumber(calories) {
            preference.caloriesPer100 = energyUnit.toKilocalories(displayedEnergy)
        }

        if nutritionInputMode == .per100 {
            preference.proteinPer100 = parsedRawNumber(protein) ?? 0
            preference.carbsPer100 = parsedRawNumber(carbohydrates) ?? 0
            preference.fatPer100 = parsedRawNumber(fat) ?? 0
        }
    }

    private func removePreference(_ preference: FoodPreference) {
        modelContext.delete(preference)

        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func existingPreference(for name: String, brand: String?) -> FoodPreference? {
        let normalizedName = Self.normalizedPreferenceName(name)
        let normalizedBrand = Self.normalizedOptionalText(brand)
        guard !normalizedName.isEmpty else { return nil }
        return existingPreferences.first {
            Self.normalizedPreferenceName($0.keyword) == normalizedName
                && Self.normalizedOptionalText($0.brand) == normalizedBrand
        }
    }

    private static func normalizedPreferenceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private func validatedValues() -> (name: String, brand: String?, grams: Double, calories: Double, protein: Double, carbohydrates: Double, fat: Double)? {
        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "请输入食物名称"
            return nil
        }

        let requiresQuantity = energyInputMode == .per100 || nutritionInputMode == .per100
        guard let gramsValue = validatedNumber(grams, fieldName: "摄入量", isRequired: requiresQuantity),
              let proteinInput = validatedNumber(protein, fieldName: "蛋白质"),
              let carbohydratesInput = validatedNumber(carbohydrates, fieldName: "碳水化合物"),
              let fatInput = validatedNumber(fat, fieldName: "脂肪") else {
            return nil
        }

        if requiresQuantity && gramsValue <= 0 {
            errorMessage = "请输入大于0的摄入量"
            return nil
        }

        guard let caloriesValue = computedCalories else {
            errorMessage = energyInputMode == .per100
                ? "请输入有效的热量和摄入量"
                : "请输入有效热量"
            return nil
        }

        errorMessage = nil
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let nutrientScale = nutritionInputMode == .per100 ? gramsValue / 100 : 1
        return (
            trimmedName,
            trimmedBrand.isEmpty ? nil : trimmedBrand,
            gramsValue,
            caloriesValue,
            proteinInput * nutrientScale,
            carbohydratesInput * nutrientScale,
            fatInput * nutrientScale
        )
    }

    private func validatedNumber(_ text: String, fieldName: String, isRequired: Bool = false) -> Double? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
            if isRequired {
                errorMessage = "请输入\(fieldName)"
                return nil
            }
            return 0
        }

        guard let value = parsedRawNumber(trimmedText), value >= 0 else {
            errorMessage = "\(fieldName)请输入有效数字"
            return nil
        }

        return value
    }

    private func parsedRawNumber(_ text: String) -> Double? {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !normalizedText.isEmpty else { return nil }
        return Double(normalizedText)
    }

    private static func trimmedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        DayDetailView(
            date: Date(),
            entries: [],
            energyBurned: DailyEnergyBurned(date: Date().startOfDay, activeCalories: 320, restingCalories: 1450)
        )
    }
}
