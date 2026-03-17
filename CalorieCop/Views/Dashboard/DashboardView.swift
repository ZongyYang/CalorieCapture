import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()

    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var manualWeightEntries: [WeightEntry]

    @State private var useAppleWatchData = true
    @State private var goalRefreshTrigger = UUID()

    private var currentGoal: UserGoal? { goals.first }

    private var hasAppleWatchData: Bool {
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

    private var calculatedTDEE: Double? {
        guard let goal = currentGoal, let weight = currentWeight else { return nil }
        return goal.calculateTDEE(currentWeight: weight)
    }

    private var totalCaloriesBurned: Double {
        if useAppleWatchData && hasAppleWatchData {
            guard let goal = currentGoal, let weight = currentWeight else {
                return healthKitService.totalCaloriesBurned
            }
            let bmr = goal.calculateBMR(currentWeight: weight)
            return bmr + healthKitService.activeCaloriesBurned
        }
        return calculatedTDEE ?? healthKitService.totalCaloriesBurned
    }

    private var activeCalories: Double {
        guard let goal = currentGoal, let weight = currentWeight else { return 0 }
        if useAppleWatchData && hasAppleWatchData {
            return healthKitService.activeCaloriesBurned
        }
        return goal.calculateTDEE(currentWeight: weight) - goal.calculateBMR(currentWeight: weight)
    }

    private var isShowingEstimated: Bool {
        !useAppleWatchData || !hasAppleWatchData
    }

    private var recommendedCalories: Double? {
        guard let goal = currentGoal, let weight = currentWeight else { return nil }
        return goal.recommendedDailyCalories(currentWeight: weight)
    }

    // Target deficit = TDEE - recommended (the planned daily deficit to reach weight goal)
    private var targetDeficit: Double? {
        guard let goal = currentGoal, let weight = currentWeight else { return nil }
        let tdee = goal.calculateTDEE(currentWeight: weight)
        let recommended = goal.recommendedDailyCalories(currentWeight: weight)
        return tdee - recommended
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    calorieBalanceSection

                    if let goal = currentGoal, let weight = currentWeight {
                        metabolismCard(goal: goal, weight: weight)
                    }

                    macroNutrientsSection

                    foodListSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("今日概览")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        useAppleWatchData.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: useAppleWatchData ? "applewatch" : "function")
                                .font(.caption)
                            Text(useAppleWatchData ? "实时" : "估算")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(useAppleWatchData ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                    }
                    .disabled(!hasAppleWatchData)
                    .opacity(hasAppleWatchData ? 1 : 0.5)
                }
            }
            .task {
                await healthKitService.requestAuthorization()
            }
            .refreshable {
                await healthKitService.fetchTodayCaloriesBurned()
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
            .id("\(goalRefreshTrigger)-\(useAppleWatchData)")

            if isShowingEstimated {
                Text("基于身体数据估算消耗")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("来自 Apple Watch 实时数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metabolismCard(goal: UserGoal, weight: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日消耗明细")
                .font(.headline)

            HStack(spacing: 16) {
                // BMR
                VStack(spacing: 4) {
                    Image(systemName: "bed.double.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    Text("\(Int(goal.calculateBMR(currentWeight: weight)))")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("基础代谢")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Activity calories
                VStack(spacing: 4) {
                    Image(systemName: isShowingEstimated ? "figure.walk" : "applewatch")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("\(Int(activeCalories))")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text(isShowingEstimated ? "活动消耗(估)" : "活动消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Total TDEE
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
