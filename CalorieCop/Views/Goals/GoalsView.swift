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

    @State private var showingGoalSettings = false
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DailyCalorieStatsChartView(stats: dailyCalorieStats)

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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("统计")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingWeightEntry = true
                    } label: {
                        Image(systemName: "plus.circle")
                        Text("记录体重")
                    }
                    .font(.caption)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Weight unit toggle
                        Menu {
                            ForEach(WeightUnit.allCases, id: \.self) { unit in
                                Button {
                                    setWeightUnit(unit)
                                } label: {
                                    HStack {
                                        Text(unit.displayName)
                                        if unit == weightUnit {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(weightUnit.shortName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Button {
                            showingGoalSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingGoalSettings) {
                GoalSettingView(
                    passedCurrentWeight: currentWeight,
                    passedAverageDailyCaloriesBurned: healthKitService.recentAverageCaloriesBurned,
                    passedAverageDailyCaloriesBurnedDays: healthKitService.recentAverageCaloriesBurnedDays
                )
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
                showingGoalSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
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

    private var hasData: Bool {
        stats.contains { $0.hasAnyData }
    }

    private var xAxisDates: [Date] {
        let dates = stats.map(\.date).sorted()
        let maxLabelCount = 5

        guard dates.count > maxLabelCount else {
            return dates
        }

        let lastIndex = dates.count - 1
        return (0..<maxLabelCount).map { index in
            let scaledIndex = Double(index) * Double(lastIndex) / Double(maxLabelCount - 1)
            return dates[Int(scaledIndex.rounded())]
        }
    }

    private var totalIntake: Double {
        stats.reduce(0) { $0 + $1.intakeCalories }
    }

    private var totalBurned: Double? {
        let values = stats.compactMap(\.burnedCalories)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
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

                legendRow

                summaryRow
            } else {
                emptyState
            }
        }
        .padding()
        .background(Color(.systemBackground))
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
                    AxisValueLabel {
                        Text(formatAxisDate(date))
                            .font(.caption2)
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
    }

    private var legendRow: some View {
        HStack(spacing: 14) {
            legendItem("摄入", color: .orange, symbol: "square.fill")
            legendItem("消耗", color: .red, symbol: "square.fill")
            legendItem("缺口", color: .green, symbol: "line.diagonal")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
        }
    }

    private var summaryRow: some View {
        HStack {
            metric("总摄入", value: totalIntake.formattedCalories, unit: "kcal", color: .orange)

            Spacer()

            metric("总消耗", value: totalBurned?.formattedCalories ?? "--", unit: "kcal", color: .red)

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
}

#Preview {
    GoalsView()
        .modelContainer(for: [UserGoal.self, FoodEntry.self, WeightEntry.self, UserSettings.self], inMemory: true)
}
