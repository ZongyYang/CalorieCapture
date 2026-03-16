import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()
    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var manualWeightEntries: [WeightEntry]
    @Query private var settings: [UserSettings]

    @State private var showingGoalSettings = false
    @State private var showingWeightEntry = false

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
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
            .navigationTitle("目标")
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
                GoalSettingView(passedCurrentWeight: currentWeight)
            }
            .sheet(isPresented: $showingWeightEntry) {
                ManualWeightEntryView()
            }
            .task {
                await healthKitService.requestAuthorization()
            }
            .refreshable {
                await healthKitService.fetchWeightHistory()
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

#Preview {
    GoalsView()
        .modelContainer(for: [UserGoal.self, WeightEntry.self, UserSettings.self], inMemory: true)
}
