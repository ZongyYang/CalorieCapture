import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()

    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var manualWeightEntries: [WeightEntry]

    @State private var goalRefreshTrigger = UUID()
    @State private var showingAIAdvisor = false
    @State private var showingAPIKeySetup = false

    private var currentGoal: UserGoal? { goals.first }

    private var hasHealthKitCalories: Bool {
        healthKitService.totalCaloriesBurned > 0
    }

    private var todayEntries: [FoodEntry] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return allEntries.filter { $0.createdAt >= startOfDay }
    }

    var totalCaloriesConsumed: Double {
        todayEntries.reduce(0) { $0 + $1.calories }
    }

    var totalProtein: Double {
        todayEntries.reduce(0) { $0 + $1.protein }
    }

    var totalCarbs: Double {
        todayEntries.reduce(0) { $0 + $1.carbohydrates }
    }

    var totalFat: Double {
        todayEntries.reduce(0) { $0 + $1.fat }
    }

    private var currentWeight: Double? {
        let latestManual = manualWeightEntries.first?.weight
        let latestHealthKit = healthKitService.currentWeight
        return latestHealthKit ?? latestManual
    }

    private var combinedWeightHistory: [WeightRecord] {
        var records = healthKitService.dailyWeights
        records.append(contentsOf: manualWeightEntries.map { WeightRecord(date: $0.date, weight: $0.weight) })

        let grouped = Dictionary(grouping: records) { record in
            Calendar.current.startOfDay(for: record.date)
        }

        return grouped.map { (_, records) in
            records.first!
        }.sorted { $0.date > $1.date }
    }

    private var totalCaloriesBurned: Double {
        healthKitService.totalCaloriesBurned
    }

    private var restingCalories: Double {
        healthKitService.basalCaloriesBurned
    }

    private var activeCalories: Double {
        healthKitService.activeCaloriesBurned
    }

    private var recommendedCalories: Double? {
        guard let goal = currentGoal, let weight = currentWeight else { return nil }
        return goal.recommendedDailyCalories(
            currentWeight: weight,
            dailyEnergyExpenditure: healthKitService.recentAverageCaloriesBurned
        )
    }

    // Target deficit is user-defined in goal settings. Existing goals fall back to the previous automatic value.
    private var targetDeficit: Double? {
        guard let goal = currentGoal, let weight = currentWeight else { return nil }
        return goal.plannedDailyDeficit(currentWeight: weight)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    calorieBalanceSection

                    metabolismCard

                    macroNutrientsSection

                    foodListSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("今日概览")
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
            .task {
                await healthKitService.requestAuthorization()
                await healthKitService.fetchRecentAverageCaloriesBurned()
            }
            .refreshable {
                await healthKitService.fetchTodayCaloriesBurned()
                await healthKitService.fetchRecentAverageCaloriesBurned()
            }
            .onChange(of: currentGoal?.targetDate) {
                goalRefreshTrigger = UUID()
            }
            .onChange(of: currentGoal?.updatedAt) {
                goalRefreshTrigger = UUID()
            }
        }
    }

    private var calorieBalanceSection: some View {
        VStack(spacing: 8) {
            CalorieBalanceView(
                consumed: totalCaloriesConsumed,
                burned: totalCaloriesBurned,
                targetDeficit: targetDeficit
            )
            .id(goalRefreshTrigger)

            if hasHealthKitCalories {
                Text("来自健康 App 今日能量数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无健康 App 今日能量数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metabolismCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日消耗明细")
                .font(.headline)

            HStack(spacing: 16) {
                // BMR
                VStack(spacing: 4) {
                    Image(systemName: "bed.double.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    Text("\(Int(restingCalories))")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("静息能量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Activity calories
                VStack(spacing: 4) {
                    Image(systemName: "applewatch")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("\(Int(activeCalories))")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("活动能量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Total calories burned
                VStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("\(Int(totalCaloriesBurned))")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("总消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private var macroNutrientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("营养摄入")
                .font(.headline)

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
    }

    private var foodListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日记录")
                    .font(.headline)
                Spacer()
                Text("\(todayEntries.count)项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if todayEntries.isEmpty {
                Text("还没有记录哦")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                FoodListView()
                    .frame(minHeight: 200)
            }
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self, WeightEntry.self], inMemory: true)
}
