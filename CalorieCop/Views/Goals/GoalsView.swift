import SwiftUI
import SwiftData
import Charts

struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()
    @Query private var goals: [UserGoal]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query(sort: \WeightEntry.date, order: .reverse) private var manualWeightEntries: [WeightEntry]
    @Query private var settings: [UserSettings]

    @State private var showingAIAdvisor = false
    @State private var showingSettings = false
    @State private var showingWeightEntry = false
    private let calorieStatsDays = 14

    private var currentGoal: UserGoal? { goals.first }

    private var weightUnit: WeightUnit {
        settings.first?.preferredWeightUnit ?? .kg
    }

    private func formatWeight(_ kgValue: Double) -> String {
        weightUnit.format(kgValue)
    }

    // Combine HealthKit and manual weight data
    private var combinedWeightHistory: [WeightRecord] {
        var allRecords: [WeightRecord] = []

        // Add HealthKit records
        allRecords.append(contentsOf: healthKitService.dailyWeights)

        // Add manual records
        for entry in manualWeightEntries {
            allRecords.append(WeightRecord(date: entry.date, weight: entry.weight))
        }

        // Sort by date and remove duplicates (prefer HealthKit for same day)
        let grouped = Dictionary(grouping: allRecords) { record in
            Calendar.current.startOfDay(for: record.date)
        }

        return grouped.map { (date, records) in
            // Just return the first record for each day
            records.first!
        }.sorted { $0.date < $1.date }
    }

    private var currentWeight: Double? {
        // Prefer most recent weight from any source
        let latestManual = manualWeightEntries.first?.weight
        let latestHealthKit = healthKitService.currentWeight

        if let manual = latestManual, let healthKit = latestHealthKit {
            // Return whichever is more recent
            if let manualDate = manualWeightEntries.first?.date {
                if let hkDate = healthKitService.weightHistory.first?.date {
                    return manualDate > hkDate ? manual : healthKit
                }
            }
            return healthKit
        }

        return latestManual ?? latestHealthKit
    }

    private var calorieStatsStartDate: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -(calorieStatsDays - 1), to: today) ?? today
    }

    private var dailyCalorieStats: [DailyCalorieStat] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calorieStatsStartDate
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()

        let entriesInRange = allEntries.filter { entry in
            entry.createdAt >= startDate && entry.createdAt < endExclusive
        }

        guard let firstIntakeDay = entriesInRange
            .map({ calendar.startOfDay(for: $0.createdAt) })
            .min() else {
            return []
        }

        let displayStartDate = max(startDate, firstIntakeDay)
        let displayDays = calendar.dateComponents([.day], from: displayStartDate, to: today).day.map { $0 + 1 } ?? 0
        guard displayDays > 0 else { return [] }

        let entriesByDay = Dictionary(grouping: entriesInRange) { entry in
            calendar.startOfDay(for: entry.createdAt)
        }

        return (0..<displayDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: displayStartDate) else {
                return nil
            }

            let intake = entriesByDay[day]?.reduce(0) { $0 + $1.calories } ?? 0
            let burned = healthKitService.dailyEnergyBurned[day]?.totalCalories

            return DailyCalorieStat(
                date: day,
                intakeCalories: intake,
                burnedCalories: burned
            )
        }
    }

    private var dailyNutritionStats: [DailyNutritionStat] {
        let calendar = Calendar.current
        let entriesByDay = Dictionary(grouping: allEntries) { entry in
            calendar.startOfDay(for: entry.createdAt)
        }

        return dailyCalorieStats.map { calorieStat in
            let entries = entriesByDay[calorieStat.date] ?? []
            return DailyNutritionStat(
                date: calorieStat.date,
                protein: entries.reduce(0) { $0 + $1.protein },
                carbohydrates: entries.reduce(0) { $0 + $1.carbohydrates },
                fat: entries.reduce(0) { $0 + $1.fat }
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DailyCalorieStatsChartView(stats: dailyCalorieStats)

                    DailyNutritionStatsChartView(stats: dailyNutritionStats)

                    // Weight Chart
                    WeightChartView(
                        weightHistory: combinedWeightHistory,
                        targetWeight: currentGoal?.targetWeight,
                        weightUnit: weightUnit
                    )

                    // Goal Progress
                    if let goal = currentGoal {
                        goalProgressCard(goal)
                    } else {
                        noGoalCard
                    }
                }
                .padding()
            }
            .background(AppSurfaceStyle.pageBackground)
            .navigationTitle("统计")
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
            .sheet(isPresented: $showingWeightEntry) {
                ManualWeightEntryView()
            }
            .task {
                await healthKitService.requestAuthorization()
                await healthKitService.fetchRecentAverageCaloriesBurned()
                await healthKitService.fetchDailyCaloriesBurned(from: calorieStatsStartDate)
            }
            .refreshable {
                await healthKitService.fetchWeightHistory()
                await healthKitService.fetchRecentAverageCaloriesBurned()
                await healthKitService.fetchDailyCaloriesBurned(from: calorieStatsStartDate)
            }
        }
    }

    private func setWeightUnit(_ unit: WeightUnit) {
        if let existing = settings.first {
            existing.preferredWeightUnit = unit
        } else {
            let newSettings = UserSettings(weightUnit: unit)
            modelContext.insert(newSettings)
        }
    }

    private var noGoalCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("还没有设置目标")
                .font(.headline)

            Text("设置目标体重，获取个性化的每日热量建议")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("设置目标") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private func goalProgressCard(_ goal: UserGoal) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("目标进度")
                    .font(.headline)
                Spacer()
                if let targetDate = goal.targetDate {
                    let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: targetDate).day ?? 0
                    Text("还剩 \(daysLeft) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let weight = currentWeight {
                let startWeight = combinedWeightHistory.first?.weight ?? weight
                let totalToLose = startWeight - goal.targetWeight
                let lost = startWeight - weight
                let progress = totalToLose > 0 ? min(lost / totalToLose, 1.0) : 1.0

                VStack(spacing: 8) {
                    ProgressView(value: max(progress, 0))
                        .tint(.green)

                    HStack {
                        VStack(alignment: .leading) {
                            Text("当前")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatWeight(weight))
                                .font(.title2)
                                .fontWeight(.bold)
                        }

                        Spacer()

                        VStack {
                            Text("已减")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatWeight(max(lost, 0)))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.green)
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("目标")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatWeight(goal.targetWeight))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text("暂无体重数据")
                        .foregroundStyle(.secondary)
                    Button("手动记录体重") {
                        showingWeightEntry = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

private struct DailyNutritionStat: Identifiable {
    let date: Date
    let protein: Double
    let carbohydrates: Double
    let fat: Double

    var id: Date { date }

    var hasAnyData: Bool {
        protein > 0 || carbohydrates > 0 || fat > 0
    }
}

private struct DailyNutritionStatsChartView: View {
    let stats: [DailyNutritionStat]
    @State private var scrollPosition: Date

    init(stats: [DailyNutritionStat]) {
        self.stats = stats
        _scrollPosition = State(initialValue: Self.latestSevenDayStart(for: stats))
    }

    private var hasData: Bool {
        stats.contains { $0.hasAnyData }
    }

    private var xAxisDates: [Date] {
        stats.map(\.date).sorted()
    }

    private var xAxisFontSize: CGFloat {
        stats.count > 10 ? 8 : 10
    }

    private var averageProtein: Double {
        average(\.protein)
    }

    private var averageCarbohydrates: Double {
        average(\.carbohydrates)
    }

    private var averageFat: Double {
        average(\.fat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("营养成分统计")
                    .font(.headline)
                Spacer()
                Text("有记录以来 \(stats.count) 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasData {
                chart
                    .frame(height: 220)

                summaryRow
            } else {
                emptyState
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private var chart: some View {
        Chart {
            ForEach(stats) { stat in
                BarMark(
                    x: .value("日期", stat.date, unit: .day),
                    y: .value("克", stat.protein)
                )
                .foregroundStyle(by: .value("营养成分", "蛋白质"))
                .position(by: .value("营养成分", "蛋白质"))

                BarMark(
                    x: .value("日期", stat.date, unit: .day),
                    y: .value("克", stat.carbohydrates)
                )
                .foregroundStyle(by: .value("营养成分", "碳水"))
                .position(by: .value("营养成分", "碳水"))

                BarMark(
                    x: .value("日期", stat.date, unit: .day),
                    y: .value("克", stat.fat)
                )
                .foregroundStyle(by: .value("营养成分", "脂肪"))
                .position(by: .value("营养成分", "脂肪"))
            }
        }
        .chartForegroundStyleScale([
            "蛋白质": Color.red,
            "碳水": Color.blue,
            "脂肪": Color.yellow
        ])
        .chartXAxis {
            AxisMarks(values: xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(collisionResolution: .disabled) {
                        Text(formatAxisDate(date))
                            .font(.system(size: xAxisFontSize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let grams = value.as(Double.self) {
                        Text("\(Int(grams))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: sevenDayInterval)
        .chartScrollPosition(x: $scrollPosition)
        .onChange(of: stats.last?.date) { _, latestDate in
            guard latestDate != nil else { return }
            scrollPosition = Self.latestSevenDayStart(for: stats)
        }
    }

    private var summaryRow: some View {
        HStack {
            metric("日均蛋白质", value: averageProtein, color: .red)
            Spacer()
            metric("日均碳水", value: averageCarbohydrates, color: .blue)
            Spacer()
            metric("日均脂肪", value: averageFat, color: .yellow)
        }
    }

    private func metric(_ title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", value))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                Text("g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无营养成分统计")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("记录蛋白质、碳水和脂肪后会显示每日变化")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private func average(_ keyPath: KeyPath<DailyNutritionStat, Double>) -> Double {
        guard !stats.isEmpty else { return 0 }
        return stats.reduce(0) { $0 + $1[keyPath: keyPath] } / Double(stats.count)
    }

    private func formatAxisDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return "" }
        return "\(month)/\(day)"
    }

    private var sevenDayInterval: TimeInterval {
        7 * 24 * 60 * 60
    }

    private static func latestSevenDayStart(for stats: [DailyNutritionStat]) -> Date {
        guard let latestDate = stats.map(\.date).max() else {
            return Calendar.current.startOfDay(for: Date())
        }
        return Calendar.current.date(byAdding: .day, value: -6, to: latestDate) ?? latestDate
    }
}

private struct DailyCalorieStat: Identifiable {
    let date: Date
    let intakeCalories: Double
    let burnedCalories: Double?

    var id: Date { date }

    var deficitCalories: Double? {
        burnedCalories.map { $0 - intakeCalories }
    }

    var hasAnyData: Bool {
        intakeCalories > 0 || (burnedCalories ?? 0) > 0
    }
}

private struct DailyCalorieStatsChartView: View {
    let stats: [DailyCalorieStat]
    @State private var scrollPosition: Date

    init(stats: [DailyCalorieStat]) {
        self.stats = stats
        _scrollPosition = State(initialValue: Self.latestSevenDayStart(for: stats))
    }

    private var hasData: Bool {
        stats.contains { $0.hasAnyData }
    }

    private var xAxisDates: [Date] {
        stats.map(\.date).sorted()
    }

    private var xAxisFontSize: CGFloat {
        stats.count > 10 ? 8 : 10
    }

    private var averageIntake: Double {
        guard !stats.isEmpty else { return 0 }
        let total = stats.reduce(0) { $0 + $1.intakeCalories }
        return total / Double(stats.count)
    }

    private var averageBurned: Double? {
        let values = stats.compactMap(\.burnedCalories)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var averageDeficit: Double? {
        let values = stats.compactMap(\.deficitCalories)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("热量统计")
                    .font(.headline)
                Spacer()
                Text("有记录以来 \(stats.count) 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasData {
                chart
                    .frame(height: 240)

                summaryRow
            } else {
                emptyState
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("基线", 0))
                .foregroundStyle(Color.secondary.opacity(0.25))

            ForEach(stats) { stat in
                BarMark(
                    x: .value("日期", stat.date, unit: .day),
                    y: .value("kcal", stat.intakeCalories)
                )
                .foregroundStyle(by: .value("指标", "摄入"))
                .position(by: .value("指标", "摄入"))

                if let burned = stat.burnedCalories {
                    BarMark(
                        x: .value("日期", stat.date, unit: .day),
                        y: .value("kcal", burned)
                    )
                    .foregroundStyle(by: .value("指标", "消耗"))
                    .position(by: .value("指标", "消耗"))
                }
            }

            ForEach(stats) { stat in
                if let deficit = stat.deficitCalories {
                    LineMark(
                        x: .value("日期", stat.date, unit: .day),
                        y: .value("kcal", deficit)
                    )
                    .foregroundStyle(by: .value("指标", "缺口"))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("日期", stat.date, unit: .day),
                        y: .value("kcal", deficit)
                    )
                    .foregroundStyle(by: .value("指标", "缺口"))
                    .symbolSize(24)
                }
            }
        }
        .chartForegroundStyleScale([
            "摄入": Color.orange,
            "消耗": Color.red,
            "缺口": Color.green
        ])
        .chartXAxis {
            AxisMarks(values: xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(collisionResolution: .disabled) {
                        Text(formatAxisDate(date))
                            .font(.system(size: xAxisFontSize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let calories = value.as(Double.self) {
                        Text("\(Int(calories))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: sevenDayInterval)
        .chartScrollPosition(x: $scrollPosition)
        .onChange(of: stats.last?.date) { _, latestDate in
            guard latestDate != nil else { return }
            scrollPosition = Self.latestSevenDayStart(for: stats)
        }
    }

    private var summaryRow: some View {
        HStack {
            metric("平均摄入", value: averageIntake.formattedCalories, unit: "kcal", color: .orange)

            Spacer()

            metric("平均消耗", value: averageBurned?.formattedCalories ?? "--", unit: "kcal", color: .red)

            Spacer()

            if let averageDeficit {
                metric(
                    "平均缺口",
                    value: abs(averageDeficit).formattedCalories,
                    unit: averageDeficit >= 0 ? "kcal" : "超出",
                    color: averageDeficit >= 0 ? .green : .pink
                )
            } else {
                metric("平均缺口", value: "--", unit: "kcal", color: .green)
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无热量统计")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("记录摄入并同步健康 App 后会显示每日摄入、消耗和缺口")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private func formatAxisDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else {
            return ""
        }
        return "\(month)/\(day)"
    }

    private var sevenDayInterval: TimeInterval {
        7 * 24 * 60 * 60
    }

    private static func latestSevenDayStart(for stats: [DailyCalorieStat]) -> Date {
        guard let latestDate = stats.map(\.date).max() else {
            return Calendar.current.startOfDay(for: Date())
        }
        return Calendar.current.date(byAdding: .day, value: -6, to: latestDate) ?? latestDate
    }
}

#Preview {
    GoalsView()
        .modelContainer(for: [UserGoal.self, FoodEntry.self, WeightEntry.self, UserSettings.self], inMemory: true)
}
