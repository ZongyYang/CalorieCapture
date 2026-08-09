import SwiftUI
import SwiftData
import PhotosUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthKitService = HealthKitService()

    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @Query(sort: \FoodPreference.usageCount, order: .reverse)
    private var foodPreferences: [FoodPreference]

    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var manualWeightEntries: [WeightEntry]

    @State private var goalRefreshTrigger = UUID()
    @State private var showingAIAdvisor = false
    @State private var showingSettings = false
    @State private var showingFoodInput = false
    @State private var showingDashboardCamera = false
    @State private var showingDashboardCameraAlert = false
    @State private var dashboardSearchText = ""
    @State private var dashboardSelectedImage: UIImage?
    @State private var dashboardSelectedPhoto: PhotosPickerItem?
    @State private var isDashboardSearchFocused = false
    @State private var shouldAutoStartFoodRecognition = false
    @State private var dashboardQuickRecordMessage: String?

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

    private var savedPreferenceSuggestions: [FoodPreference] {
        let query = dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return Array(
            foodPreferences
                .filter {
                    $0.keyword.localizedCaseInsensitiveContains(query)
                        || ($0.brand?.localizedCaseInsensitiveContains(query) ?? false)
                }
                .sorted { lhs, rhs in
                    if lhs.usageCount != rhs.usageCount {
                        return lhs.usageCount > rhs.usageCount
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                .prefix(3)
        )
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
            .background(AppSurfaceStyle.pageBackground)
            .navigationTitle("今日概览")
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
            .sheet(isPresented: $showingFoodInput) {
                FoodInputView(
                    initialSearchText: dashboardSearchText,
                    initialImage: dashboardSelectedImage,
                    autoStartRecognition: shouldAutoStartFoodRecognition
                ) {
                    dashboardSearchText = ""
                    dashboardSelectedImage = nil
                    dashboardSelectedPhoto = nil
                    shouldAutoStartFoodRecognition = false
                    showingFoodInput = false
                }
            }
            .sheet(isPresented: $showingDashboardCamera) {
                CameraView(image: $dashboardSelectedImage)
            }
            .alert("相机不可用", isPresented: $showingDashboardCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请在真机上使用相机功能，或从相册选择图片。")
            }
            .onChange(of: dashboardSelectedPhoto) {
                Task {
                    if let data = try? await dashboardSelectedPhoto?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        dashboardSelectedImage = image
                    }
                }
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
        VStack(spacing: 12) {
            foodSearchSection

            if !savedPreferenceSuggestions.isEmpty {
                SavedPreferenceSuggestionPanel(
                    preferences: savedPreferenceSuggestions,
                    onSelect: { preference in
                        dashboardSearchText = preference.keyword
                        presentFoodInput(autoStartRecognition: false)
                    },
                    onRecord: { preference in
                        quickRecordPreference(preference)
                    }
                )
            }

            if let dashboardQuickRecordMessage {
                Label(dashboardQuickRecordMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

    private var foodSearchSection: some View {
        HStack(spacing: 8) {
            ImagePasteTextField(
                text: $dashboardSearchText,
                placeholder: "搜索习惯或输入食物",
                returnKeyType: .search,
                focusBinding: $isDashboardSearchFocused,
                onSubmit: {
                    presentFoodInput(autoStartRecognition: true)
                },
                onPasteImage: { image in
                    dashboardSelectedImage = image
                },
                onPasteFailure: {}
            )

            if !dashboardSearchText.isEmpty {
                Button {
                    dashboardSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 22)

            Button {
                presentFoodInput(autoStartRecognition: true)
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .opacity(canRecognizeFromDashboardSearch ? 1 : 0.45)
            .accessibilityLabel("AI识别")

            Button {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    dashboardSelectedImage = nil
                    showingDashboardCamera = true
                } else {
                    showingDashboardCameraAlert = true
                }
            } label: {
                Image(systemName: "camera.fill")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("拍照识别")

            PhotosPicker(selection: $dashboardSelectedPhoto, matching: .images) {
                Image(systemName: "photo.fill")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("从相册选择照片")
        }
        .foodSearchBarSurface()
        .onChange(of: dashboardSelectedImage) { _, image in
            if image != nil && !showingDashboardCamera {
                presentFoodInput(autoStartRecognition: false)
            }
        }
        .onChange(of: showingDashboardCamera) { _, isPresented in
            if !isPresented, dashboardSelectedImage != nil {
                presentFoodInput(autoStartRecognition: false)
            }
        }
    }

    private var canRecognizeFromDashboardSearch: Bool {
        !dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dashboardSelectedImage != nil
    }

    private func presentFoodInput(autoStartRecognition: Bool) {
        guard autoStartRecognition == false || canRecognizeFromDashboardSearch else {
            isDashboardSearchFocused = true
            return
        }

        isDashboardSearchFocused = false
        shouldAutoStartFoodRecognition = autoStartRecognition
        showingFoodInput = true
    }

    private func quickRecordPreference(_ preference: FoodPreference) {
        guard let nutrition = quickRecordNutrition(from: preference) else {
            let message = "\(preference.keyword)缺少可记录的热量数据，请先编辑食物习惯。"
            withAnimation(.easeInOut(duration: 0.18)) {
                dashboardQuickRecordMessage = message
            }
            return
        }

        let entryDate = Date()
        let entry = FoodEntry(
            rawInput: "已保存习惯: \(preference.keyword)",
            foodName: nutrition.foodName,
            brand: nutrition.brand,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbohydrates: nutrition.carbohydrates,
            fat: nutrition.fat,
            date: entryDate,
            category: preference.category,
            mealType: preference.category == .meal ? FoodMealType.defaultType(for: entryDate) : nil,
            energyUnit: preference.energyUnit
        )

        preference.usageCount += 1
        modelContext.insert(entry)
        try? modelContext.save()
        dashboardSearchText = ""

        let message = "已记录 \(preference.keyword)"
        withAnimation(.easeInOut(duration: 0.18)) {
            dashboardQuickRecordMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard dashboardQuickRecordMessage == message else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                dashboardQuickRecordMessage = nil
            }
        }
    }

    private func quickRecordNutrition(from preference: FoodPreference) -> NutritionInfo? {
        if let quantity = preference.defaultGrams, quantity > 0,
           let caloriesPer100 = preference.resolvedCaloriesPer100 {
            let scale = quantity / 100
            return NutritionInfo(
                foodName: preference.keyword,
                brand: preference.brand,
                grams: quantity,
                calories: caloriesPer100 * scale,
                protein: (preference.resolvedProteinPer100 ?? 0) * scale,
                carbohydrates: (preference.resolvedCarbsPer100 ?? 0) * scale,
                fat: (preference.resolvedFatPer100 ?? 0) * scale,
                confidence: "saved",
                notes: "从已保存习惯快速记录",
                daysAgo: 0
            )
        }

        if let calories = preference.defaultCalories {
            return NutritionInfo(
                foodName: preference.keyword,
                brand: preference.brand,
                grams: preference.defaultGrams ?? 0,
                calories: calories,
                protein: preference.defaultProtein ?? 0,
                carbohydrates: preference.defaultCarbs ?? 0,
                fat: preference.defaultFat ?? 0,
                confidence: "saved",
                notes: "从已保存习惯快速记录",
                daysAgo: 0
            )
        }

        guard let caloriesPer100 = preference.resolvedCaloriesPer100 else {
            return nil
        }

        return NutritionInfo(
            foodName: preference.keyword,
            brand: preference.brand,
            grams: 100,
            calories: caloriesPer100,
            protein: preference.resolvedProteinPer100 ?? 0,
            carbohydrates: preference.resolvedCarbsPer100 ?? 0,
            fat: preference.resolvedFatPer100 ?? 0,
            confidence: "saved",
            notes: "从已保存习惯按单位基准快速记录",
            daysAgo: 0
        )
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
                        .foregroundStyle(.red)
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
        .background(AppSurfaceStyle.cardBackground)
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
                    .background(AppSurfaceStyle.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                FoodListView()
            }
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self, WeightEntry.self], inMemory: true)
}
