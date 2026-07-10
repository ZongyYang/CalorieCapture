import SwiftUI
import SwiftData

struct DayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Query private var foodPreferences: [FoodPreference]

    let date: Date
    let energyBurned: DailyEnergyBurned?
    @State private var entries: [FoodEntry]
    @State private var entryToDelete: FoodEntry?
    @State private var entryToEdit: FoodEntry?
    @State private var fetchedEnergyBurned: DailyEnergyBurned?
    @State private var showingDeleteConfirmation = false
    @State private var showingBackfillSheet = false
    @State private var showingAIAdvisor = false
    @State private var showingAPIKeySetup = false
    @State private var showingDailyBriefing = false

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
        DailyBriefing(date: date, entries: entries, energyBurned: displayedEnergyBurned)
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
                    showingDailyBriefing = true
                } label: {
                    DailyBriefingPreviewCard(briefing: dailyBriefing)
                }
                .buttonStyle(.plain)

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

                    ForEach(entries.sorted { $0.createdAt < $1.createdAt }) { entry in
                        SwipeableHistoryFoodEntryRow(
                            entry: entry,
                            isSavedAsPreference: isSavedAsPreference(entry),
                            onEdit: {
                                entryToEdit = entry
                            },
                            onTogglePreference: {
                                togglePreference(for: entry)
                            },
                            onDelete: {
                                entryToDelete = entry
                                showingDeleteConfirmation = true
                            }
                        )
                        .contextMenu {
                            Button {
                                entryToEdit = entry
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                entryToDelete = entry
                                showingDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
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
                APISettingsToolbarButton(isPresented: $showingAPIKeySetup)
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
        .sheet(isPresented: $showingAPIKeySetup) {
            APIKeySetupView()
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
        .alert("确认删除", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {
                entryToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let entry = entryToDelete {
                    deleteEntry(entry)
                }
            }
        } message: {
            if let entry = entryToDelete {
                Text("确定要删除「\(entry.foodName)」吗？此操作无法撤销。")
            }
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
        entryToDelete = nil
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
            defaultDescription: "\(Self.trimmedNumber(entry.grams))\(entry.category.quantityUnitSymbol), \(Self.trimmedNumber(entry.calories))kcal"
        )
        preference.defaultGrams = entry.grams
        preference.defaultCalories = entry.calories
        preference.defaultProtein = entry.protein
        preference.defaultCarbs = entry.carbohydrates
        preference.defaultFat = entry.fat
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
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
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
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
        .background(Color(.secondarySystemGroupedBackground))
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

private struct SwipeableHistoryFoodEntryRow: View {
    let entry: FoodEntry
    let isSavedAsPreference: Bool
    let onEdit: () -> Void
    let onTogglePreference: () -> Void
    let onDelete: () -> Void

    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    private let deleteButtonWidth: CGFloat = 88

    private var currentOffset: CGFloat {
        min(0, max(-deleteButtonWidth, settledOffset + dragOffset))
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

            HistoryFoodEntryRow(
                entry: entry,
                isSavedAsPreference: isSavedAsPreference,
                onTogglePreference: onTogglePreference,
                onEdit: onEdit
            )
            .offset(x: currentOffset)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                if settledOffset == 0 {
                    onEdit()
                } else {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        settledOffset = 0
                    }
                }
            }
            .gesture(swipeGesture)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: settledOffset)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($dragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projectedOffset = settledOffset + value.predictedEndTranslation.width
                settledOffset = projectedOffset < -deleteButtonWidth / 2 ? -deleteButtonWidth : 0
            }
    }
}

private struct HistoryFoodEntryRow: View {
    let entry: FoodEntry
    let isSavedAsPreference: Bool
    let onTogglePreference: () -> Void
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
                        .background(Color(.systemBackground))
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
                Text("\(entry.calories.formattedCalories) kcal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)

                HStack(spacing: 2) {
                    Button {
                        onTogglePreference()
                    } label: {
                        Image(systemName: isSavedAsPreference ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isSavedAsPreference ? Color.pink : Color.secondary)
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSavedAsPreference ? "取消保存习惯" : "保存习惯")

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
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            return "每100单位"
        }
    }
}

private struct FoodEntryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]

    let entry: FoodEntry
    var onSaved: (() -> Void)?

    @State private var foodName = ""
    @State private var brand = ""
    @State private var grams = ""
    @State private var calories = ""
    @State private var energyUnit: EnergyUnit = .kilocalorie
    @State private var energyInputMode: FoodEntryEditEnergyInputMode = .total
    @State private var protein = ""
    @State private var carbohydrates = ""
    @State private var fat = ""
    @State private var category: FoodEntryCategory = .meal
    @State private var mealType: FoodMealType = .lunch
    @State private var errorMessage: String?

    private var quantityUnit: String {
        category.quantityUnitSymbol
    }

    private var energyInputTitle: String {
        switch energyInputMode {
        case .total:
            return "总热量"
        case .per100:
            return "热量/100\(quantityUnit)"
        }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    editFormModule(title: "食物信息", systemImage: "fork.knife") {
                        VStack(spacing: 10) {
                            TextField("名称", text: $foodName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(editInputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            TextField("品牌（可选）", text: $brand)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(editInputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
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
                                    Text(mode == .per100 ? "每100\(quantityUnit)" : mode.title).tag(mode)
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
                                isRequired: energyInputMode == .per100
                            )
                            numberField(
                                title: energyInputTitle,
                                text: $calories,
                                unit: energyUnit.symbol,
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

                    editFormModule(title: "营养成分（可选）", systemImage: "chart.pie.fill") {
                        VStack(spacing: 10) {
                            numberField(title: "蛋白质", text: $protein, unit: "g")
                            numberField(title: "碳水化合物", text: $carbohydrates, unit: "g")
                            numberField(title: "脂肪", text: $fat, unit: "g")
                        }
                    }

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
                    .background(isSavedAsPreference ? Color.pink : Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

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
            .background(Color(.systemGroupedBackground))
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
            .onAppear {
                foodName = entry.foodName
                brand = entry.brand ?? ""
                grams = String(format: "%.1f", entry.grams)
                calories = String(format: "%.0f", entry.calories)
                energyUnit = .kilocalorie
                energyInputMode = .total
                protein = String(format: "%.1f", entry.protein)
                carbohydrates = String(format: "%.1f", entry.carbohydrates)
                fat = String(format: "%.1f", entry.fat)
                category = entry.category
                mealType = entry.mealType ?? FoodMealType.defaultType(for: entry.createdAt)
            }
            .onChange(of: energyUnit) { oldUnit, newUnit in
                convertEnergyUnit(from: oldUnit, to: newUnit)
            }
            .onChange(of: energyInputMode) { oldMode, newMode in
                convertEnergyInputMode(from: oldMode, to: newMode)
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
        .background(Color(.systemGray6))
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
                .frame(width: 42, alignment: .leading)
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

    private func saveChanges() {
        guard let values = validatedValues() else { return }

        entry.foodName = values.name
        entry.brand = values.brand
        entry.grams = values.grams
        entry.calories = values.calories
        entry.protein = values.protein
        entry.carbohydrates = values.carbohydrates
        entry.fat = values.fat
        entry.category = category
        entry.mealType = category == .meal ? mealType : nil

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
            existing.defaultDescription = "\(Self.trimmedNumber(values.grams))\(quantityUnit), \(Self.trimmedNumber(values.calories))kcal"
            existing.defaultGrams = values.grams
            existing.defaultCalories = values.calories
            existing.defaultProtein = values.protein
            existing.defaultCarbs = values.carbohydrates
            existing.defaultFat = values.fat
            existing.usageCount += 1
        } else {
            let preference = FoodPreference(
                keyword: values.name,
                brand: values.brand,
                defaultDescription: "\(Self.trimmedNumber(values.grams))\(quantityUnit), \(Self.trimmedNumber(values.calories))kcal"
            )
            preference.defaultGrams = values.grams
            preference.defaultCalories = values.calories
            preference.defaultProtein = values.protein
            preference.defaultCarbs = values.carbohydrates
            preference.defaultFat = values.fat
            modelContext.insert(preference)
        }

        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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

        guard let gramsValue = validatedNumber(grams, fieldName: "摄入量", isRequired: energyInputMode == .per100),
              let proteinValue = validatedNumber(protein, fieldName: "蛋白质"),
              let carbohydratesValue = validatedNumber(carbohydrates, fieldName: "碳水化合物"),
              let fatValue = validatedNumber(fat, fieldName: "脂肪") else {
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
        return (trimmedName, trimmedBrand.isEmpty ? nil : trimmedBrand, gramsValue, caloriesValue, proteinValue, carbohydratesValue, fatValue)
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
