import SwiftUI
import SwiftData

struct GoalSettingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthKitService = HealthKitService()
    @Query private var goals: [UserGoal]
    @Query private var settings: [UserSettings]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    // Current weight passed from parent or from weight entries
    var passedCurrentWeight: Double?
    var passedAverageDailyCaloriesBurned: Double?
    var passedAverageDailyCaloriesBurnedDays: Int = 0

    private var currentWeight: Double? {
        passedCurrentWeight ?? weightEntries.first?.weight
    }

    private var averageDailyCaloriesBurned: Double? {
        healthKitService.recentAverageCaloriesBurned ?? passedAverageDailyCaloriesBurned
    }

    private var averageDailyCaloriesBurnedDays: Int {
        healthKitService.recentAverageCaloriesBurnedDays > 0
            ? healthKitService.recentAverageCaloriesBurnedDays
            : passedAverageDailyCaloriesBurnedDays
    }

    @State private var targetWeight: Double = 65  // Input value in user's preferred unit
    @State private var height: Double = 170
    @State private var age: Int = 30
    @State private var gender: String = "male"
    @State private var activityLevel: String = "moderate"
    @State private var dailyCalorieDeficit: Double = 500
    @State private var hasTargetDate: Bool = false
    @State private var targetDate: Date = Date().addingTimeInterval(86400 * 90)
    @State private var initialized = false

    var currentGoal: UserGoal? { goals.first }

    private var weightUnit: WeightUnit {
        settings.first?.preferredWeightUnit ?? .kg
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("身体信息") {
                    HStack {
                        Text("身高")
                        Spacer()
                        TextField("cm", value: $height, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("cm")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("年龄")
                        Spacer()
                        TextField("岁", value: $age, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("岁")
                            .foregroundStyle(.secondary)
                    }

                    Picker("性别", selection: $gender) {
                        Text("男").tag("male")
                        Text("女").tag("female")
                    }
                }

                Section("目标设置") {
                    HStack {
                        Text("目标体重")
                        Spacer()
                        TextField(weightUnit.shortName, value: $targetWeight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(weightUnit.shortName)
                            .foregroundStyle(.secondary)
                    }

                    if hasTargetDate {
                        DatePicker("目标日期", selection: $targetDate, in: Date()..., displayedComponents: .date)

                        Button(role: .destructive) {
                            hasTargetDate = false
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("清除目标日期")
                            }
                        }
                    } else {
                        Button {
                            hasTargetDate = true
                            targetDate = Date().addingTimeInterval(86400 * 90)  // Default to 90 days from now
                        } label: {
                            HStack {
                                Image(systemName: "calendar.badge.plus")
                                Text("设置目标日期")
                            }
                        }
                    }
                }

                Section("活动水平") {
                    Picker("日常活动量", selection: $activityLevel) {
                        Text("久坐（很少运动）").tag("sedentary")
                        Text("轻度（每周1-3次运动）").tag("light")
                        Text("中度（每周3-5次运动）").tag("moderate")
                        Text("活跃（每周6-7次运动）").tag("active")
                        Text("非常活跃（运动员/体力劳动）").tag("very_active")
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    HStack {
                        Text("每日热量缺口")
                        Spacer()
                        TextField("kcal", value: $dailyCalorieDeficit, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("kcal")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("热量目标")
                } footer: {
                    Text("推荐摄入 = 每日消耗 - 热量缺口。每日消耗优先使用 HealthKit 最近完整日期的平均总消耗。")
                }

                Section {
                    calorieRecommendation
                }

                Section {
                    Button("保存目标") {
                        saveGoal()
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.blue)
                }
            }
            .navigationTitle("设置目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadExistingGoal()
            }
            .task {
                await healthKitService.requestAuthorization()
                await healthKitService.fetchRecentAverageCaloriesBurned()
            }
        }
    }

    private var calorieRecommendation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("建议每日摄入")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Convert to kg for calculations
            let targetWeightInKg = weightUnit.toKg(targetWeight)

            let goal = UserGoal(
                targetWeight: targetWeightInKg,
                height: height,
                age: age,
                gender: gender,
                activityLevel: activityLevel,
                targetDate: hasTargetDate ? targetDate : nil,
                dailyCalorieDeficit: max(dailyCalorieDeficit, 0)
            )

            // Use actual current weight if available, otherwise estimate
            let weightForCalc = currentWeight ?? (targetWeightInKg + 5)
            let isEstimated = currentWeight == nil
            let estimatedTDEE = goal.calculateTDEE(currentWeight: weightForCalc)
            let dailyExpenditure = averageDailyCaloriesBurned ?? estimatedTDEE
            let recommended = goal.recommendedDailyCalories(
                currentWeight: weightForCalc,
                dailyEnergyExpenditure: dailyExpenditure
            )

            HStack {
                VStack {
                    Text("\(Int(recommended))")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                    Text("推荐摄入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack {
                    Text("\(Int(dailyExpenditure))")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                    Text("每日消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack {
                    Text("\(Int(goal.plannedDailyDeficit(currentWeight: weightForCalc)))")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                    Text("热量缺口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isEstimated {
                Text("* 基于预估当前体重 \(weightUnit.format(weightForCalc)) 计算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("* 基于当前体重 \(weightUnit.format(weightForCalc)) 计算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if averageDailyCaloriesBurned != nil {
                Text("* 每日消耗使用 HealthKit 最近 \(averageDailyCaloriesBurnedDays) 个完整日平均总消耗")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("* 暂无 HealthKit 平均消耗数据，每日消耗暂用身体信息和活动水平估算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if recommended <= 1200 {
                Text("* 推荐摄入低于 1200 kcal 时会按 1200 kcal 显示")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func loadExistingGoal() {
        guard !initialized else { return }
        initialized = true

        if let goal = currentGoal {
            // Convert stored kg value to user's preferred unit
            // Round to 1 decimal to avoid floating point precision issues (e.g., 124.9999 → 125.0)
            let convertedWeight = weightUnit.fromKg(goal.targetWeight)
            targetWeight = (convertedWeight * 10).rounded() / 10
            height = goal.height
            age = goal.age
            gender = goal.gender
            activityLevel = goal.activityLevel
            let weightForCalc = currentWeight ?? (goal.targetWeight + 5)
            dailyCalorieDeficit = goal.plannedDailyDeficit(currentWeight: weightForCalc)
            if let date = goal.targetDate {
                hasTargetDate = true
                targetDate = date
            }
        } else {
            // Set default based on unit
            targetWeight = weightUnit == .lb ? 143.0 : 65.0
        }
    }

    private func saveGoal() {
        // Convert from user's unit to kg for storage
        // Round the input first to avoid precision issues
        let roundedTargetWeight = (targetWeight * 10).rounded() / 10
        let targetWeightInKg = weightUnit.toKg(roundedTargetWeight)

        if let existing = currentGoal {
            // Update existing goal in-place for better SwiftData observation
            existing.targetWeight = targetWeightInKg
            existing.height = height
            existing.age = age
            existing.gender = gender
            existing.activityLevel = activityLevel
            existing.dailyCalorieDeficit = max(dailyCalorieDeficit, 0)
            existing.targetDate = hasTargetDate ? targetDate : nil
            existing.updatedAt = Date()
        } else {
            // Create new goal
            let goal = UserGoal(
                targetWeight: targetWeightInKg,
                height: height,
                age: age,
                gender: gender,
                activityLevel: activityLevel,
                targetDate: hasTargetDate ? targetDate : nil,
                dailyCalorieDeficit: max(dailyCalorieDeficit, 0)
            )
            modelContext.insert(goal)
        }

        // Explicitly save to ensure changes are persisted
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    GoalSettingView(passedCurrentWeight: 70.0)
        .modelContainer(for: [UserGoal.self, FoodEntry.self, UserSettings.self, WeightEntry.self], inMemory: true)
}
