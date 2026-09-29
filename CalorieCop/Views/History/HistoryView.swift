import SwiftUI
import SwiftData

private struct HistoryDay: Identifiable {
    let date: Date
    let entries: [FoodEntry]

    var id: Date { date }
}

private struct HistoryPeriodSection: Identifiable {
    let id: String
    let title: String
    let days: [HistoryDay]
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var healthKitService = HealthKitService()

    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    @State private var showingAIAdvisor = false
    @State private var showingSettings = false
    @State private var collapsedSectionIDs: Set<String> = []

    private var currentGoal: UserGoal? { goals.first }

    private var currentWeight: Double? {
        let latestManual = weightEntries.first?.weight
        let latestHealthKit = healthKitService.currentWeight
        return latestHealthKit ?? latestManual
    }

    // Combine HealthKit and manual weight data for AI advisor
    private var combinedWeightHistory: [WeightRecord] {
        var allRecords: [WeightRecord] = []

        // Add HealthKit records
        allRecords.append(contentsOf: healthKitService.dailyWeights)

        // Add manual records
        for entry in weightEntries {
            allRecords.append(WeightRecord(date: entry.date, weight: entry.weight))
        }

        // Sort by date descending and remove duplicates (keep first for same day)
        let grouped = Dictionary(grouping: allRecords) { record in
            Calendar.current.startOfDay(for: record.date)
        }

        return grouped.map { (_, records) in
            records.first!
        }.sorted { $0.date > $1.date }
    }

    private var historyCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var groupedByDay: [HistoryDay] {
        let entriesByDay = Dictionary(grouping: allEntries) { entry in
            historyCalendar.startOfDay(for: entry.createdAt)
        }

        var availableDays = Set(entriesByDay.keys)
        let firstTrackedDay = historyCalendar.startOfDay(for: energyFetchStartDate)
        let today = historyCalendar.startOfDay(for: Date())

        for record in healthKitService.dailyEnergyBurned.values where record.totalCalories > 0 {
            let day = historyCalendar.startOfDay(for: record.date)
            guard day >= firstTrackedDay, day <= today else { continue }
            availableDays.insert(day)
        }

        return availableDays
            .sorted(by: >)
            .map { day in
                HistoryDay(date: day, entries: entriesByDay[day] ?? [])
            }
    }

