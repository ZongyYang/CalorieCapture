import SwiftUI
import SwiftData
import PhotosUI
import WidgetKit

private struct DashboardEditingPreference: Identifiable {
    let id: UUID
    let preference: FoodPreference

    init(_ preference: FoodPreference) {
        self.id = preference.id
        self.preference = preference
    }
}

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
    @State private var editingPreference: DashboardEditingPreference?
    @State private var editingSuggestedEntry: FoodEntry?
    @State private var showingDashboardCamera = false
    @State private var showingDashboardCameraAlert = false
    @State private var dashboardSearchText = ""
    @State private var dashboardSelectedImage: UIImage?
    @State private var dashboardSelectedPhoto: PhotosPickerItem?
    @State private var isDashboardSearchFocused = false
    @State private var dashboardQuickRecordMessage: String?
    @State private var isDashboardRecognizing = false
    @State private var dashboardRecognitionNutrition: NutritionInfo?
    @State private var dashboardRecognitionList: [NutritionInfo] = []
    @State private var dashboardRecognitionRawInput = ""
    @State private var showingDashboardRecognitionResult = false
    @State private var showingDashboardMultipleRecognitionResult = false
    @State private var dashboardRecognitionError: String?
    @State private var pendingPreferenceDeletionIDs: Set<UUID> = []

    private let aiService = MiniMaxService()

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
        guard !query.isEmpty, dashboardSelectedImage == nil else { return [] }

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

    private var unsavedEntrySuggestions: [FoodEntry] {
        guard dashboardSelectedImage == nil else { return [] }
        return allEntries.unsavedSearchSuggestions(
            matching: dashboardSearchText,
            on: Date(),
            excluding: foodPreferences
        )
    }

    private var isDashboardSearchMode: Bool {
        isDashboardSearchFocused
            || !dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dashboardSelectedImage != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    calorieBalanceSection

                    if !isDashboardSearchMode {
                        metabolismCard

                        macroNutrientsSection

                        foodListSection
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.2), value: isDashboardSearchMode)
            }
            .background(AppSurfaceStyle.pageBackground)
            .navigationTitle("今日")
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
            .sheet(
                isPresented: $showingDashboardRecognitionResult,
                onDismiss: finishDashboardRecognitionFlow
            ) {
                if let nutrition = dashboardRecognitionNutrition {
                    FoodConfirmationView(
                        rawInput: dashboardRecognitionRawInput,
                        originalNutrition: nutrition
                    ) { editedNutrition, category, mealType in
                        saveDashboardRecognizedFood(
                            editedNutrition,
                            category: category,
                            mealType: mealType
                        )
                    }
                }
            }
            .sheet(
                isPresented: $showingDashboardMultipleRecognitionResult,
                onDismiss: finishDashboardRecognitionFlow
            ) {
                MultipleFoodConfirmationView(
                    nutritionList: dashboardRecognitionList,
                    onConfirm: saveDashboardRecognizedFoods
                )
            }
            .sheet(item: $editingPreference, onDismiss: {
                dashboardSearchText = ""
            }) { item in
                FoodPreferenceEditView(
                    preference: item.preference,
                    onRecordIntake: { nutrition in
                        recordPreferenceIntake(from: item.preference, nutrition: nutrition)
                    }
                )
            }
            .sheet(item: $editingSuggestedEntry) { entry in
                FoodEntryEditView(entry: entry)
            }
            .fullScreenCover(isPresented: $showingDashboardCamera) {
                CameraView(image: $dashboardSelectedImage)
            }
            .alert("相机不可用", isPresented: $showingDashboardCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请在真机上使用相机功能，或从相册选择图片。")
            }
            .alert(
                "AI 识别失败",
                isPresented: Binding(
                    get: { dashboardRecognitionError != nil },
                    set: { isPresented in
                        if !isPresented {
                            dashboardRecognitionError = nil
                        }
                    }
                )
            ) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(dashboardRecognitionError ?? "请稍后重试。")
            }
            .onChange(of: dashboardSelectedPhoto) {
                Task {
                    if let data = try? await dashboardSelectedPhoto?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        dashboardSelectedImage = image
                        isDashboardSearchFocused = true
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
                WidgetCenter.shared.reloadAllTimelines()
            }
            .onChange(of: currentGoal?.targetDate) {
                goalRefreshTrigger = UUID()
            }
            .onChange(of: currentGoal?.updatedAt) {
                goalRefreshTrigger = UUID()
            }
        }
        .onChange(of: isDashboardSearchMode) { wasSearching, isSearching in
            if wasSearching && !isSearching {
                commitPendingPreferenceDeletions()
            }
        }
        .onDisappear {
            commitPendingPreferenceDeletions()
        }
    }

    private var calorieBalanceSection: some View {
        VStack(spacing: 12) {
            foodSearchSection

            if !isDashboardSearchMode, let dashboardQuickRecordMessage {
                Label(dashboardQuickRecordMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isDashboardSearchMode {
                CalorieBalanceView(
                    consumed: totalCaloriesConsumed,
                    burned: totalCaloriesBurned,
                    targetDeficit: targetDeficit
                )
                .id(goalRefreshTrigger)
            }

        }
    }

    private var foodSearchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ImagePasteTextField(
                        text: $dashboardSearchText,
                        placeholder: "搜索习惯或输入食物",
                        returnKeyType: .search,
                        focusBinding: $isDashboardSearchFocused,
                        onSubmit: {
                            recognizeFromDashboardSearch()
                        },
                        onPasteImage: { image in
                            dashboardSelectedImage = image
                            isDashboardSearchFocused = true
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

                    TextRecognitionActionButton(
                        isProcessing: isDashboardRecognizing,
                        isEnabled: canRecognizeFromDashboardSearch,
                        action: recognizeFromDashboardSearch
                    )

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
                .frame(maxWidth: .infinity)
                .foodSearchBarSurface()

                if isDashboardSearchMode {
                    Button("取消") {
                        commitPendingPreferenceDeletions()
                        dashboardSearchText = ""
                        dashboardSelectedImage = nil
                        dashboardSelectedPhoto = nil
                        isDashboardSearchFocused = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }

            if let selectedImage = dashboardSelectedImage {
                HStack(spacing: 12) {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("已添加食物图片")
                            .font(.subheadline.weight(.medium))
                        Text("可继续输入份量或烹饪方式，再点 AI 识别")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        dashboardSelectedImage = nil
                        dashboardSelectedPhoto = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除图片")
                }
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !savedPreferenceSuggestions.isEmpty {
                SavedPreferenceSuggestionPanel(
                    preferences: savedPreferenceSuggestions,
                    pendingDeletionIDs: pendingPreferenceDeletionIDs,
                    onSelect: { preference in
                        editingPreference = DashboardEditingPreference(preference)
                    },
                    onToggleSaved: { preference in
                        togglePendingPreferenceDeletion(preference)
                    },
                    onRecord: { preference in
                        quickRecordPreference(preference)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if !unsavedEntrySuggestions.isEmpty {
                TodayEntrySuggestionPanel(
                    entries: unsavedEntrySuggestions,
                    onSelect: { entry in
                        editingSuggestedEntry = entry
                    },
                    onSavePreference: { entry in
                        saveSuggestedEntryAsPreference(entry)
                    },
                    onRecord: { entry in
                        quickRecordSuggestedEntry(entry)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(
            .easeInOut(duration: 0.2),
            value: isDashboardSearchMode
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: savedPreferenceSuggestions.map { $0.id }
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: unsavedEntrySuggestions.map { $0.id }
        )
        .onChange(of: showingDashboardCamera) { _, isPresented in
            if !isPresented, dashboardSelectedImage != nil {
                isDashboardSearchFocused = true
            }
        }
    }

    private var canRecognizeFromDashboardSearch: Bool {
        !dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dashboardSelectedImage != nil
    }

    private func togglePendingPreferenceDeletion(_ preference: FoodPreference) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if pendingPreferenceDeletionIDs.contains(preference.id) {
                pendingPreferenceDeletionIDs.remove(preference.id)
            } else {
                pendingPreferenceDeletionIDs.insert(preference.id)
            }
        }
    }

    private func commitPendingPreferenceDeletions() {
        guard !pendingPreferenceDeletionIDs.isEmpty else { return }

        let pendingIDs = pendingPreferenceDeletionIDs
        for preference in foodPreferences where pendingIDs.contains(preference.id) {
            modelContext.delete(preference)
        }

        do {
            try modelContext.save()
            pendingPreferenceDeletionIDs.removeAll()
        } catch {
            dashboardQuickRecordMessage = "删除食物习惯失败：\(error.localizedDescription)"
        }
    }

    private func recognizeFromDashboardSearch() {
        guard !isDashboardRecognizing else { return }

        let input = dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedImage = dashboardSelectedImage
        let isDirectNutritionSummary = NutritionSummaryParser.canParse(input)
        guard !input.isEmpty || selectedImage != nil else {
            isDashboardSearchFocused = true
            return
        }

        if selectedImage != nil {
            guard APIKeyManager.isDeepSeekConfigured else {
                dashboardRecognitionError = "图片识别需要设置 DeepSeek API 密钥。"
                return
            }
        } else {
            guard isDirectNutritionSummary
                    || APIKeyManager.isTextParsingModelConfigured(APIKeyManager.textParsingModel) else {
                let model = APIKeyManager.textParsingModel
                dashboardRecognitionError = "当前选择 \(model.displayName)，请先配置 \(model.providerName) API 密钥。"
                return
            }
        }

        isDashboardSearchFocused = false
        dashboardRecognitionRawInput = input.isEmpty ? "图片识别" : input
        isDashboardRecognizing = true
        dashboardRecognitionError = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        Task {
            do {
                let nutritionList: [NutritionInfo]
                if let selectedImage {
                    nutritionList = try await aiService.parseFoodImageMultiple(
                        selectedImage,
                        additionalContext: input.isEmpty ? nil : input,
                        preferences: foodPreferences
                    )
                } else {
                    nutritionList = try await aiService.parseFoodInputMultiple(
                        input,
                        preferences: foodPreferences
                    )
                }

                await MainActor.run {
                    isDashboardRecognizing = false
                    if nutritionList.count == 1 {
                        dashboardRecognitionNutrition = nutritionList.first
                        showingDashboardRecognitionResult = true
                    } else if nutritionList.count > 1 {
                        dashboardRecognitionList = nutritionList
                        showingDashboardMultipleRecognitionResult = true
                    } else {
                        dashboardRecognitionError = "未能识别任何食物。"
                    }
                }
            } catch {
                await MainActor.run {
                    isDashboardRecognizing = false
                    dashboardRecognitionError = error.localizedDescription
                }
            }
        }
    }

    private func saveDashboardRecognizedFood(
        _ nutrition: NutritionInfo,
        category: FoodEntryCategory,
        mealType: FoodMealType?
    ) -> FoodEntry {
        let entry = FoodEntry(
            rawInput: dashboardRecognitionRawInput,
            foodName: nutrition.foodName,
            brand: nutrition.brand,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbohydrates: nutrition.carbohydrates,
            fat: nutrition.fat,
            date: nutrition.entryDate,
            category: category,
            mealType: category == .meal ? mealType : nil,
            energyUnit: .kilocalorie
        )
        modelContext.insert(entry)
        try? modelContext.save()
        return entry
    }

    private func saveDashboardRecognizedFoods(_ nutritionList: [NutritionInfo]) {
        for nutrition in nutritionList {
            let entryDate = nutrition.entryDate
            let entry = FoodEntry(
                rawInput: dashboardRecognitionRawInput,
                foodName: nutrition.foodName,
                brand: nutrition.brand,
                grams: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbohydrates: nutrition.carbohydrates,
                fat: nutrition.fat,
                date: entryDate,
                category: .meal,
                mealType: FoodMealType.defaultType(for: entryDate)
            )
            modelContext.insert(entry)
        }
        try? modelContext.save()
    }

    private func finishDashboardRecognitionFlow() {
        dashboardSearchText = ""
        dashboardSelectedImage = nil
        dashboardSelectedPhoto = nil
        dashboardRecognitionRawInput = ""
        dashboardRecognitionNutrition = nil
        dashboardRecognitionList = []
        isDashboardSearchFocused = false
    }

    private func quickRecordPreference(_ preference: FoodPreference) {
        guard let nutrition = quickRecordNutrition(from: preference) else {
            let message = "\(preference.keyword)缺少可记录的热量数据，请先编辑食物习惯。"
            withAnimation(.easeInOut(duration: 0.18)) {
                dashboardQuickRecordMessage = message
            }
            return
        }

        recordPreferenceIntake(from: preference, nutrition: nutrition)
    }

    private func saveSuggestedEntryAsPreference(_ entry: FoodEntry) {
        guard !foodPreferences.contains(where: {
            $0.matches(keyword: entry.foodName, brand: entry.brand)
        }) else { return }

        modelContext.insert(FoodPreference(entry: entry))
        do {
            try modelContext.save()
            showDashboardQuickRecordMessage("已保存习惯 \(entry.foodName)")
        } catch {
            dashboardQuickRecordMessage = "保存食物习惯失败：\(error.localizedDescription)"
        }
    }

    private func quickRecordSuggestedEntry(_ source: FoodEntry) {
        let entryDate = Date()
        let entry = FoodEntry(
            rawInput: "从今日记录再次摄入: \(source.foodName)",
            foodName: source.foodName,
            brand: source.brand,
            grams: source.grams,
            calories: source.calories,
            protein: source.protein,
            carbohydrates: source.carbohydrates,
            fat: source.fat,
            date: entryDate,
            category: source.category,
            mealType: source.category == .meal ? FoodMealType.defaultType(for: entryDate) : nil,
            energyUnit: source.energyUnit,
            nutritionEstimatedByAI: source.nutritionEstimatedByAI == true
        )
        modelContext.insert(entry)

        do {
            try modelContext.save()
            dashboardSearchText = ""
            isDashboardSearchFocused = false
            showDashboardQuickRecordMessage("已记录 \(source.foodName)")
        } catch {
            dashboardQuickRecordMessage = "记录摄入失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func recordPreferenceIntake(from preference: FoodPreference, nutrition: NutritionInfo) -> FoodEntry {
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
        showDashboardQuickRecordMessage("已记录 \(preference.keyword)")
        return entry
    }

    private func showDashboardQuickRecordMessage(_ message: String) {
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
                    Image(systemName: "figure.run")
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

/// Tap to run the current AI action; long-press to choose the text model.
/// The selection is shared by Today, Record, and AI Advisor.
struct TextRecognitionActionButton: View {
    let isProcessing: Bool
    let isEnabled: Bool
    let action: () -> Void
    let accessibilityLabel: String
    let processingAccessibilityLabel: String
    let modelSelectionHint: String

    init(
        isProcessing: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void,
        accessibilityLabel: String = "AI识别",
        processingAccessibilityLabel: String = "正在识别",
        modelSelectionHint: String = "长按可切换文字识别模型"
    ) {
        self.isProcessing = isProcessing
        self.isEnabled = isEnabled
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.processingAccessibilityLabel = processingAccessibilityLabel
        self.modelSelectionHint = modelSelectionHint
    }

    @AppStorage(APIKeyManager.textParsingModelUserDefaultsKey)
    private var selectedModelRawValue = TextParsingModel.flash.rawValue

    private var selectedModel: TextParsingModel {
        TextParsingModel(rawValue: selectedModelRawValue) ?? .flash
    }

    var body: some View {
        if isProcessing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .accessibilityLabel(processingAccessibilityLabel)
        } else {
            Button {
                guard isEnabled else { return }
                action()
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(modelSelectionHint)
            .contextMenu {
                ForEach(TextParsingModel.allCases) { model in
                    Button {
                        selectedModelRawValue = model.rawValue
                    } label: {
                        Label(
                            model.displayName,
                            systemImage: model == selectedModel ? "checkmark" : "circle"
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self, WeightEntry.self], inMemory: true)
}
