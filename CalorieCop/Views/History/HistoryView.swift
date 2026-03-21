import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()

    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    @State private var showingAIAdvisor = false

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

    private var estimatedTDEE: Double {
        guard let goal = currentGoal, let weight = currentWeight else { return 2000 }
        return goal.calculateTDEE(currentWeight: weight)
    }

    private var groupedByDay: [(date: Date, entries: [FoodEntry])] {
        let grouped = Dictionary(grouping: allEntries) { entry in
            Calendar.current.startOfDay(for: entry.createdAt)
        }
        return grouped.sorted { $0.key > $1.key }.map { (date: $0.key, entries: $0.value) }
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
            .navigationTitle("历史记录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAIAdvisor = true
                    } label: {
                        Image(systemName: "sparkles")
                        Text("AI顾问")
                    }
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
            .task {
                await healthKitService.requestAuthorization()
            }
        }
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
            ForEach(groupedByDay, id: \.date) { day in
                NavigationLink {
                    DayDetailView(date: day.date, entries: day.entries)
                } label: {
                    DaySummaryRow(date: day.date, entries: day.entries, estimatedTDEE: estimatedTDEE)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct DaySummaryRow: View {
    let date: Date
    let entries: [FoodEntry]
    var estimatedTDEE: Double = 2000

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
    private var deficit: Double {
        estimatedTDEE - totalCalories
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formatDate(date))
                    .font(.headline)
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
                    Text("\(Int(totalCalories))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                // 缺口/超出
                HStack(spacing: 4) {
                    Image(systemName: deficit >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(deficit >= 0 ? .green : .red)
                    Text(deficit >= 0 ? "缺口\(Int(deficit))" : "超出\(Int(abs(deficit)))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(deficit >= 0 ? .green : .red)
                }

                Spacer()

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
            formatter.dateFormat = "M月d日 EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.string(from: date)
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self, WeightEntry.self], inMemory: true)
}