    private var historySections: [HistoryPeriodSection] {
        let calendar = historyCalendar
        let today = calendar.startOfDay(for: Date())
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let previousWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeekStart) ?? currentWeekStart
        let currentMonthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonthStart) ?? currentMonthStart

        var recentBuckets: [String: [HistoryDay]] = [:]
        var olderMonthBuckets: [Date: [HistoryDay]] = [:]

        for day in groupedByDay {
            if day.date >= currentWeekStart {
                recentBuckets["this-week", default: []].append(day)
            } else if day.date >= previousWeekStart {
                recentBuckets["last-week", default: []].append(day)
            } else if day.date >= currentMonthStart {
                recentBuckets["earlier-this-month", default: []].append(day)
            } else if day.date >= previousMonthStart {
                recentBuckets["last-month", default: []].append(day)
            } else {
                let monthStart = calendar.dateInterval(of: .month, for: day.date)?.start ?? day.date
                olderMonthBuckets[monthStart, default: []].append(day)
            }
        }

        let recentDefinitions = [
            (id: "this-week", title: "本周"),
            (id: "last-week", title: "上周"),
            (id: "earlier-this-month", title: "本月较早"),
            (id: "last-month", title: "上月")
        ]

        var sections = recentDefinitions.compactMap { definition -> HistoryPeriodSection? in
            guard let days = recentBuckets[definition.id], !days.isEmpty else { return nil }
            return HistoryPeriodSection(id: definition.id, title: definition.title, days: days)
        }

        sections.append(contentsOf: olderMonthBuckets
            .sorted { $0.key > $1.key }
            .map { month, days in
                HistoryPeriodSection(
                    id: "month-\(month.timeIntervalSinceReferenceDate)",
                    title: formatHistoryMonth(month),
                    days: days
                )
            })

        return sections
    }

    private var energyFetchStartDate: Date {
        let earliestEntryDate = allEntries.map(\.createdAt).min() ?? Date()
        return Calendar.current.startOfDay(for: earliestEntryDate)
    }

    private var energyFetchID: String {
        guard !allEntries.isEmpty else { return "empty" }

        let calendar = Calendar.current
        let earliestDay = calendar.startOfDay(for: allEntries.map(\.createdAt).min() ?? Date())
        let latestDay = calendar.startOfDay(for: allEntries.map(\.createdAt).max() ?? Date())
        return "\(earliestDay.timeIntervalSinceReferenceDate)-\(latestDay.timeIntervalSinceReferenceDate)-\(allEntries.count)"
    }

    private func energyBurned(for date: Date) -> DailyEnergyBurned? {
        healthKitService.dailyEnergyBurned[Calendar.current.startOfDay(for: date)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if allEntries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("历史")
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
            .task(id: energyFetchID) {
                await refreshHealthData()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await refreshHealthData()
                }
            }
            .refreshable {
                await refreshHealthData()
            }
        }
    }

    private func refreshHealthData() async {
        await healthKitService.requestAuthorization()

        guard !allEntries.isEmpty else {
            return
        }

        await healthKitService.fetchDailyCaloriesBurned(from: energyFetchStartDate)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("暂无历史记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("开始记录食物后，这里会显示每日摘要")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var historyList: some View {
        List {
            ForEach(historySections) { section in
                Section {
                    if !collapsedSectionIDs.contains(section.id) {
                        ForEach(section.days) { day in
                            NavigationLink {
                                DayDetailView(
                                    date: day.date,
                                    entries: day.entries,
                                    energyBurned: energyBurned(for: day.date)
                                )
                            } label: {
                                DaySummaryRow(
                                    date: day.date,
                                    entries: day.entries,
                                    energyBurned: energyBurned(for: day.date)
                                )
                            }
                        }
                    }
                } header: {
                    Button {
                        toggleHistorySection(section.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Text("\(section.days.count)天")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .rotationEffect(
                                    .degrees(collapsedSectionIDs.contains(section.id) ? 0 : 180)
                                )
                                .frame(width: 18, height: 18)
                                .animation(
                                    .easeInOut(duration: 0.35),
                                    value: collapsedSectionIDs.contains(section.id)
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func toggleHistorySection(_ id: String) {
        withAnimation(.easeInOut(duration: 0.35)) {
            if collapsedSectionIDs.contains(id) {
                collapsedSectionIDs.remove(id)
            } else {
                collapsedSectionIDs.insert(id)
            }
        }
    }

    private func formatHistoryMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }
}

struct DaySummaryRow: View {
    let date: Date
    let entries: [FoodEntry]
    let energyBurned: DailyEnergyBurned?

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

    // 缺口 = 消耗 - 摄入 (正数表示热量缺口，有利于减重)
    private var deficit: Double? {
        guard let energyBurned else { return nil }
        return energyBurned.totalCalories - totalCalories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(formatDate(date))
                    .font(.headline)

                Text(formatWeekday(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
                Text("\(entries.count)项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                // 摄入
                HStack(spacing: 4) {
                    Image(systemName: "fork.knife")
                        .foregroundStyle(.orange)
                    Text("摄入\(Int(totalCalories))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                // 消耗
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.red)
                    Text("消耗\(energyBurned.map { Int($0.totalCalories).description } ?? "--")")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                // 缺口/超出
                if let deficit {
                    HStack(spacing: 4) {
                        Image(systemName: deficit >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(deficit >= 0 ? .green : .red)
                        Text(deficit >= 0 ? "缺口\(Int(deficit))" : "超出\(Int(abs(deficit)))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(deficit >= 0 ? .green : .red)
                    }
                }

                Spacer()
            }

            HStack(spacing: 6) {
                Text("蛋白\(totalProtein.formattedGrams)g")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text("碳水\(totalCarbs.formattedGrams)g")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("脂肪\(totalFat.formattedGrams)g")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.string(from: date)
        }
    }

    private func formatWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self, WeightEntry.self], inMemory: true)
}
