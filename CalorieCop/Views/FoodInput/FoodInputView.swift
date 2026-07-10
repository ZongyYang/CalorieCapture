import SwiftUI
import SwiftData
import PhotosUI

private enum FoodInputMode: String, CaseIterable, Identifiable {
    case manual
    case ai

    var id: Self { self }

    var title: String {
        switch self {
        case .ai:
            return "AI识别"
        case .manual:
            return "手动记录"
        }
    }
}

private enum ManualEnergyInputMode: String, CaseIterable, Identifiable {
    case total
    case per100

    var id: Self { self }

    var title: String {
        switch self {
        case .total:
            return "总热量"
        case .per100:
            return "每100单位"
        }
    }
}

struct FoodInputView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodPreference.usageCount, order: .reverse) private var foodPreferences: [FoodPreference]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query private var goals: [UserGoal]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    // Optional target date for backfilling entries
    var targetDate: Date?
    var onSaved: (() -> Void)?

    @State private var inputText = ""
    @State private var isLoading = false
    @State private var parsedNutrition: NutritionInfo?
    @State private var parsedNutritionList: [NutritionInfo] = []
    @State private var errorMessage: String?
    @State private var showConfirmation = false
    @State private var showMultipleConfirmation = false
    @State private var confirmationRawInput = ""
    @State private var confirmationInitialCategory: FoodEntryCategory = .meal
    @State private var confirmationInitialMealType: FoodMealType?

    // Image picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingCamera = false
    @State private var showingCameraAlert = false

    // Food preferences
    @State private var preferenceSearchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var preferenceToDelete: FoodPreference?
    @State private var editingPreference: EditingPreference?

    // API Key setup
    @State private var showingAPIKeySetup = false
    @State private var apiKeyCheckTrigger = false  // Used to refresh state
    @State private var showingAIAdvisor = false

    // Input mode
    @State private var inputMode: FoodInputMode = .manual

    // Manual entry
    @State private var manualFoodName = ""
    @State private var manualBrand = ""
    @State private var manualGrams = ""
    @State private var manualCalories = ""
    @State private var manualEnergyUnit: EnergyUnit = .kilocalorie
    @State private var manualEnergyInputMode: ManualEnergyInputMode = .total
    @State private var manualProtein = ""
    @State private var manualCarbohydrates = ""
    @State private var manualFat = ""
    @State private var manualCategory: FoodEntryCategory = .meal
    @State private var manualMealType: FoodMealType = .lunch
    @State private var manualPreferenceMessage: String?

    private let aiService = MiniMaxService()

    private var isAPIConfigured: Bool {
        isTextAPIConfigured || isImageAPIConfigured
    }

    private var isTextAPIConfigured: Bool {
        APIKeyManager.isDeepSeekConfigured || APIKeyManager.isMiniMaxConfigured || APIKeyManager.isQwenConfigured
    }

    private var isImageAPIConfigured: Bool {
        APIKeyManager.isQwenConfigured
    }

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var isBackfillMode: Bool {
        targetDate != nil
    }

    private var effectiveDate: Date {
        targetDate ?? Date()
    }

    private var currentGoal: UserGoal? { goals.first }

    private var currentWeight: Double? {
        weightEntries.first?.weight
    }

    private var combinedWeightHistory: [WeightRecord] {
        weightEntries
            .map { WeightRecord(date: $0.date, weight: $0.weight) }
            .sorted { $0.date > $1.date }
    }

    private var targetDateFormatted: String {
        guard let date = targetDate else { return "" }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Use apiKeyCheckTrigger to force SwiftUI to re-evaluate
                    let _ = apiKeyCheckTrigger

                    // Backfill mode banner
                    if isBackfillMode {
                        backfillBanner
                    }

                    inputModePicker

                    if inputMode == .manual {
                        manualEntrySection

                        if let error = errorMessage {
                            errorView(error)
                        }

                        manualActionButtons

                        if !foodPreferences.isEmpty {
                            savedPreferencesSection
                        }
                    } else if !isAPIConfigured {
                        // API Key setup prompt only blocks AI recognition.
                        apiKeyPromptSection
                    } else {
                        instructionText

                        // Image input section
                        imageInputSection

                        // Dynamic divider text based on whether image is selected
                        if selectedImage != nil {
                            dividerWithText("补充说明 (可选)")
                        } else {
                            dividerWithText("或直接输入文字")
                        }

                        // Text input section
                        inputField

                        if let error = errorMessage {
                            errorView(error)
                        }

                        parseButton

                        // Food preferences section
                        if !foodPreferences.isEmpty {
                            savedPreferencesSection
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle(isBackfillMode ? "补录食物" : "记录食物")
            .toolbar {
                if !isBackfillMode {
                    ToolbarItem(placement: .topBarLeading) {
                        AIAdvisorToolbarButton(isPresented: $showingAIAdvisor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    APISettingsToolbarButton(isPresented: $showingAPIKeySetup)
                }
            }
            .sheet(isPresented: $showConfirmation) {
                if let nutrition = parsedNutrition {
                    FoodConfirmationView(
                        rawInput: confirmationRawInput.isEmpty ? (inputText.isEmpty ? "图片识别" : inputText) : confirmationRawInput,
                        originalNutrition: nutrition,
                        initialCategory: confirmationInitialCategory,
                        initialMealType: confirmationInitialMealType
                    ) { editedNutrition, category, mealType in
                        saveFoodEntry(
                            with: editedNutrition,
                            category: category,
                            mealType: mealType,
                            rawInputOverride: confirmationRawInput
                        )
                    }
                }
            }
            .sheet(item: $editingPreference) { item in
                FoodPreferenceEditView(
                    preference: item.preference,
                    onRecordIntake: { nutrition in
                        recordPreferenceIntake(from: item.preference, nutrition: nutrition)
                    }
                )
            }
            .sheet(isPresented: $showingCamera) {
                CameraView(image: $selectedImage)
            }
            .sheet(isPresented: $showMultipleConfirmation) {
                MultipleFoodConfirmationView(
                    nutritionList: parsedNutritionList,
                    onConfirm: { confirmedList in
                        saveMultipleFoodEntries(confirmedList)
                    }
                )
            }
            .alert("相机不可用", isPresented: $showingCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请在真机上使用相机功能，或从相册选择图片。")
            }
            .alert("删除习惯", isPresented: $showingDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let pref = preferenceToDelete {
                        modelContext.delete(pref)
                        try? modelContext.save()
                    }
                }
            } message: {
                Text("确定要删除这个食物习惯吗？")
            }
            .onChange(of: selectedPhoto) {
                Task {
                    if let data = try? await selectedPhoto?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                    }
                }
            }
            .sheet(isPresented: $showingAPIKeySetup) {
                APIKeySetupView {
                    // Trigger refresh when keys are saved
                    apiKeyCheckTrigger.toggle()
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
            .onChange(of: showingAPIKeySetup) { _, isShowing in
                // Refresh when sheet is dismissed
                if !isShowing {
                    apiKeyCheckTrigger.toggle()
                }
            }
            .onChange(of: inputMode) {
                errorMessage = nil
                manualPreferenceMessage = nil
            }
            .onAppear {
                inputMode = .manual
                manualMealType = FoodMealType.defaultType(for: effectiveDate)
            }
        }
    }

    private var backfillBanner: some View {
        HStack {
            Image(systemName: "calendar.badge.plus")
                .foregroundStyle(.blue)
            Text("正在为 \(targetDateFormatted) 补录食物")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var inputModePicker: some View {
        Picker("输入方式", selection: $inputMode) {
            ForEach(FoodInputMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var apiKeyPromptSection: some View {
        VStack(spacing: 20) {
            Spacer()
                .frame(height: 40)

            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("需要设置 API 密钥")
                .font(.title2)
                .fontWeight(.bold)

            Text("请至少设置 DeepSeek 或 MiniMax API 密钥以启用文字解析。Qwen 用于图片识别，也可作为文字解析备用。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                    apiStatusRow(
                        name: "DeepSeek API",
                        purpose: "文字解析和 AI 顾问",
                        isConfigured: APIKeyManager.isDeepSeekConfigured
                    )
                    apiStatusRow(
                        name: "MiniMax API",
                        purpose: "文字解析和 AI 顾问",
                        isConfigured: APIKeyManager.isMiniMaxConfigured
                    )
                    apiStatusRow(
                        name: "Qwen API",
                        purpose: "图片识别和文字解析备用",
                        isConfigured: APIKeyManager.isQwenConfigured
                    )
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                showingAPIKeySetup = true
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("设置 API 密钥")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
    }

    private func apiStatusRow(name: String, purpose: String, isConfigured: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isConfigured {
                Label("已配置", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("未配置", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var instructionText: some View {
        Text("拍照识别食物，或直接输入文字解析食物")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var imageInputSection: some View {
        VStack(spacing: 12) {
            // Warning if Qwen API not configured
            // Use apiKeyCheckTrigger to force refresh
            let _ = apiKeyCheckTrigger
            if !isImageAPIConfigured {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("图片识别需要设置 Qwen API")
                        .font(.caption)
                    Spacer()
                    Button("设置") {
                        showingAPIKeySetup = true
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let image = selectedImage {
                ZStack(alignment: .topTrailing) {
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }

                    Button {
                        clearSelectedImage()
                    } label: {
                        Label("删除照片", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("删除上传的照片")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
                }
            } else {
                HStack(spacing: 16) {
                    // Camera button
                    Button {
                        if isCameraAvailable {
                            showingCamera = true
                        } else {
                            showingCameraAlert = true
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.title)
                            Text("拍照")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Photo library button
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.fill")
                                .font(.title)
                            Text("相册")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func dividerWithText(_ text: String) -> some View {
        HStack {
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)
        }
    }

    private var inputField: some View {
        let placeholder = selectedImage != nil
            ? "补充说明：如份量、时间等（可选）"
            : "例如：一碗米饭、两个鸡蛋、昨天的晚餐"

        return TextField(placeholder, text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .lineLimit(3...6)
    }

    private var manualQuantityUnit: String {
        manualCategory.quantityUnitSymbol
    }

    private var manualEnergyInputTitle: String {
        switch manualEnergyInputMode {
        case .total:
            return "总热量"
        case .per100:
            return "热量/100\(manualQuantityUnit)"
        }
    }

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.list.clipboard")
                    .foregroundStyle(.blue)
                Text("手动记录")
                    .font(.headline)
            }

            manualFormModule(title: "食物信息", systemImage: "fork.knife") {
                VStack(spacing: 10) {
                    TextField("食物名称，例如：鸡胸肉", text: $manualFoodName)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.next)

                    TextField("品牌（可选）", text: $manualBrand)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.next)
                }
            }

            manualFormModule(title: "分类", systemImage: "tag.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    manualPickerLabel("类型")

                    Picker("类型", selection: $manualCategory) {
                        ForEach(FoodEntryCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                    .pickerStyle(.segmented)

                    if manualCategory == .meal {
                        Divider()

                        manualPickerLabel("餐次")

                        Picker("餐次", selection: $manualMealType) {
                            ForEach(FoodMealType.allCases) { mealType in
                                Label(mealType.rawValue, systemImage: mealType.systemImage)
                                    .tag(mealType)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            manualFormModule(title: "热量设置", systemImage: "flame.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    manualPickerLabel("热量单位")

                    Picker("热量单位", selection: $manualEnergyUnit) {
                        ForEach(EnergyUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider()

                    manualPickerLabel("热量输入")

                    Picker("热量输入", selection: $manualEnergyInputMode) {
                        ForEach(ManualEnergyInputMode.allCases) { mode in
                            Text(mode == .per100 ? "每100\(manualQuantityUnit)" : mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            manualFormModule(title: "摄入信息", systemImage: "scalemass.fill") {
                VStack(spacing: 10) {
                    manualNumberField(
                        title: "摄入量",
                        placeholder: manualCategory == .drink ? "例如 300" : "例如 150",
                        unit: manualQuantityUnit,
                        text: $manualGrams,
                        isRequired: manualEnergyInputMode == .per100
                    )

                    manualNumberField(
                        title: manualEnergyInputTitle,
                        placeholder: "0",
                        unit: manualEnergyUnit.symbol,
                        text: $manualCalories,
                        isRequired: true
                    )

                    if let manualTotalEnergyText {
                        Label(manualTotalEnergyText, systemImage: "equal.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            manualFormModule(title: "营养成分（可选）", systemImage: "chart.pie.fill") {
                VStack(spacing: 10) {
                    manualNumberField(
                        title: "蛋白质",
                        placeholder: "0",
                        unit: "g",
                        text: $manualProtein
                    )
                    manualNumberField(
                        title: "碳水化合物",
                        placeholder: "0",
                        unit: "g",
                        text: $manualCarbohydrates
                    )
                    manualNumberField(
                        title: "脂肪",
                        placeholder: "0",
                        unit: "g",
                        text: $manualFat
                    )
                }
            }
        }
    }

    private func manualFormModule<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .frame(width: 18)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            content()
        }
        .padding(14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func manualPickerLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

    private func manualNumberField(
        title: String,
        placeholder: String,
        unit: String,
        text: Binding<String>,
        isRequired: Bool = false
    ) -> some View {
        HStack {
            Text(title + (isRequired ? " *" : ""))
                .foregroundStyle(.primary)

            Spacer()

            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)

            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func errorView(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var parseButton: some View {
        Button {
            Task {
                await parseFood()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: selectedImage != nil ? "eye.fill" : "sparkles")
                    Text(selectedImage != nil ? "识别食物" : "解析食物")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(canParse ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canParse || isLoading)
    }

    private var manualActionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    saveManualPreference()
                } label: {
                    Label("保存习惯", systemImage: "heart.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(canSaveManualEntry ? Color.pink : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!canSaveManualEntry)

                Button {
                    recordManualIntake()
                } label: {
                    Label("记录摄入", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(canSaveManualEntry ? Color.green : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!canSaveManualEntry)
            }

            if let manualPreferenceMessage {
                Label(manualPreferenceMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(manualPreferenceMessage.hasPrefix("已") ? .green : .red)
            }
        }
    }

    private var canParse: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImage != nil
    }

    private var computedManualCalories: Double? {
        guard let energyValue = parsedManualDouble(manualCalories), energyValue >= 0 else {
            return nil
        }

        let energyInKilocalories = manualEnergyUnit.toKilocalories(energyValue)

        switch manualEnergyInputMode {
        case .total:
            return energyInKilocalories
        case .per100:
            guard let quantity = parsedManualDouble(manualGrams), quantity >= 0 else {
                return nil
            }
            return energyInKilocalories * quantity / 100
        }
    }

    private var manualTotalEnergyText: String? {
        guard let calories = computedManualCalories else {
            return nil
        }

        let kilojoules = EnergyUnit.kilojoule.fromKilocalories(calories)
        return "总摄入约 \(calories.formattedCalories) kcal / \(kilojoules.formattedCalories) kJ"
    }

    private var canSaveManualEntry: Bool {
        let trimmedName = manualFoodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return computedManualCalories != nil
    }

    private var filteredPreferences: [FoodPreference] {
        if preferenceSearchText.isEmpty {
            return foodPreferences
        }
        return foodPreferences.filter { $0.keyword.localizedCaseInsensitiveContains(preferenceSearchText) }
    }

    private var savedPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已保存的食物习惯")
                    .font(.headline)
                Spacer()
                Text("\(foodPreferences.count)项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索食物习惯", text: $preferenceSearchText)
                    .textFieldStyle(.plain)
                if !preferenceSearchText.isEmpty {
                    Button {
                        preferenceSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // All preferences list
            if filteredPreferences.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: preferenceSearchText.isEmpty ? "heart.slash" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(preferenceSearchText.isEmpty ? "暂无保存的习惯" : "未找到匹配的食物")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredPreferences, id: \.id) { pref in
                        PreferenceRowWithActions(
                            preference: pref,
                            onTap: { editingPreference = EditingPreference(pref) },
                            onDelete: {
                                preferenceToDelete = pref
                                showingDeleteConfirmation = true
                            }
                        )

                        if pref.id != filteredPreferences.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text("点击编辑习惯 | 记录摄入在编辑页中操作")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func parseFood() async {
        // Dismiss keyboard first
        _ = await MainActor.run {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedImage != nil || !trimmedInput.isEmpty else {
            errorMessage = "请输入食物描述，或选择一张食物照片。"
            return
        }

        // Check API keys before parsing
        if selectedImage != nil && !isImageAPIConfigured {
            errorMessage = "图片识别需要设置 Qwen API 密钥。请在设置中配置。"
            showingAPIKeySetup = true
            return
        }

        if selectedImage == nil && !isTextAPIConfigured {
            errorMessage = "文字解析需要设置 DeepSeek 或 MiniMax API 密钥，或设置 Qwen API 密钥作为备用。"
            showingAPIKeySetup = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let nutritionList: [NutritionInfo]

            if let image = selectedImage {
                // Image parsing now supports multiple items via Qwen VL Plus
                nutritionList = try await aiService.parseFoodImageMultiple(
                    image,
                    additionalContext: trimmedInput.isEmpty ? nil : trimmedInput,
                    preferences: foodPreferences
                )
            } else {
                // Text parsing supports multiple items
                nutritionList = try await aiService.parseFoodInputMultiple(trimmedInput, preferences: foodPreferences)
            }

            if nutritionList.count == 1 {
                // Single item - show normal confirmation
                parsedNutrition = nutritionList.first
                confirmationRawInput = selectedImage == nil
                    ? trimmedInput
                    : (trimmedInput.isEmpty ? "图片识别" : trimmedInput)
                confirmationInitialCategory = .meal
                confirmationInitialMealType = nil
                showConfirmation = true
            } else if nutritionList.count > 1 {
                // Multiple items - show multiple confirmation
                parsedNutritionList = nutritionList
                showMultipleConfirmation = true
            } else {
                errorMessage = "未能识别任何食物"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func clearSelectedImage() {
        selectedImage = nil
        selectedPhoto = nil
        if errorMessage == "图片识别需要设置 Qwen API 密钥。请在设置中配置。" {
            errorMessage = nil
        }
    }

    private func manualNutritionInfo() -> NutritionInfo? {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let foodName = manualFoodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foodName.isEmpty else {
            errorMessage = "请输入食物名称"
            return nil
        }

        guard let _ = validatedManualValue(manualCalories, fieldName: manualEnergyInputTitle, isRequired: true),
              let grams = validatedManualValue(manualGrams, fieldName: "摄入量", isRequired: manualEnergyInputMode == .per100),
              let protein = validatedManualValue(manualProtein, fieldName: "蛋白质"),
              let carbohydrates = validatedManualValue(manualCarbohydrates, fieldName: "碳水化合物"),
              let fat = validatedManualValue(manualFat, fieldName: "脂肪") else {
            return nil
        }

        guard let calories = computedManualCalories else {
            errorMessage = manualEnergyInputMode == .per100
                ? "请输入有效的热量和摄入量"
                : "请输入有效热量"
            return nil
        }

        errorMessage = nil
        return NutritionInfo(
            foodName: foodName,
            brand: manualBrand,
            grams: grams,
            calories: calories,
            protein: protein,
            carbohydrates: carbohydrates,
            fat: fat,
            confidence: "manual",
            notes: "手动输入"
        )
    }

    private func recordManualIntake() {
        guard let nutrition = manualNutritionInfo() else { return }

        saveFoodEntry(
            with: nutrition,
            category: manualCategory,
            mealType: manualCategory == .meal ? manualMealType : nil,
            rawInputOverride: "手动记录: \(nutrition.foodName)"
        )
        resetManualEntry()
    }

    private func saveManualPreference() {
        guard let nutrition = manualNutritionInfo() else { return }

        let keyword = nutrition.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            manualPreferenceMessage = "请输入食物名称"
            return
        }

        if let existing = foodPreferences.first(where: { $0.matches(keyword: keyword, brand: nutrition.brand) }) {
            existing.keyword = keyword
            existing.updateBrand(nutrition.brand)
            existing.defaultDescription = "\(Int(nutrition.grams))\(manualQuantityUnit), \(Int(nutrition.calories))kcal"
            existing.defaultGrams = nutrition.grams
            existing.defaultCalories = nutrition.calories
            existing.defaultProtein = nutrition.protein
            existing.defaultCarbs = nutrition.carbohydrates
            existing.defaultFat = nutrition.fat
            manualPreferenceMessage = "已更新食物习惯"
        } else {
            let preference = FoodPreference(
                keyword: keyword,
                brand: nutrition.brand,
                defaultDescription: "\(Int(nutrition.grams))\(manualQuantityUnit), \(Int(nutrition.calories))kcal"
            )
            preference.defaultGrams = nutrition.grams
            preference.defaultCalories = nutrition.calories
            preference.defaultProtein = nutrition.protein
            preference.defaultCarbs = nutrition.carbohydrates
            preference.defaultFat = nutrition.fat
            modelContext.insert(preference)
            manualPreferenceMessage = "已保存习惯"
        }

        do {
            try modelContext.save()
        } catch {
            manualPreferenceMessage = error.localizedDescription
        }
    }

    private func validatedManualValue(_ text: String, fieldName: String, isRequired: Bool = false) -> Double? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
            if isRequired {
                errorMessage = "请输入\(fieldName)"
                return nil
            }
            return 0
        }

        guard let value = parsedManualDouble(trimmedText), value >= 0 else {
            errorMessage = "\(fieldName)请输入有效数字"
            return nil
        }

        return value
    }

    private func parsedManualDouble(_ text: String) -> Double? {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !normalizedText.isEmpty else { return nil }
        return Double(normalizedText)
    }

    private func resetManualEntry() {
        manualFoodName = ""
        manualBrand = ""
        manualGrams = ""
        manualCalories = ""
        manualEnergyUnit = .kilocalorie
        manualEnergyInputMode = .total
        manualProtein = ""
        manualCarbohydrates = ""
        manualFat = ""
        manualCategory = .meal
        manualMealType = FoodMealType.defaultType()
        errorMessage = nil
        manualPreferenceMessage = nil
    }

    private func saveFoodEntry(
        with nutrition: NutritionInfo,
        category: FoodEntryCategory = .meal,
        mealType: FoodMealType? = nil,
        rawInputOverride: String? = nil
    ) {
        let trimmedRawInputOverride = rawInputOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawInput: String
        if let trimmedRawInputOverride, !trimmedRawInputOverride.isEmpty {
            rawInput = trimmedRawInputOverride
        } else {
            rawInput = inputText.isEmpty ? "图片识别: \(nutrition.foodName)" : inputText
        }

        // Use target date if in backfill mode, otherwise use the nutrition's entry date
        let entryDate = targetDate ?? nutrition.entryDate

        let entry = FoodEntry(
            rawInput: rawInput,
            foodName: nutrition.foodName,
            brand: nutrition.brand,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbohydrates: nutrition.carbohydrates,
            fat: nutrition.fat,
            date: entryDate,
            category: category,
            mealType: category == .meal ? mealType : nil
        )
        modelContext.insert(entry)

        // Explicitly save to ensure Dashboard updates immediately
        try? modelContext.save()

        // Reset state
        inputText = ""
        selectedImage = nil
        selectedPhoto = nil
        parsedNutrition = nil
        showConfirmation = false
        confirmationRawInput = ""
        confirmationInitialCategory = .meal
        confirmationInitialMealType = nil

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        // Call completion handler and dismiss if in backfill mode
        onSaved?()
        if isBackfillMode {
            dismiss()
        }
    }

    private func saveMultipleFoodEntries(_ nutritionList: [NutritionInfo]) {
        for nutrition in nutritionList {
            // Use target date if in backfill mode
            let entryDate = targetDate ?? nutrition.entryDate

            let entry = FoodEntry(
                rawInput: inputText,
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

        inputText = ""
        selectedImage = nil
        selectedPhoto = nil
        parsedNutritionList = []
        showMultipleConfirmation = false

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        // Call completion handler and dismiss if in backfill mode
        onSaved?()
        if isBackfillMode {
            dismiss()
        }
    }

    private func recordPreferenceIntake(from preference: FoodPreference, nutrition: NutritionInfo) {
        let entryDate = effectiveDate
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
            category: .meal,
            mealType: FoodMealType.defaultType(for: entryDate)
        )

        preference.usageCount += 1
        modelContext.insert(entry)
        try? modelContext.save()

        onSaved?()
        if isBackfillMode {
            dismiss()
        }
    }
}

private struct EditingPreference: Identifiable {
    let id: UUID
    let preference: FoodPreference

    init(_ preference: FoodPreference) {
        self.id = preference.id
        self.preference = preference
    }
}

private enum PreferenceEditField: Hashable {
    case foodName
    case brand
    case grams
    case calories
    case protein
    case carbohydrates
    case fat
}

struct FoodPreferenceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let preference: FoodPreference
    let onRecordIntake: (NutritionInfo) -> Void

    @State private var foodName: String
    @State private var brand: String
    @State private var grams: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbohydrates: String
    @State private var fat: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: PreferenceEditField?

    init(preference: FoodPreference, onRecordIntake: @escaping (NutritionInfo) -> Void) {
        self.preference = preference
        self.onRecordIntake = onRecordIntake
        _foodName = State(initialValue: preference.keyword)
        _brand = State(initialValue: preference.brand ?? "")
        _grams = State(initialValue: Self.formatted(preference.defaultGrams))
        _calories = State(initialValue: Self.formatted(preference.defaultCalories, decimals: 0))
        _protein = State(initialValue: Self.formatted(preference.defaultProtein))
        _carbohydrates = State(initialValue: Self.formatted(preference.defaultCarbs))
        _fat = State(initialValue: Self.formatted(preference.defaultFat))
    }

    private var canRecordIntake: Bool {
        let hasName = !foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && parsedOptionalValue(calories) != nil && allEnteredNumbersValid
    }

    private var allEnteredNumbersValid: Bool {
        [grams, calories, protein, carbohydrates, fat].allSatisfy(isValidOptionalNumber)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("食物信息") {
                    TextField("食物名称", text: $foodName)
                        .focused($focusedField, equals: .foodName)

                    TextField("品牌（可选）", text: $brand)
                        .focused($focusedField, equals: .brand)

                    numericRow(title: "摄入量", text: $grams, unit: "g", field: .grams)
                }

                Section("营养成分") {
                    numericRow(title: "热量", text: $calories, unit: "kcal", field: .calories)
                    numericRow(title: "蛋白质", text: $protein, unit: "g", field: .protein)
                    numericRow(title: "碳水化合物", text: $carbohydrates, unit: "g", field: .carbohydrates)
                    numericRow(title: "脂肪", text: $fat, unit: "g", field: .fat)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        recordIntake()
                    } label: {
                        Label("记录摄入", systemImage: "plus.circle.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canRecordIntake)
                } footer: {
                    Text("右上角确认只保存习惯；记录摄入会把当前数值新增为一条食物记录。")
                }
            }
            .navigationTitle("编辑食物习惯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        confirmSave()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func numericRow(
        title: String,
        text: Binding<String>,
        unit: String,
        field: PreferenceEditField
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .frame(width: 90)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private func confirmSave() {
        focusedField = nil
        guard savePreferenceChanges(requireCalories: false) != nil else { return }
        dismiss()
    }

    private func recordIntake() {
        focusedField = nil
        guard let nutrition = savePreferenceChanges(requireCalories: true) else { return }
        onRecordIntake(nutrition)
        dismiss()
    }

    private func savePreferenceChanges(requireCalories: Bool) -> NutritionInfo? {
        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "请输入食物名称"
            return nil
        }

        if let invalidField = firstInvalidNumberField() {
            errorMessage = "\(invalidField)请输入有效数字"
            return nil
        }

        let gramsValue = parsedOptionalValue(grams)
        let caloriesValue = parsedOptionalValue(calories)
        let proteinValue = parsedOptionalValue(protein)
        let carbohydratesValue = parsedOptionalValue(carbohydrates)
        let fatValue = parsedOptionalValue(fat)

        if requireCalories && caloriesValue == nil {
            errorMessage = "请输入热量"
            return nil
        }

        preference.keyword = trimmedName
        preference.updateBrand(brand)
        preference.defaultGrams = gramsValue
        preference.defaultCalories = caloriesValue
        preference.defaultProtein = proteinValue
        preference.defaultCarbs = carbohydratesValue
        preference.defaultFat = fatValue
        preference.defaultDescription = defaultDescription(
            name: trimmedName,
            grams: gramsValue,
            calories: caloriesValue
        )

        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        errorMessage = nil
        return NutritionInfo(
            foodName: trimmedName,
            brand: brand,
            grams: gramsValue ?? 0,
            calories: caloriesValue ?? 0,
            protein: proteinValue ?? 0,
            carbohydrates: carbohydratesValue ?? 0,
            fat: fatValue ?? 0,
            confidence: "saved",
            notes: "从已保存习惯记录",
            daysAgo: 0
        )
    }

    private func firstInvalidNumberField() -> String? {
        let fields = [
            ("摄入量", grams),
            ("热量", calories),
            ("蛋白质", protein),
            ("碳水化合物", carbohydrates),
            ("脂肪", fat)
        ]

        return fields.first { !isValidOptionalNumber($0.1) }?.0
    }

    private func isValidOptionalNumber(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty else { return true }
        guard let value = Double(normalizedText) else { return false }
        return value >= 0
    }

    private func parsedOptionalValue(_ text: String) -> Double? {
        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty else { return nil }
        guard let value = Double(normalizedText), value >= 0 else { return nil }
        return value
    }

    private func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
    }

    private func defaultDescription(name: String, grams: Double?, calories: Double?) -> String {
        var parts: [String] = []
        if let grams {
            parts.append("\(Self.trimmedNumber(grams))g")
        }
        if let calories {
            parts.append("\(Self.trimmedNumber(calories))kcal")
        }
        return parts.isEmpty ? name : parts.joined(separator: ", ")
    }

    private static func formatted(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func trimmedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - Multiple Food Confirmation View

// Wrapper to make index identifiable for sheet(item:)
struct EditingItem: Identifiable {
    let id: Int
    let nutrition: NutritionInfo
}

struct MultipleFoodConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]

    let onConfirm: ([NutritionInfo]) -> Void

    @State private var editableList: [NutritionInfo]
    @State private var selectedItems: Set<Int>
    @State private var editingItem: EditingItem?
    @State private var saveAsPreferences: Set<Int> = []  // Track which items to save as preferences
    @State private var preferenceSaveMessage: String?

    init(nutritionList: [NutritionInfo], onConfirm: @escaping ([NutritionInfo]) -> Void) {
        self.onConfirm = onConfirm
        self._editableList = State(initialValue: nutritionList)
        self._selectedItems = State(initialValue: Set(0..<nutritionList.count))
    }

    private var totalCalories: Double {
        selectedItems.reduce(0) { sum, index in
            guard index < editableList.count else { return sum }
            return sum + editableList[index].calories
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Summary header
                VStack(spacing: 8) {
                    Text("识别到 \(editableList.count) 种食物")
                        .font(.headline)
                    Text("总热量: \(Int(totalCalories)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("勾选左侧记录摄入，点❤️选择要保存习惯的食物")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))

                // Food list
                List {
                    ForEach(Array(editableList.enumerated()), id: \.offset) { index, nutrition in
                        MultipleFoodRow(
                            nutrition: nutrition,
                            isSelected: selectedItems.contains(index),
                            isSavingAsPreference: saveAsPreferences.contains(index),
                            onToggle: {
                                if selectedItems.contains(index) {
                                    selectedItems.remove(index)
                                } else {
                                    selectedItems.insert(index)
                                }
                            },
                            onEdit: {
                                editingItem = EditingItem(id: index, nutrition: nutrition)
                            },
                            onToggleSavePreference: {
                                if saveAsPreferences.contains(index) {
                                    saveAsPreferences.remove(index)
                                } else {
                                    saveAsPreferences.insert(index)
                                }
                            }
                        )
                    }
                }
                .listStyle(.plain)

                multipleActionBar
            }
            .navigationTitle("识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $editingItem) { item in
                SingleFoodEditView(
                    nutrition: item.nutrition,
                    onSave: { updatedNutrition in
                        if item.id < editableList.count {
                            editableList[item.id] = updatedNutrition
                        }
                    }
                )
            }
        }
    }

    private var multipleActionBar: some View {
        VStack(spacing: 8) {
            if let preferenceSaveMessage {
                Label(preferenceSaveMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(preferenceSaveMessage.hasPrefix("已") ? .green : .red)
            }

            HStack(spacing: 12) {
                Button {
                    saveSelectedPreferences()
                } label: {
                    Label("保存习惯 (\(saveAsPreferences.count))", systemImage: "heart.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(saveAsPreferences.isEmpty ? Color.gray : Color.pink)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(saveAsPreferences.isEmpty)

                Button {
                    recordSelectedItems()
                } label: {
                    Label("记录摄入 (\(selectedItems.count))", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(selectedItems.isEmpty ? Color.gray : Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(selectedItems.isEmpty)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func saveSelectedPreferences() {
        let indexes = saveAsPreferences.sorted().filter { $0 < editableList.count }
        guard !indexes.isEmpty else { return }

        for index in indexes {
            savePreference(editableList[index])
        }

        preferenceSaveMessage = "已保存 \(indexes.count) 个食物习惯"
        saveAsPreferences.removeAll()
    }

    private func recordSelectedItems() {
        let confirmed = selectedItems.sorted().compactMap { index in
            index < editableList.count ? editableList[index] : nil
        }
        guard !confirmed.isEmpty else { return }

        onConfirm(confirmed)
        dismiss()
    }

    private func savePreference(_ nutrition: NutritionInfo) {
        let keyword = nutrition.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        if let existing = existingPreferences.first(where: { $0.matches(keyword: keyword, brand: nutrition.brand) }) {
            existing.keyword = keyword
            existing.updateBrand(nutrition.brand)
            existing.defaultDescription = "\(Int(nutrition.grams))g, \(Int(nutrition.calories))kcal"
            existing.defaultGrams = nutrition.grams
            existing.defaultCalories = nutrition.calories
            existing.defaultProtein = nutrition.protein
            existing.defaultCarbs = nutrition.carbohydrates
            existing.defaultFat = nutrition.fat
            existing.usageCount += 1
        } else {
            let preference = FoodPreference(
                keyword: keyword,
                brand: nutrition.brand,
                grams: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbs: nutrition.carbohydrates,
                fat: nutrition.fat
            )
            modelContext.insert(preference)
        }
        try? modelContext.save()
    }
}

struct MultipleFoodRow: View {
    let nutrition: NutritionInfo
    let isSelected: Bool
    let isSavingAsPreference: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onToggleSavePreference: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                onToggle()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .gray)
                    .font(.title2)
            }
            .buttonStyle(.plain)

            // Food info
            VStack(alignment: .leading, spacing: 4) {
                Text(nutrition.foodName)
                    .font(.headline)

                if let brand = nutrition.brand {
                    Text(brand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("\(Int(nutrition.grams))g")
                    Text("•")
                    Text("\(Int(nutrition.calories)) kcal")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("蛋白\(String(format: "%.1f", nutrition.protein))g")
                    Text("碳水\(String(format: "%.1f", nutrition.carbohydrates))g")
                    Text("脂肪\(String(format: "%.1f", nutrition.fat))g")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Save as preference button
            Button {
                onToggleSavePreference()
            } label: {
                Image(systemName: isSavingAsPreference ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isSavingAsPreference ? .pink : .gray)
            }
            .buttonStyle(.plain)

            // Edit button
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Single Food Edit View

struct SingleFoodEditView: View {
    @Environment(\.dismiss) private var dismiss

    let nutrition: NutritionInfo
    let onSave: (NutritionInfo) -> Void

    @State private var foodName: String = ""
    @State private var brand: String = ""
    @State private var grams: String = ""
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var carbohydrates: String = ""
    @State private var fat: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("食物信息") {
                    TextField("食物名称", text: $foodName)
                    TextField("品牌（可选）", text: $brand)
                    HStack {
                        Text("摄入量")
                        Spacer()
                        TextField("0", text: $grams)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("营养成分") {
                    HStack {
                        Text("热量")
                        Spacer()
                        TextField("0", text: $calories)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("kcal")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("蛋白质")
                        Spacer()
                        TextField("0", text: $protein)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("碳水化合物")
                        Spacer()
                        TextField("0", text: $carbohydrates)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("脂肪")
                        Spacer()
                        TextField("0", text: $fat)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let updated = NutritionInfo(
                            foodName: foodName,
                            brand: brand,
                            grams: Double(grams) ?? nutrition.grams,
                            calories: Double(calories) ?? nutrition.calories,
                            protein: Double(protein) ?? nutrition.protein,
                            carbohydrates: Double(carbohydrates) ?? nutrition.carbohydrates,
                            fat: Double(fat) ?? nutrition.fat,
                            confidence: "manual",
                            notes: "用户手动调整",
                            daysAgo: nutrition.daysAgo
                        )
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                foodName = nutrition.foodName
                brand = nutrition.brand ?? ""
                grams = String(format: "%.1f", nutrition.grams)
                calories = String(format: "%.0f", nutrition.calories)
                protein = String(format: "%.1f", nutrition.protein)
                carbohydrates = String(format: "%.1f", nutrition.carbohydrates)
                fat = String(format: "%.1f", nutrition.fat)
            }
        }
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Preference Row With Actions

struct PreferenceRowWithActions: View {
    let preference: FoodPreference
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onTap()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preference.keyword)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let brand = preference.brand {
                            Text(brand)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let grams = preference.defaultGrams {
                            HStack(spacing: 6) {
                                Text("\(Int(grams))g")
                                if let protein = preference.defaultProtein {
                                    Text("蛋白\(String(format: "%.0f", protein))g")
                                }
                                if let carbs = preference.defaultCarbs {
                                    Text("碳水\(String(format: "%.0f", carbs))g")
                                }
                                if let fat = preference.defaultFat {
                                    Text("脂肪\(String(format: "%.0f", fat))g")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        } else {
                            Text("暂无营养数据")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if let calories = preference.defaultCalories {
                        Text("\(Int(calories)) kcal")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash.circle")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview {
    FoodInputView()
        .modelContainer(for: [FoodEntry.self, FoodPreference.self], inMemory: true)
}
