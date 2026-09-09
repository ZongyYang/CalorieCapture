import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

private enum ManualEnergyInputMode: String, CaseIterable, Identifiable {
    case total
    case per100

    var id: Self { self }

    var title: String {
        switch self {
        case .total:
            return "总热量"
        case .per100:
            return "单位热量"
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
    var initialSearchText: String
    var initialImage: UIImage?
    var autoStartRecognition: Bool
    var onSaved: (() -> Void)?

    init(
        targetDate: Date? = nil,
        initialSearchText: String = "",
        initialImage: UIImage? = nil,
        autoStartRecognition: Bool = false,
        onSaved: (() -> Void)? = nil
    ) {
        self.targetDate = targetDate
        self.initialSearchText = initialSearchText
        self.initialImage = initialImage
        self.autoStartRecognition = autoStartRecognition
        self.onSaved = onSaved
        _inputText = State(initialValue: initialSearchText)
        _preferenceSearchText = State(initialValue: initialSearchText)
        _selectedImage = State(initialValue: initialImage)
    }

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
    @State private var confirmationEnergyUnit: EnergyUnit = .kilocalorie
    @State private var confirmationIsManualAutofill = false

    // Image picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingCamera = false
    @State private var showingCameraAlert = false
    @State private var showingPhotoLibrary = false

    // Food preferences
    @State private var preferenceSearchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var preferenceToDelete: FoodPreference?
    @State private var editingPreference: EditingPreference?
    @State private var editingSuggestedEntry: FoodEntry?
    @State private var showingAllPreferences = true
    @State private var isPreferenceSearchFocused = false
    @State private var pendingPreferenceDeletionIDs: Set<UUID> = []
    @State private var quickRecordMessage: String?

    // API Key setup
    @State private var showingSettings = false
    @State private var apiKeyCheckTrigger = false  // Used to refresh state
    @State private var showingAIAdvisor = false

    // Manual entry
    @State private var manualFoodName = ""
    @State private var manualBrand = ""
    @State private var manualGrams = ""
    @State private var manualCalories = ""
    @State private var manualEnergyUnit: EnergyUnit = .kilocalorie
    @State private var manualEnergyInputMode: ManualEnergyInputMode = .total
    @State private var manualNutritionInputMode: ManualEnergyInputMode = .total
    @State private var manualProtein = ""
    @State private var manualCarbohydrates = ""
    @State private var manualFat = ""
    @State private var manualCategory: FoodEntryCategory = .meal
    @State private var manualMealType: FoodMealType = .lunch
    @State private var manualPreferenceMessage: String?
    @State private var didAutoStartRecognition = false

    private let aiService = MiniMaxService()

    private var isAPIConfigured: Bool {
        isTextAPIConfigured || isImageAPIConfigured
    }

    private var isTextAPIConfigured: Bool {
        APIKeyManager.isTextParsingModelConfigured(APIKeyManager.textParsingModel)
    }

    private var isImageAPIConfigured: Bool {
        APIKeyManager.isDeepSeekConfigured
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

    private var knownBrands: [String] {
        BrandSuggestionCatalog.brands(
            entries: allEntries,
            preferences: foodPreferences
        )
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

                    if !isSavedPreferenceSearchMode {
                        // Backfill mode banner
                        if isBackfillMode {
                            backfillBanner
                        }

                        if selectedImage != nil {
                            imageInputSection
                        }
                    }

                    savedPreferencesSection

                    // Search mode must also show recognition errors. Previously this
                    // message was inside the manual-only branch and was hidden while
                    // the search field contained text.
                    if let error = errorMessage {
                        errorView(error)
                    }

                    if !isSavedPreferenceSearchMode {
                        manualEntrySection

                        manualActionButtons
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .background(AppSurfaceStyle.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeInOut(duration: 0.2), value: isSavedPreferenceSearchMode)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle(isBackfillMode ? "补录食物" : "记录")
            .toolbar {
                if !isBackfillMode {
                    ToolbarItem(placement: .topBarLeading) {
                        AIAdvisorToolbarButton(isPresented: $showingAIAdvisor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AppSettingsToolbarButton(isPresented: $showingSettings)
                }
            }
            .sheet(isPresented: $showConfirmation, onDismiss: finishFoodConfirmationFlow) {
                if let nutrition = parsedNutrition {
                    FoodConfirmationView(
                        rawInput: confirmationRawInput.isEmpty ? (inputText.isEmpty ? "图片识别" : inputText) : confirmationRawInput,
                        originalNutrition: nutrition,
                        initialCategory: confirmationInitialCategory,
                        initialMealType: confirmationInitialMealType,
                        initialEnergyUnit: confirmationEnergyUnit
                    ) { editedNutrition, category, mealType in
                        let shouldResetManualEntry = confirmationIsManualAutofill
                        let entry = saveFoodEntry(
                            with: editedNutrition,
                            category: category,
                            mealType: mealType,
                            energyUnit: confirmationEnergyUnit,
                            nutritionEstimatedByAI: confirmationIsManualAutofill && editedNutrition.confidence != "manual",
                            rawInputOverride: confirmationRawInput,
                            finishFlow: false
                        )
                        if shouldResetManualEntry {
                            resetManualEntry()
                        }
                        return entry
                    }
                }
            }
            .sheet(item: $editingPreference, onDismiss: {
                preferenceSearchText = ""
                isPreferenceSearchFocused = false
            }) { item in
                FoodPreferenceEditView(
                    preference: item.preference,
                    startsAIRecognition: item.startsAIRecognition,
                    onRecordIntake: { nutrition in
                        recordPreferenceIntake(
                            from: item.preference,
                            nutrition: nutrition,
                            finishFlow: false
                        )
                    }
                )
            }
            .sheet(item: $editingSuggestedEntry) { entry in
                FoodEntryEditView(entry: entry)
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView(image: $selectedImage)
            }
            .photosPicker(
                isPresented: $showingPhotoLibrary,
                selection: $selectedPhoto,
                matching: .images
            )
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
                        inputText = preferenceSearchText
                        selectedImage = image
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                AppSettingsView {
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
            .onChange(of: showingSettings) { _, isShowing in
                // Refresh when sheet is dismissed
                if !isShowing {
                    apiKeyCheckTrigger.toggle()
                }
            }
            .onAppear {
                manualMealType = FoodMealType.defaultType(for: effectiveDate)
                guard autoStartRecognition, !didAutoStartRecognition else { return }
                didAutoStartRecognition = true
                Task {
                    await parseFood()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusFoodRecordSearch)) { _ in
                isPreferenceSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFoodRecordCamera)) { _ in
                isPreferenceSearchFocused = false
                openCameraFromSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFoodRecordPhotoLibrary)) { _ in
                isPreferenceSearchFocused = false
                showingPhotoLibrary = true
            }
        }
        .onChange(of: isSavedPreferenceSearchMode) { wasSearching, isSearching in
            if wasSearching && !isSearching {
                commitPendingPreferenceDeletions()
            }
        }
        .onDisappear {
            commitPendingPreferenceDeletions()
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

            Text("DeepSeek 用于文字、图片食物识别和按需联网检索；Highspeed 文字模式需要 MiniMax。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                    apiStatusRow(
                        name: "DeepSeek API",
                        purpose: "文字、图片识别和按需联网检索",
                        isConfigured: APIKeyManager.isDeepSeekConfigured
                    )
                    apiStatusRow(
                        name: "MiniMax API",
                        purpose: "文字解析和 AI 顾问",
                        isConfigured: APIKeyManager.isMiniMaxConfigured
                    )
                    apiStatusRow(
                        name: "Qwen API",
                        purpose: "AI 顾问图片分析（可选）",
                        isConfigured: APIKeyManager.isQwenConfigured
                    )
            }
            .padding()
            .background(AppSurfaceStyle.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppSurfaceStyle.inputBorder, lineWidth: 1)
            }

            Button {
                showingSettings = true
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
            // Warning if DeepSeek API not configured
            // Use apiKeyCheckTrigger to force refresh
            let _ = apiKeyCheckTrigger
            if !isImageAPIConfigured {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("图片识别需要设置 DeepSeek API")
                        .font(.caption)
                    Spacer()
                    Button("设置") {
                        showingSettings = true
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
                .background(AppSurfaceStyle.formInputBackground)
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
                        .background(AppSurfaceStyle.formInputBackground)
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
                        .background(AppSurfaceStyle.formInputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(14)
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
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
            ? "补充说明：如份量、时间等"
            : "例如：一碗米饭、两个鸡蛋、昨天的晚餐"

        return TextField(placeholder, text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .padding()
            .background(AppSurfaceStyle.formInputBackground)
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
            return "热量"
        }
    }

    private func manualNutrientInputTitle(_ nutrient: String) -> String {
        nutrient
    }

    private var manualEnergyInputUnit: String {
        manualEnergyInputMode == .per100
            ? "\(manualEnergyUnit.symbol)/100\(manualQuantityUnit)"
            : manualEnergyUnit.symbol
    }

    private var manualNutrientInputUnit: String {
        manualNutritionInputMode == .per100
            ? "g/100\(manualQuantityUnit)"
            : "g"
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
                        .background(AppSurfaceStyle.formInputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.next)

                    BrandAutocompleteField(
                        text: $manualBrand,
                        brands: knownBrands,
                        inputBackground: AppSurfaceStyle.formInputBackground
                    )
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
                            Text(mode.title).tag(mode)
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
                        isRequired: manualEnergyInputMode == .per100 || manualNutritionInputMode == .per100
                    )

                    manualNumberField(
                        title: manualEnergyInputTitle,
                        placeholder: "0",
                        unit: manualEnergyInputUnit,
                        text: $manualCalories,
                        isRequired: true
                    )

                    if let manualTotalEnergyText {
                        Label(manualTotalEnergyText, systemImage: "equal.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let manualUnitEnergyText {
                        Label(manualUnitEnergyText, systemImage: "divide.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

                manualFormModule(title: "营养成分", systemImage: "chart.pie.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    manualPickerLabel("营养输入")

                    Picker("营养输入", selection: $manualNutritionInputMode) {
                        Text("总量").tag(ManualEnergyInputMode.total)
                        Text("单位营养").tag(ManualEnergyInputMode.per100)
                    }
                    .pickerStyle(.segmented)

                    Divider()

                    manualNumberField(
                        title: manualNutrientInputTitle("蛋白质"),
                        placeholder: "0",
                        unit: manualNutrientInputUnit,
                        text: $manualProtein
                    )
                    manualNumberField(
                        title: manualNutrientInputTitle("碳水化合物"),
                        placeholder: "0",
                        unit: manualNutrientInputUnit,
                        text: $manualCarbohydrates
                    )
                    manualNumberField(
                        title: manualNutrientInputTitle("脂肪"),
                        placeholder: "0",
                        unit: manualNutrientInputUnit,
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
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
    }

    private func manualPickerLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(AppSurfaceStyle.formSecondaryText)
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
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                .frame(width: 82, alignment: .leading)
        }
        .padding(12)
        .background(AppSurfaceStyle.formInputBackground)
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
                    handleManualRecordAction()
                } label: {
                    Label("记录摄入", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(canSaveManualEntry && !isLoading ? Color.green : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!canSaveManualEntry || isLoading)

                Button {
                    handleManualPreferenceAction()
                } label: {
                    Label("保存习惯", systemImage: "heart.fill")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(canSaveManualPreference && !isLoading ? Color.pink : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!canSaveManualPreference || isLoading)
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

    private var manualUnitEnergyText: String? {
        guard manualEnergyInputMode == .total,
              let quantity = parsedManualDouble(manualGrams),
              quantity > 0,
              let totalCalories = computedManualCalories else {
            return nil
        }

        let caloriesPer100 = totalCalories * 100 / quantity
        let displayedValue = manualEnergyUnit.fromKilocalories(caloriesPer100)
        return "单位热量约 \(displayedValue.formattedGrams) \(manualEnergyUnit.symbol)/100\(manualQuantityUnit)"
    }

    private var canSaveManualEntry: Bool {
        let trimmedName = manualFoodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if manualEnergyInputMode == .per100 || manualNutritionInputMode == .per100 {
            guard let quantity = parsedManualDouble(manualGrams), quantity > 0 else {
                return false
            }
        }
        return computedManualCalories != nil
    }

    private var canSaveManualPreference: Bool {
        canSaveManualEntry
    }

    private var filteredPreferences: [FoodPreference] {
        if preferenceSearchText.isEmpty {
            return foodPreferences
        }
        return foodPreferences.filter {
            $0.keyword.localizedCaseInsensitiveContains(preferenceSearchText)
                || ($0.brand?.localizedCaseInsensitiveContains(preferenceSearchText) ?? false)
        }
    }

    private var canRecognizeFromSearch: Bool {
        !preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImage != nil
    }

    private var isSavedPreferenceSearchMode: Bool {
        isPreferenceSearchFocused
            || !preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedSearchPreferences: [FoodPreference] {
        if preferenceSearchText.isEmpty {
            return showingAllPreferences ? foodPreferences : []
        }
        return filteredPreferences
    }

    private var savedPreferenceSuggestions: [FoodPreference] {
        let query = preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(filteredPreferences.prefix(3))
    }

    private var unsavedEntrySuggestions: [FoodEntry] {
        allEntries.unsavedSearchSuggestions(
            matching: preferenceSearchText,
            on: effectiveDate,
            excluding: foodPreferences
        )
    }

    private var savedPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ImagePasteTextField(
                        text: $preferenceSearchText,
                        placeholder: "搜索习惯或输入食物",
                        isEnabled: !isLoading,
                        returnKeyType: .search,
                        focusBinding: $isPreferenceSearchFocused,
                        onSubmit: { recognizeFromSearch() },
                        onPasteImage: { image in
                            inputText = preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            selectedPhoto = nil
                            selectedImage = image
                            errorMessage = nil
                        },
                        onPasteFailure: {
                            errorMessage = "剪贴板中没有可用图片，请重新拷贝照片后重试。"
                        }
                    )
                    if !preferenceSearchText.isEmpty {
                        Button {
                            preferenceSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 22)

                    TextRecognitionActionButton(
                        isProcessing: isLoading,
                        isEnabled: canRecognizeFromSearch,
                        action: recognizeFromSearch
                    )

                    Button {
                        openCameraFromSearch()
                    } label: {
                        Image(systemName: "camera.fill")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("拍照识别")

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
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

                if isSavedPreferenceSearchMode {
                    Button("取消") {
                        commitPendingPreferenceDeletions()
                        preferenceSearchText = ""
                        isPreferenceSearchFocused = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }

            if !savedPreferenceSuggestions.isEmpty {
                SavedPreferenceSuggestionPanel(
                    preferences: savedPreferenceSuggestions,
                    pendingDeletionIDs: pendingPreferenceDeletionIDs,
                    onSelect: { preference in
                        editingPreference = EditingPreference(preference)
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
            value: savedPreferenceSuggestions.map { $0.id }
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: unsavedEntrySuggestions.map { $0.id }
        )
    }

    private func isPreferenceRecordedForEffectiveDate(_ preference: FoodPreference) -> Bool {
        allEntries.contains { entry in
            Calendar.current.isDate(entry.createdAt, inSameDayAs: effectiveDate)
                && entry.rawInput.hasPrefix("已保存习惯:")
                && preference.matches(keyword: entry.foodName, brand: entry.brand)
        }
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
            errorMessage = "删除食物习惯失败：\(error.localizedDescription)"
        }
    }

    private func recognizeFromSearch() {
        guard !isLoading else { return }

        guard canRecognizeFromSearch else {
            errorMessage = nil
            isPreferenceSearchFocused = true
            return
        }

        inputText = preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await parseFood()
        }
    }

    private func openCameraFromSearch() {
        inputText = preferenceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCameraAvailable {
            showingCamera = true
        } else {
            showingCameraAlert = true
        }
    }

    private func parseFood() async {
        // Dismiss keyboard first
        _ = await MainActor.run {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDirectNutritionSummary = NutritionSummaryParser.canParse(trimmedInput)
        guard selectedImage != nil || !trimmedInput.isEmpty else {
            errorMessage = "请输入食物描述，或选择一张食物照片。"
            return
        }

        // Check API keys before parsing
        if selectedImage != nil && !isImageAPIConfigured {
            errorMessage = "图片识别需要设置 DeepSeek API 密钥。请在设置中配置。"
            showingSettings = true
            return
        }

        if selectedImage == nil && !isDirectNutritionSummary && !isTextAPIConfigured {
            let model = APIKeyManager.textParsingModel
            errorMessage = "当前选择 \(model.displayName)，请先配置 \(model.providerName) API 密钥。"
            showingSettings = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let nutritionList: [NutritionInfo]

            if let image = selectedImage {
                // Image parsing uses DeepSeek Vision and supports multiple items.
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
                confirmationEnergyUnit = .kilocalorie
                confirmationIsManualAutofill = false
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
        if errorMessage == "图片识别需要设置 DeepSeek API 密钥。请在设置中配置。" {
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

        let requiresQuantity = manualEnergyInputMode == .per100 || manualNutritionInputMode == .per100
        guard let _ = validatedManualValue(manualCalories, fieldName: manualEnergyInputTitle, isRequired: true),
              let grams = validatedManualValue(manualGrams, fieldName: "摄入量", isRequired: requiresQuantity),
              let proteinInput = validatedManualValue(manualProtein, fieldName: "蛋白质"),
              let carbohydratesInput = validatedManualValue(manualCarbohydrates, fieldName: "碳水化合物"),
              let fatInput = validatedManualValue(manualFat, fieldName: "脂肪") else {
            return nil
        }

        if requiresQuantity && grams <= 0 {
            errorMessage = "请输入大于0的摄入量"
            return nil
        }

        guard let calories = computedManualCalories else {
            errorMessage = manualEnergyInputMode == .per100
                ? "请输入有效的热量和摄入量"
                : "请输入有效热量"
            return nil
        }

        let nutrientScale = manualNutritionInputMode == .per100 ? grams / 100 : 1

        errorMessage = nil
        return NutritionInfo(
            foodName: foodName,
            brand: manualBrand,
            grams: grams,
            calories: calories,
            protein: proteinInput * nutrientScale,
            carbohydrates: carbohydratesInput * nutrientScale,
            fat: fatInput * nutrientScale,
            confidence: "manual",
            notes: "手动输入"
        )
    }

    private var shouldAutofillManualNutrition: Bool {
        let hasNoNutritionInput = [manualProtein, manualCarbohydrates, manualFat]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return hasNoNutritionInput && (parsedManualDouble(manualGrams) ?? 0) > 0
    }

    private func handleManualPreferenceAction() {
        if shouldAutofillManualNutrition {
            requestManualNutritionAutofill()
        } else {
            saveManualPreference()
        }
    }

    private func handleManualRecordAction() {
        if shouldAutofillManualNutrition {
            requestManualNutritionAutofill()
        } else {
            recordManualIntake()
        }
    }

    private func requestManualNutritionAutofill() {
        guard let nutrition = manualNutritionInfo() else { return }

        guard isTextAPIConfigured else {
            presentManualNutritionConfirmation(
                nutrition,
                notes: "未配置文字 AI，可在确认页手动填写营养成分。"
            )
            return
        }

        isLoading = true
        errorMessage = nil
        let quantityUnit = manualQuantityUnit
        let brandDescription = nutrition.brand.map { "，品牌：\($0)" } ?? ""
        let prompt = """
        请估算以下食物每100\(quantityUnit)的营养成分：\(nutrition.foodName)\(brandDescription)。
        已知本次摄入量为\(nutrition.grams.formattedGrams)\(quantityUnit)，总热量为\(nutrition.calories.formattedCalories)kcal。
        请按100\(quantityUnit)返回结果，grams字段返回100，重点给出蛋白质、碳水化合物和脂肪。
        """

        Task {
            do {
                let estimate = try await aiService.parseFoodInput(prompt, preferences: foodPreferences)
                let estimatedQuantity = estimate.grams > 0 ? estimate.grams : 100
                let unitScale = 100 / estimatedQuantity
                let proteinPer100 = estimate.protein * unitScale
                let carbsPer100 = estimate.carbohydrates * unitScale
                let fatPer100 = estimate.fat * unitScale
                let intakeScale = nutrition.grams / 100

                let enrichedNutrition = NutritionInfo(
                    foodName: nutrition.foodName,
                    brand: nutrition.brand,
                    grams: nutrition.grams,
                    calories: nutrition.calories,
                    protein: proteinPer100 * intakeScale,
                    carbohydrates: carbsPer100 * intakeScale,
                    fat: fatPer100 * intakeScale,
                    confidence: "medium",
                    notes: "AI估算单位营养：蛋白质\(proteinPer100.formattedGrams)g、碳水\(carbsPer100.formattedGrams)g、脂肪\(fatPer100.formattedGrams)g / 100\(quantityUnit)"
                )
                isLoading = false
                presentManualNutritionConfirmation(enrichedNutrition)
            } catch {
                isLoading = false
                presentManualNutritionConfirmation(
                    nutrition,
                    notes: "AI营养补全失败，可在确认页手动填写：\(error.localizedDescription)"
                )
            }
        }
    }

    private func presentManualNutritionConfirmation(_ nutrition: NutritionInfo, notes: String? = nil) {
        let confirmedNutrition: NutritionInfo
        if let notes {
            confirmedNutrition = NutritionInfo(
                foodName: nutrition.foodName,
                brand: nutrition.brand,
                grams: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbohydrates: nutrition.carbohydrates,
                fat: nutrition.fat,
                confidence: nutrition.confidence,
                notes: notes,
                daysAgo: nutrition.daysAgo
            )
        } else {
            confirmedNutrition = nutrition
        }

        parsedNutrition = confirmedNutrition
        confirmationRawInput = "手动记录: \(confirmedNutrition.foodName)"
        confirmationInitialCategory = manualCategory
        confirmationInitialMealType = manualCategory == .meal ? manualMealType : nil
        confirmationEnergyUnit = manualEnergyUnit
        confirmationIsManualAutofill = true
        showConfirmation = true
    }

    private func recordManualIntake() {
        guard let nutrition = manualNutritionInfo() else { return }

        saveFoodEntry(
            with: nutrition,
            category: manualCategory,
            mealType: manualCategory == .meal ? manualMealType : nil,
            energyUnit: manualEnergyUnit,
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
        let displayedTotalEnergy = manualEnergyUnit.fromKilocalories(nutrition.calories)
        let quantityDescription = nutrition.grams > 0
            ? "\(Int(nutrition.grams))\(manualQuantityUnit), "
            : ""
        let preferenceDescription = "\(quantityDescription)\(displayedTotalEnergy.formattedCalories)\(manualEnergyUnit.symbol)"
        let preferenceProtein = manualProtein.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : nutrition.protein
        let preferenceCarbs = manualCarbohydrates.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : nutrition.carbohydrates
        let preferenceFat = manualFat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : nutrition.fat

        if let existing = foodPreferences.first(where: { $0.matches(keyword: keyword, brand: nutrition.brand) }) {
            existing.keyword = keyword
            existing.updateBrand(nutrition.brand)
            existing.category = manualCategory
            existing.energyUnit = manualEnergyUnit
            existing.defaultDescription = preferenceDescription
            existing.updateNutritionReference(
                quantity: nutrition.grams,
                calories: nutrition.calories,
                protein: preferenceProtein,
                carbs: preferenceCarbs,
                fat: preferenceFat
            )
            applyManualPer100Values(to: existing)
            manualPreferenceMessage = "已更新食物习惯"
        } else {
            let preference = FoodPreference(
                keyword: keyword,
                brand: nutrition.brand,
                defaultDescription: preferenceDescription,
                category: manualCategory,
                energyUnit: manualEnergyUnit
            )
            preference.updateNutritionReference(
                quantity: nutrition.grams,
                calories: nutrition.calories,
                protein: preferenceProtein,
                carbs: preferenceCarbs,
                fat: preferenceFat
            )
            applyManualPer100Values(to: preference)
            modelContext.insert(preference)
            manualPreferenceMessage = "已保存习惯"
        }

        do {
            try modelContext.save()
        } catch {
            manualPreferenceMessage = error.localizedDescription
        }
    }

    private func applyManualPer100Values(to preference: FoodPreference) {
        if manualEnergyInputMode == .per100,
           let displayedEnergy = parsedManualDouble(manualCalories) {
            preference.caloriesPer100 = manualEnergyUnit.toKilocalories(displayedEnergy)
        }

        if manualNutritionInputMode == .per100 {
            preference.proteinPer100 = parsedManualDouble(manualProtein)
            preference.carbsPer100 = parsedManualDouble(manualCarbohydrates)
            preference.fatPer100 = parsedManualDouble(manualFat)
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
        manualNutritionInputMode = .total
        manualProtein = ""
        manualCarbohydrates = ""
        manualFat = ""
        manualCategory = .meal
        manualMealType = FoodMealType.defaultType()
        errorMessage = nil
        manualPreferenceMessage = nil
    }

    @discardableResult
    private func saveFoodEntry(
        with nutrition: NutritionInfo,
        category: FoodEntryCategory = .meal,
        mealType: FoodMealType? = nil,
        energyUnit: EnergyUnit = .kilocalorie,
        nutritionEstimatedByAI: Bool = false,
        rawInputOverride: String? = nil,
        finishFlow: Bool = true
    ) -> FoodEntry {
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
            mealType: category == .meal ? mealType : nil,
            energyUnit: energyUnit,
            nutritionEstimatedByAI: nutritionEstimatedByAI
        )
        modelContext.insert(entry)

        // Explicitly save to ensure Dashboard updates immediately
        try? modelContext.save()

        if finishFlow {
            // Reset state
            inputText = ""
            selectedImage = nil
            selectedPhoto = nil
            parsedNutrition = nil
            showConfirmation = false
            confirmationRawInput = ""
            confirmationInitialCategory = .meal
            confirmationInitialMealType = nil
            confirmationEnergyUnit = .kilocalorie
            confirmationIsManualAutofill = false

            // Dismiss keyboard
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

            // Call completion handler and dismiss if in backfill mode
            onSaved?()
            if isBackfillMode {
                dismiss()
            }
        }

        return entry
    }

    private func finishFoodConfirmationFlow() {
        preferenceSearchText = ""
        inputText = ""
        selectedImage = nil
        selectedPhoto = nil
        parsedNutrition = nil
        confirmationRawInput = ""
        confirmationInitialCategory = .meal
        confirmationInitialMealType = nil
        confirmationEnergyUnit = .kilocalorie
        confirmationIsManualAutofill = false
        isPreferenceSearchFocused = false
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

    @discardableResult
    private func recordPreferenceIntake(
        from preference: FoodPreference,
        nutrition: NutritionInfo,
        finishFlow: Bool = true
    ) -> FoodEntry {
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
            category: preference.category,
            mealType: preference.category == .meal ? FoodMealType.defaultType(for: entryDate) : nil,
            energyUnit: preference.energyUnit
        )

        preference.usageCount += 1
        modelContext.insert(entry)
        try? modelContext.save()

        if finishFlow {
            preferenceSearchText = ""
            isPreferenceSearchFocused = false
            onSaved?()
            if isBackfillMode {
                dismiss()
            }
        }
        return entry
    }

    private func quickRecordPreference(_ preference: FoodPreference) {
        guard let nutrition = quickRecordNutrition(from: preference) else {
            errorMessage = "\(preference.keyword)缺少可记录的热量数据，请先编辑食物习惯。"
            return
        }

        recordPreferenceIntake(from: preference, nutrition: nutrition)
        showQuickRecordMessage("已记录 \(preference.keyword)")
    }

    private func saveSuggestedEntryAsPreference(_ entry: FoodEntry) {
        guard !foodPreferences.contains(where: {
            $0.matches(keyword: entry.foodName, brand: entry.brand)
        }) else { return }

        modelContext.insert(FoodPreference(entry: entry))
        do {
            try modelContext.save()
            showQuickRecordMessage("已保存习惯 \(entry.foodName)")
        } catch {
            errorMessage = "保存食物习惯失败：\(error.localizedDescription)"
        }
    }

    private func quickRecordSuggestedEntry(_ source: FoodEntry) {
        let entryDate = effectiveDate
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
            preferenceSearchText = ""
            isPreferenceSearchFocused = false
            showQuickRecordMessage("已记录 \(source.foodName)")
            onSaved?()
            if isBackfillMode {
                dismiss()
            }
        } catch {
            errorMessage = "记录摄入失败：\(error.localizedDescription)"
        }
    }

    private func showQuickRecordMessage(_ message: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            quickRecordMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard quickRecordMessage == message else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                quickRecordMessage = nil
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
}

struct SavedPreferenceSuggestionPanel: View {
    let preferences: [FoodPreference]
    let pendingDeletionIDs: Set<UUID>
    let onSelect: (FoodPreference) -> Void
    let onToggleSaved: (FoodPreference) -> Void
    let onRecord: (FoodPreference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已保存习惯")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(Array(preferences.enumerated()), id: \.element.id) { index, preference in
                HStack(spacing: 12) {
                    Button {
                        onSelect(preference)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preference.keyword)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if let brand = preference.brand, !brand.isEmpty {
                                    Text(brand)
                                }
                                if !preference.defaultDescription.isEmpty {
                                    Text(preference.defaultDescription)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onToggleSaved(preference)
                    } label: {
                        Image(
                            systemName: pendingDeletionIDs.contains(preference.id)
                                ? "heart"
                                : "heart.fill"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            pendingDeletionIDs.contains(preference.id) ? Color.gray : Color.pink
                        )
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        pendingDeletionIDs.contains(preference.id)
                            ? "恢复保存 \(preference.keyword)"
                            : "删除习惯 \(preference.keyword)"
                    )

                    Button {
                        onRecord(preference)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录 \(preference.keyword)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if index < preferences.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
    }
}

struct TodayEntrySuggestionPanel: View {
    let entries: [FoodEntry]
    let onSelect: (FoodEntry) -> Void
    let onSavePreference: (FoodEntry) -> Void
    let onRecord: (FoodEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("当日未保存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 12) {
                    Button {
                        onSelect(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.foodName)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if let brand = entry.brand, !brand.isEmpty {
                                    Text(brand)
                                }
                                Text("\(entry.grams.formattedGrams)\(entry.category.quantityUnitSymbol)")
                                Text("\(entry.displayedEnergy.formattedCalories) \(entry.energyUnit.symbol)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSavePreference(entry)
                    } label: {
                        Image(systemName: "heart")
                            .font(.title3)
                            .foregroundStyle(.gray)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("保存习惯 \(entry.foodName)")

                    Button {
                        onRecord(entry)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("再次记录 \(entry.foodName)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if index < entries.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
    }
}

struct FoodPreferencesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodPreference.usageCount, order: .reverse) private var foodPreferences: [FoodPreference]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var allEntries: [FoodEntry]

    @State private var searchText = ""
    @State private var editingPreference: EditingPreference?
    @State private var preferenceToDelete: FoodPreference?
    @State private var showingDeleteConfirmation = false
    @State private var quickRecordMessage: String?
    @State private var sessionRecordedPreferenceIDs: Set<UUID> = []

    private var filteredPreferences: [FoodPreference] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return foodPreferences }

        return foodPreferences.filter {
            $0.keyword.localizedCaseInsensitiveContains(query)
                || ($0.brand?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("搜索保存的习惯", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foodSearchBarSurface()

                if filteredPreferences.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "heart")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "还没有保存的食物习惯" : "未找到匹配的食物习惯")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredPreferences, id: \.id) { preference in
                            PreferenceRowWithActions(
                                preference: preference,
                                isRecordedForDate: sessionRecordedPreferenceIDs.contains(preference.id),
                                onTap: {
                                    editingPreference = EditingPreference(preference)
                                },
                                onRecognize: {
                                    editingPreference = EditingPreference(
                                        preference,
                                        startsAIRecognition: true
                                    )
                                },
                                onRecord: {
                                    quickRecordPreference(preference)
                                },
                                onDelete: {
                                    preferenceToDelete = preference
                                    showingDeleteConfirmation = true
                                }
                            )
                        }
                    }
                }

                if let quickRecordMessage {
                    Label(quickRecordMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(AppSurfaceStyle.pageBackground)
        .navigationTitle("保存的习惯")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingPreference) { item in
            FoodPreferenceEditView(
                preference: item.preference,
                startsAIRecognition: item.startsAIRecognition,
                onRecordIntake: { nutrition in
                    recordPreferenceIntake(from: item.preference, nutrition: nutrition)
                },
                onIntakeStateChange: { isRecorded in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isRecorded {
                            _ = sessionRecordedPreferenceIDs.insert(item.preference.id)
                        } else {
                            sessionRecordedPreferenceIDs.remove(item.preference.id)
                        }
                    }
                }
            )
        }
        .alert("删除习惯", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let preferenceToDelete {
                    modelContext.delete(preferenceToDelete)
                    try? modelContext.save()
                }
            }
        } message: {
            Text("确定要删除这个食物习惯吗？")
        }
        .onDisappear {
            sessionRecordedPreferenceIDs.removeAll()
        }
    }

    @discardableResult
    private func recordPreferenceIntake(from preference: FoodPreference, nutrition: NutritionInfo) -> FoodEntry {
        let entry = FoodEntry(
            rawInput: "已保存习惯: \(preference.keyword)",
            foodName: nutrition.foodName,
            brand: nutrition.brand,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbohydrates: nutrition.carbohydrates,
            fat: nutrition.fat,
            date: Date(),
            category: preference.category,
            mealType: preference.category == .meal ? FoodMealType.defaultType(for: Date()) : nil,
            energyUnit: preference.energyUnit
        )

        preference.usageCount += 1
        modelContext.insert(entry)
        try? modelContext.save()
        return entry
    }

    private func quickRecordPreference(_ preference: FoodPreference) {
        guard let nutrition = quickRecordNutrition(from: preference) else {
            quickRecordMessage = "\(preference.keyword)缺少可记录的热量数据，请先编辑食物习惯。"
            return
        }

        recordPreferenceIntake(from: preference, nutrition: nutrition)
        let message = "已记录 \(preference.keyword)"
        withAnimation(.easeInOut(duration: 0.18)) {
            sessionRecordedPreferenceIDs.insert(preference.id)
            quickRecordMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard quickRecordMessage == message else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                quickRecordMessage = nil
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

        guard let caloriesPer100 = preference.resolvedCaloriesPer100 else { return nil }
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
}

private struct EditingPreference: Identifiable {
    let id: UUID
    let preference: FoodPreference
    let startsAIRecognition: Bool

    init(_ preference: FoodPreference, startsAIRecognition: Bool = false) {
        self.id = preference.id
        self.preference = preference
        self.startsAIRecognition = startsAIRecognition
    }
}

private enum PreferenceEditField: Hashable {
    case foodName
    case brand
    case intakeQuantity
    case totalQuantity
    case totalCalories
    case totalProtein
    case totalCarbohydrates
    case totalFat
    case caloriesPer100
    case proteinPer100
    case carbohydratesPer100
    case fatPer100
}

struct FoodPreferenceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingPreferences: [FoodPreference]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var existingEntries: [FoodEntry]

    let preference: FoodPreference
    let startsAIRecognition: Bool
    let onRecordIntake: (NutritionInfo) -> FoodEntry
    let onIntakeStateChange: (Bool) -> Void

    @State private var foodName: String
    @State private var brand: String
    @State private var intakeQuantity: String
    @State private var totalQuantity: String
    @State private var totalCalories: String
    @State private var totalProtein: String
    @State private var totalCarbohydrates: String
    @State private var totalFat: String
    @State private var caloriesPer100: String
    @State private var proteinPer100: String
    @State private var carbohydratesPer100: String
    @State private var fatPer100: String
    @State private var category: FoodEntryCategory
    @State private var energyUnit: EnergyUnit
    @State private var errorMessage: String?
    @State private var aiStatusMessage: String?
    @State private var isProcessingAI = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingCamera = false
    @State private var showingCameraAlert = false
    @State private var showingSettings = false
    @State private var hasStartedInitialRecognition = false
    @State private var showingDeleteConfirmation = false
    @State private var aiInputText = ""
    @State private var isPreferenceSaved = true
    @FocusState private var focusedField: PreferenceEditField?

    private let aiService = MiniMaxService()

    private var knownBrands: [String] {
        BrandSuggestionCatalog.brands(
            entries: existingEntries,
            preferences: existingPreferences
        )
    }

    init(
        preference: FoodPreference,
        startsAIRecognition: Bool = false,
        onRecordIntake: @escaping (NutritionInfo) -> FoodEntry,
        onIntakeStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.preference = preference
        self.startsAIRecognition = startsAIRecognition
        self.onRecordIntake = onRecordIntake
        self.onIntakeStateChange = onIntakeStateChange
        _foodName = State(initialValue: preference.keyword)
        _brand = State(initialValue: preference.brand ?? "")
        _intakeQuantity = State(initialValue: Self.initialIntakeQuantity(for: preference))
        _totalQuantity = State(initialValue: Self.formatted(preference.defaultGrams))
        _totalCalories = State(
            initialValue: Self.formatted(
                preference.defaultCalories.map { preference.energyUnit.fromKilocalories($0) },
                decimals: 1
            )
        )
        _totalProtein = State(initialValue: Self.formatted(preference.defaultProtein))
        _totalCarbohydrates = State(initialValue: Self.formatted(preference.defaultCarbs))
        _totalFat = State(initialValue: Self.formatted(preference.defaultFat))
        _caloriesPer100 = State(
            initialValue: Self.formatted(
                preference.resolvedCaloriesPer100.map { preference.energyUnit.fromKilocalories($0) },
                decimals: 1
            )
        )
        _proteinPer100 = State(initialValue: Self.formatted(preference.resolvedProteinPer100))
        _carbohydratesPer100 = State(initialValue: Self.formatted(preference.resolvedCarbsPer100))
        _fatPer100 = State(initialValue: Self.formatted(preference.resolvedFatPer100))
        _category = State(initialValue: preference.category)
        _energyUnit = State(initialValue: preference.energyUnit)
    }

    private var hasTotalReference: Bool {
        parsedOptionalValue(totalCalories) != nil
    }

    private var hasPer100Reference: Bool {
        parsedOptionalValue(caloriesPer100) != nil
    }

    private var canSavePreference: Bool {
        let hasName = !foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && (hasTotalReference || hasPer100Reference) && allEnteredNumbersValid
    }

    private var canRecordIntake: Bool {
        guard canSavePreference else { return false }
        if hasPer100Reference {
            return (parsedOptionalValue(intakeQuantity) ?? 0) > 0
        }
        return hasTotalReference
    }

    private var allEnteredNumbersValid: Bool {
        [
            intakeQuantity,
            totalQuantity,
            totalCalories,
            totalProtein,
            totalCarbohydrates,
            totalFat,
            caloriesPer100,
            proteinPer100,
            carbohydratesPer100,
            fatPer100
        ].allSatisfy(isValidOptionalNumber)
    }

    private var calculatedTotalEnergy: Double? {
        if let unitEnergy = parsedOptionalValue(caloriesPer100),
           let quantity = parsedOptionalValue(intakeQuantity),
           quantity > 0 {
            return unitEnergy * quantity / 100
        }
        return parsedOptionalValue(totalCalories)
    }

    private var unitEnergyLabel: String {
        "\(energyUnit.symbol)/100\(category.quantityUnitSymbol)"
    }

    private var unitNutrientLabel: String {
        "g/100\(category.quantityUnitSymbol)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AIRecognitionActionBar(
                        isProcessing: isProcessingAI,
                        onRecognize: { recognizeWithAI(image: selectedImage) },
                        onCamera: { openCamera() },
                        onPasteImage: { image in
                            selectedImage = image
                            errorMessage = nil
                            aiStatusMessage = "已粘贴图片，可补充说明后点 AI 识别。"
                        },
                        onPasteFailure: {
                            errorMessage = "剪贴板中没有可用图片，请重新拷贝照片后重试。"
                        },
                        inputText: $aiInputText,
                        selectedPhoto: $selectedPhoto
                    )

                    if let aiStatusMessage {
                        Label(aiStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    preferenceEditModule(title: "食物信息", systemImage: "fork.knife") {
                        VStack(spacing: 10) {
                            TextField("食物名称", text: $foodName)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .foodName)
                                .padding(12)
                                .background(preferenceEditInputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            BrandAutocompleteField(
                                text: $brand,
                                brands: knownBrands,
                                inputBackground: preferenceEditInputBackground
                            )
                        }
                    }

                    preferenceEditModule(title: "分类", systemImage: "tag.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            preferenceEditLabel("类型")

                            Picker("类型", selection: $category) {
                                ForEach(FoodEntryCategory.allCases) { category in
                                    Label(category.rawValue, systemImage: category.systemImage)
                                        .tag(category)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    preferenceEditModule(title: "热量设置", systemImage: "flame.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            preferenceEditLabel("热量单位")

                            Picker("热量单位", selection: $energyUnit) {
                                ForEach(EnergyUnit.allCases) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    preferenceEditModule(title: "摄入信息", systemImage: "scalemass.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            if hasPer100Reference {
                                numericRow(
                                    title: "本次摄入量",
                                    text: $intakeQuantity,
                                    unit: category.quantityUnitSymbol,
                                    field: .intakeQuantity
                                )
                            } else if hasTotalReference {
                                Label("未设置单位热量，将按保存的总量记录", systemImage: "sum")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("请先填写下方任意一套热量数据", systemImage: "exclamationmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let calculatedTotalEnergy {
                                HStack {
                                    Text("预计总热量")
                                    Spacer()
                                    Text("\(Self.trimmedNumber(calculatedTotalEnergy)) \(energyUnit.symbol)")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                                .font(.subheadline)
                            }

                            Text(hasPer100Reference
                                ? "优先使用单位数据，并按本次摄入量计算。"
                                : "没有单位数据时，直接使用保存的总量数据。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    preferenceEditModule(title: "总量数据", systemImage: "sum") {
                        VStack(alignment: .leading, spacing: 10) {
                            numericRow(
                                title: "摄入量",
                                text: $totalQuantity,
                                unit: category.quantityUnitSymbol,
                                field: .totalQuantity
                            )
                            numericRow(title: "总热量", text: $totalCalories, unit: energyUnit.symbol, field: .totalCalories)
                            numericRow(title: "总蛋白质", text: $totalProtein, unit: "g", field: .totalProtein)
                            numericRow(title: "总碳水", text: $totalCarbohydrates, unit: "g", field: .totalCarbohydrates)
                            numericRow(title: "总脂肪", text: $totalFat, unit: "g", field: .totalFat)

                            Text("无法确定单位热量时，可以只保留这套总量数据。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    preferenceEditModule(title: "单位数据", systemImage: "chart.bar.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            numericRow(title: "热量", text: $caloriesPer100, unit: unitEnergyLabel, field: .caloriesPer100)
                            numericRow(title: "蛋白质", text: $proteinPer100, unit: unitNutrientLabel, field: .proteinPer100)
                            numericRow(title: "碳水化合物", text: $carbohydratesPer100, unit: unitNutrientLabel, field: .carbohydratesPer100)
                            numericRow(title: "脂肪", text: $fatPer100, unit: unitNutrientLabel, field: .fatPer100)

                            Text("填写后，后续记录将优先按这套数据和摄入量计算。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    HStack(spacing: 12) {
                        Button {
                            recordIntake()
                        } label: {
                            Label("记录摄入", systemImage: "plus.circle.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.secondary)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(!canRecordIntake)

                        Button {
                            if isPreferenceSaved {
                                showingDeleteConfirmation = true
                            } else {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isPreferenceSaved = true
                                }
                            }
                        } label: {
                            Label(
                                isPreferenceSaved ? "删除习惯" : "添加习惯",
                                systemImage: isPreferenceSaved ? "heart.fill" : "heart"
                            )
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isPreferenceSaved ? .white : .pink)
                        .background(isPreferenceSaved ? Color.pink : AppSurfaceStyle.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.pink.opacity(isPreferenceSaved ? 0 : 0.35), lineWidth: 1)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .padding()
            }
            .background(AppSurfaceStyle.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑习惯")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSettings) {
                AppSettingsView()
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: recognizeCapturedImage) {
                CameraView(image: $selectedImage)
            }
            .alert("相机不可用", isPresented: $showingCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请在真机上使用相机功能，或从相册选择图片。")
            }
            .alert("删除食物习惯", isPresented: $showingDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deletePreference()
                }
            } message: {
                Text("确定删除这个食物习惯吗？历史摄入记录不会受到影响。")
            }
            .onChange(of: energyUnit) { oldUnit, newUnit in
                convertEnergyUnit(from: oldUnit, to: newUnit)
            }
            .onChange(of: selectedPhoto) { _, newPhoto in
                guard let newPhoto else { return }
                Task {
                    guard let data = try? await newPhoto.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        await MainActor.run {
                            errorMessage = "无法读取所选图片，请重试。"
                            selectedPhoto = nil
                        }
                        return
                    }
                    await MainActor.run {
                        selectedPhoto = nil
                        recognizeWithAI(image: image)
                    }
                }
            }
            .onAppear {
                guard startsAIRecognition, !hasStartedInitialRecognition else { return }
                hasStartedInitialRecognition = true
                DispatchQueue.main.async {
                    recognizeWithAI()
                }
            }
            .onDisappear {
                commitPreferenceSavedState()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        confirmSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSavePreference)
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

    private func preferenceEditModule<Content: View>(
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
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private func preferenceEditLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(AppSurfaceStyle.formSecondaryText)
    }

    private var preferenceEditInputBackground: Color {
        AppSurfaceStyle.formInputBackground
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
                .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                .frame(width: 92, alignment: .leading)
        }
        .padding(12)
        .background(preferenceEditInputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @MainActor
    private func recognizeWithAI(image: UIImage? = nil) {
        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "请先填写食物名称"
            aiStatusMessage = nil
            return
        }

        if image != nil, !APIKeyManager.isDeepSeekConfigured {
            errorMessage = "图片识别需要设置 DeepSeek API 密钥。"
            aiStatusMessage = nil
            showingSettings = true
            return
        }

        let totalQuantityValue = parsedOptionalValue(totalQuantity) ?? 0
        let intakeQuantityValue = parsedOptionalValue(intakeQuantity) ?? 0
        let currentQuantity = totalQuantityValue > 0 ? totalQuantityValue : intakeQuantityValue
        let displayedTotalEnergy = parsedOptionalValue(totalCalories) ?? 0
        let displayedUnitEnergy = parsedOptionalValue(caloriesPer100) ?? 0
        let totalEnergyInKilocalories = energyUnit.toKilocalories(displayedTotalEnergy)
        let unitEnergyInKilocalories = energyUnit.toKilocalories(displayedUnitEnergy)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityDescription = currentQuantity > 0
            ? "参考摄入量：\(Self.trimmedNumber(currentQuantity))\(category.quantityUnitSymbol)"
            : "参考摄入量：未知，请估算常见单次摄入量"
        let totalEnergyDescription = totalEnergyInKilocalories > 0
            ? "已知总热量：\(Self.trimmedNumber(totalEnergyInKilocalories))kcal"
            : "总热量：未知"
        let unitEnergyDescription = unitEnergyInKilocalories > 0
            ? "已知单位热量：\(Self.trimmedNumber(unitEnergyInKilocalories))kcal/100\(category.quantityUnitSymbol)"
            : "单位热量：未知"
        let prompt = """
        请识别并补全这项食物习惯：
        食物名称：\(trimmedName)
        品牌：\(trimmedBrand.isEmpty ? "未知" : trimmedBrand)
        类型：\(category.rawValue)
        \(quantityDescription)
        \(totalEnergyDescription)
        \(unitEnergyDescription)
        补充说明：\(aiInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无" : aiInputText.trimmingCharacters(in: .whitespacesAndNewlines))

        用户提供的数据优先于估算。请返回一个常见单次摄入记录：grams为该次摄入量，calories、protein、carbohydrates和fat均为该次摄入总量。
        """

        focusedField = nil
        errorMessage = nil
        aiStatusMessage = nil
        isProcessingAI = true

        Task {
            defer { isProcessingAI = false }

            do {
                let nutritionPreferences = existingPreferences.filter {
                    $0.id != preference.id
                        && (($0.resolvedProteinPer100 ?? 0)
                            + ($0.resolvedCarbsPer100 ?? 0)
                            + ($0.resolvedFatPer100 ?? 0) > 0)
                }
                let estimate: NutritionInfo
                if let image {
                    estimate = try await aiService.parseFoodImage(
                        image,
                        additionalContext: prompt,
                        preferences: nutritionPreferences
                    )
                } else {
                    estimate = try await aiService.parseFoodInput(
                        prompt,
                        preferences: nutritionPreferences
                    )
                }
                applyAIEstimate(
                    estimate,
                    currentQuantity: currentQuantity,
                    knownTotalCalories: totalEnergyInKilocalories
                )
            } catch {
                if let aiError = error as? AIServiceError,
                   case .apiKeyNotConfigured = aiError {
                    showingSettings = true
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func applyAIEstimate(
        _ estimate: NutritionInfo,
        currentQuantity: Double,
        knownTotalCalories: Double
    ) {
        let estimatedQuantity = max(0, estimate.grams)
        let resolvedQuantity = currentQuantity > 0 ? currentQuantity : estimatedQuantity

        guard resolvedQuantity > 0 else {
            errorMessage = "AI 未能估算摄入量，请手动填写后重试。"
            return
        }

        let sourceQuantity = estimatedQuantity > 0 ? estimatedQuantity : resolvedQuantity
        let scale = resolvedQuantity / sourceQuantity
        let resolvedCalories = max(0, estimate.calories * scale)
        let resolvedProtein = max(0, estimate.protein * scale)
        let resolvedCarbs = max(0, estimate.carbohydrates * scale)
        let resolvedFat = max(0, estimate.fat * scale)

        if resolvedProtein + resolvedCarbs + resolvedFat <= 0,
           max(knownTotalCalories, resolvedCalories) > 5 {
            errorMessage = "AI 未返回有效的营养成分，请重试。"
            return
        }

        if (parsedOptionalValue(totalQuantity) ?? 0) <= 0 {
            totalQuantity = Self.trimmedNumber(resolvedQuantity)
        }
        if (parsedOptionalValue(totalCalories) ?? 0) <= 0, resolvedCalories > 0 {
            totalCalories = Self.trimmedNumber(energyUnit.fromKilocalories(resolvedCalories))
        }
        if brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let estimatedBrand = estimate.brand {
            brand = estimatedBrand
        }

        totalProtein = Self.trimmedNumber(resolvedProtein)
        totalCarbohydrates = Self.trimmedNumber(resolvedCarbs)
        totalFat = Self.trimmedNumber(resolvedFat)

        let per100Scale = 100 / resolvedQuantity
        let referenceCalories = knownTotalCalories > 0 ? knownTotalCalories : resolvedCalories
        if (parsedOptionalValue(caloriesPer100) ?? 0) <= 0, referenceCalories > 0 {
            caloriesPer100 = Self.trimmedNumber(
                energyUnit.fromKilocalories(referenceCalories * per100Scale)
            )
        }
        proteinPer100 = Self.trimmedNumber(resolvedProtein * per100Scale)
        carbohydratesPer100 = Self.trimmedNumber(resolvedCarbs * per100Scale)
        fatPer100 = Self.trimmedNumber(resolvedFat * per100Scale)

        errorMessage = nil
        selectedImage = nil
        aiStatusMessage = currentQuantity > 0
            ? "已补全总量和单位营养，请确认后保存。"
            : "已估算份量并补全营养，请确认后保存。"
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            selectedImage = nil
            showingCamera = true
        } else {
            showingCameraAlert = true
        }
    }

    private func recognizeCapturedImage() {
        guard let image = selectedImage else { return }
        selectedImage = nil
        recognizeWithAI(image: image)
    }

    private func confirmSave() {
        focusedField = nil
        guard savePreferenceChanges(requireIntakeAmount: false) != nil else { return }
        dismiss()
    }

    private func recordIntake() {
        focusedField = nil
        guard let nutrition = savePreferenceChanges(requireIntakeAmount: true) else { return }
        _ = onRecordIntake(nutrition)
        onIntakeStateChange(true)
        dismiss()
    }

    private func deletePreference() {
        focusedField = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            isPreferenceSaved = false
        }
    }

    private func commitPreferenceSavedState() {
        guard !isPreferenceSaved else { return }
        modelContext.delete(preference)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func savePreferenceChanges(requireIntakeAmount: Bool) -> NutritionInfo? {
        let trimmedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "请输入食物名称"
            return nil
        }

        if let invalidField = firstInvalidNumberField() {
            errorMessage = "\(invalidField)请输入有效数字"
            return nil
        }

        let intakeQuantityValue = parsedOptionalValue(intakeQuantity)
        let totalQuantityValue = parsedOptionalValue(totalQuantity)
        let displayedTotalCaloriesValue = parsedOptionalValue(totalCalories)
        let totalProteinValue = parsedOptionalValue(totalProtein)
        let totalCarbohydratesValue = parsedOptionalValue(totalCarbohydrates)
        let totalFatValue = parsedOptionalValue(totalFat)
        let displayedCaloriesPer100Value = parsedOptionalValue(caloriesPer100)
        let proteinPer100Value = parsedOptionalValue(proteinPer100)
        let carbohydratesPer100Value = parsedOptionalValue(carbohydratesPer100)
        let fatPer100Value = parsedOptionalValue(fatPer100)

        guard displayedTotalCaloriesValue != nil || displayedCaloriesPer100Value != nil else {
            errorMessage = "请填写总热量或单位热量"
            return nil
        }

        if requireIntakeAmount,
           displayedCaloriesPer100Value != nil,
           (intakeQuantityValue ?? 0) <= 0 {
            errorMessage = "请输入本次摄入量"
            return nil
        }

        preference.keyword = trimmedName
        preference.updateBrand(brand)
        preference.category = category
        preference.energyUnit = energyUnit
        let totalCaloriesValue = displayedTotalCaloriesValue.map { energyUnit.toKilocalories($0) }
        let caloriesPer100Value = displayedCaloriesPer100Value.map { energyUnit.toKilocalories($0) }
        preference.updateTotalNutrition(
            quantity: totalQuantityValue,
            calories: totalCaloriesValue,
            protein: totalProteinValue,
            carbs: totalCarbohydratesValue,
            fat: totalFatValue
        )
        preference.updatePer100Nutrition(
            calories: caloriesPer100Value,
            protein: proteinPer100Value,
            carbs: carbohydratesPer100Value,
            fat: fatPer100Value
        )
        preference.defaultDescription = preferenceDescription(
            totalQuantity: totalQuantityValue,
            totalEnergy: displayedTotalCaloriesValue,
            unitEnergy: displayedCaloriesPer100Value
        )

        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        errorMessage = nil
        if let caloriesPer100Value {
            let quantity = intakeQuantityValue ?? 0
            let scale = quantity / 100
            return NutritionInfo(
                foodName: trimmedName,
                brand: brand,
                grams: quantity,
                calories: caloriesPer100Value * scale,
                protein: (proteinPer100Value ?? 0) * scale,
                carbohydrates: (carbohydratesPer100Value ?? 0) * scale,
                fat: (fatPer100Value ?? 0) * scale,
                confidence: "saved",
                notes: "从已保存习惯按单位数据记录",
                daysAgo: 0
            )
        }

        return NutritionInfo(
            foodName: trimmedName,
            brand: brand,
            grams: totalQuantityValue ?? 0,
            calories: totalCaloriesValue ?? 0,
            protein: totalProteinValue ?? 0,
            carbohydrates: totalCarbohydratesValue ?? 0,
            fat: totalFatValue ?? 0,
            confidence: "saved",
            notes: "从已保存习惯按总量数据记录",
            daysAgo: 0
        )
    }

    private func firstInvalidNumberField() -> String? {
        let fields = [
            ("本次摄入量", intakeQuantity),
            ("总量摄入量", totalQuantity),
            ("总热量", totalCalories),
            ("总蛋白质", totalProtein),
            ("总碳水", totalCarbohydrates),
            ("总脂肪", totalFat),
            ("单位热量", caloriesPer100),
            ("单位蛋白质", proteinPer100),
            ("单位碳水化合物", carbohydratesPer100),
            ("单位脂肪", fatPer100)
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

    private func convertEnergyUnit(from oldUnit: EnergyUnit, to newUnit: EnergyUnit) {
        guard oldUnit != newUnit else { return }
        totalCalories = convertedEnergyText(totalCalories, from: oldUnit, to: newUnit)
        caloriesPer100 = convertedEnergyText(caloriesPer100, from: oldUnit, to: newUnit)
    }

    private func convertedEnergyText(_ text: String, from oldUnit: EnergyUnit, to newUnit: EnergyUnit) -> String {
        guard let currentValue = parsedOptionalValue(text) else { return text }
        let kilocalories = oldUnit.toKilocalories(currentValue)
        return Self.trimmedNumber(newUnit.fromKilocalories(kilocalories))
    }

    private func preferenceDescription(
        totalQuantity: Double?,
        totalEnergy: Double?,
        unitEnergy: Double?
    ) -> String {
        if let unitEnergy {
            return "每100\(category.quantityUnitSymbol), \(Self.trimmedNumber(unitEnergy))\(energyUnit.symbol)"
        }
        if let totalEnergy {
            let quantityText = totalQuantity.map {
                "\(Self.trimmedNumber($0))\(category.quantityUnitSymbol), "
            } ?? ""
            return "\(quantityText)\(Self.trimmedNumber(totalEnergy))\(energyUnit.symbol)"
        }
        return foodName
    }

    private static func formatted(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func initialIntakeQuantity(for preference: FoodPreference) -> String {
        if let defaultGrams = preference.defaultGrams, defaultGrams > 0 {
            return formatted(defaultGrams)
        }

        // Older habits may have unit nutrition data but no saved serving size.
        // Start from one standard 100 g / 100 ml reference so the action is
        // immediately available while keeping the quantity editable.
        return preference.resolvedCaloriesPer100 != nil ? "100" : ""
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

    @State private var originalRecognizedList: [NutritionInfo]
    @State private var editableList: [NutritionInfo]
    @State private var selectedItems: Set<Int>
    @State private var editingItem: EditingItem?
    @State private var saveAsPreferences: Set<Int> = []  // Track which items to save as preferences
    @State private var addAsNewPreferenceItems: Set<Int> = []
    @State private var preferenceSaveMessage: String?
    @State private var didLoadMatchedPreferences = false

    init(nutritionList: [NutritionInfo], onConfirm: @escaping ([NutritionInfo]) -> Void) {
        self.onConfirm = onConfirm
        self._originalRecognizedList = State(initialValue: nutritionList)
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
                    Text("实心心形表示已有习惯；空心心形可选择新建习惯")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))

                // Food list
                List {
                    ForEach(Array(editableList.enumerated()), id: \.offset) { index, nutrition in
                        let originalMatch = index < originalRecognizedList.count
                            ? existingPreferences.bestMatch(
                                foodName: originalRecognizedList[index].foodName,
                                brand: originalRecognizedList[index].brand
                            )
                            : nil

                        MultipleFoodRow(
                            nutrition: nutrition,
                            preferenceMatch: originalMatch,
                            isUsingExistingPreference: originalMatch != nil
                                && !addAsNewPreferenceItems.contains(index),
                            isAddingAsNewPreference: addAsNewPreferenceItems.contains(index),
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
                            },
                            onToggleAddAsNewPreference: {
                                toggleAddAsNewPreference(at: index, match: originalMatch)
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
            .onAppear {
                loadMatchedPreferencesIfNeeded()
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

        var savedCount = 0
        var duplicateCount = 0
        var failedIndexes: Set<Int> = []
        for index in indexes {
            let nutrition = editableList[index]
            if addAsNewPreferenceItems.contains(index),
               existingPreferences.contains(where: {
                   $0.matches(keyword: nutrition.foodName, brand: nutrition.brand)
               }) {
                duplicateCount += 1
                failedIndexes.insert(index)
                continue
            }
            savePreference(nutrition)
            savedCount += 1
        }

        if duplicateCount > 0 {
            preferenceSaveMessage = savedCount > 0
                ? "已保存 \(savedCount) 个；\(duplicateCount) 个需修改名称或品牌后新建"
                : "名称和品牌与已有习惯相同，请编辑后再新建"
        } else {
            preferenceSaveMessage = "已保存 \(savedCount) 个食物习惯"
        }
        saveAsPreferences = saveAsPreferences.intersection(failedIndexes)
    }

    private func loadMatchedPreferencesIfNeeded() {
        guard !didLoadMatchedPreferences else { return }
        didLoadMatchedPreferences = true

        for index in originalRecognizedList.indices {
            guard index < editableList.count,
                  let match = existingPreferences.bestMatch(
                    foodName: originalRecognizedList[index].foodName,
                    brand: originalRecognizedList[index].brand
                  ) else {
                continue
            }
            editableList[index] = nutrition(
                loadedFrom: match.preference,
                fallback: originalRecognizedList[index]
            )
        }
    }

    private func toggleAddAsNewPreference(at index: Int, match: FoodPreferenceMatch?) {
        guard index < editableList.count,
              index < originalRecognizedList.count,
              let match else {
            return
        }

        if addAsNewPreferenceItems.contains(index) {
            addAsNewPreferenceItems.remove(index)
            saveAsPreferences.remove(index)
            editableList[index] = nutrition(
                loadedFrom: match.preference,
                fallback: originalRecognizedList[index]
            )
        } else {
            addAsNewPreferenceItems.insert(index)
            saveAsPreferences.insert(index)
            editableList[index] = originalRecognizedList[index]
        }
    }

    private func nutrition(
        loadedFrom preference: FoodPreference,
        fallback: NutritionInfo
    ) -> NutritionInfo {
        let quantity = preference.defaultGrams ?? fallback.grams
        let scale = quantity > 0 ? quantity / 100 : 1

        return NutritionInfo(
            foodName: preference.keyword,
            brand: preference.brand,
            grams: quantity,
            calories: preference.resolvedCaloriesPer100.map { $0 * scale }
                ?? preference.defaultCalories
                ?? fallback.calories,
            protein: preference.resolvedProteinPer100.map { $0 * scale }
                ?? preference.defaultProtein
                ?? fallback.protein,
            carbohydrates: preference.resolvedCarbsPer100.map { $0 * scale }
                ?? preference.defaultCarbs
                ?? fallback.carbohydrates,
            fat: preference.resolvedFatPer100.map { $0 * scale }
                ?? preference.defaultFat
                ?? fallback.fat,
            confidence: fallback.confidence,
            notes: "已加载食物习惯",
            daysAgo: fallback.daysAgo
        )
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
            existing.updateNutritionReference(
                quantity: nutrition.grams,
                calories: nutrition.calories,
                protein: nutrition.protein,
                carbs: nutrition.carbohydrates,
                fat: nutrition.fat
            )
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
    let preferenceMatch: FoodPreferenceMatch?
    let isUsingExistingPreference: Bool
    let isAddingAsNewPreference: Bool
    let isSelected: Bool
    let isSavingAsPreference: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onToggleSavePreference: () -> Void
    let onToggleAddAsNewPreference: () -> Void

    private var isAlreadySaved: Bool {
        isUsingExistingPreference
    }

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

                if let preferenceMatch {
                    Label(
                        isUsingExistingPreference
                            ? "已加载习惯：\(preferenceMatch.preference.keyword)"
                            : "将另建习惯，未加载：\(preferenceMatch.preference.keyword)",
                        systemImage: isUsingExistingPreference ? "heart.fill" : "plus.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(isUsingExistingPreference ? .pink : .orange)

                    Toggle("添加为新的食物习惯", isOn: Binding(
                        get: { isAddingAsNewPreference },
                        set: { _ in onToggleAddAsNewPreference() }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)
                } else {
                    Label("未在食物习惯中", systemImage: "heart")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Save as preference button
            Button {
                onToggleSavePreference()
            } label: {
                Image(systemName: isAlreadySaved || isSavingAsPreference ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isAlreadySaved || isSavingAsPreference ? .pink : .gray)
            }
            .buttonStyle(.plain)
            .disabled(isAlreadySaved)
            .accessibilityLabel(isAlreadySaved ? "已在食物习惯中" : "新建食物习惯")

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
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var existingEntries: [FoodEntry]
    @Query private var existingPreferences: [FoodPreference]

    let nutrition: NutritionInfo
    let onSave: (NutritionInfo) -> Void

    @State private var foodName: String = ""
    @State private var brand: String = ""
    @State private var grams: String = ""
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var carbohydrates: String = ""
    @State private var fat: String = ""

    private var knownBrands: [String] {
        BrandSuggestionCatalog.brands(
            entries: existingEntries,
            preferences: existingPreferences
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("食物信息") {
                    TextField("食物名称", text: $foodName)
                    BrandAutocompleteField(
                        text: $brand,
                        brands: knownBrands,
                        style: .plain
                    )
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

struct CameraView: View {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            if let errorMessage = camera.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                    Text(errorMessage)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(28)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 32)
            }

            VStack(spacing: 18) {
                Spacer()

                Button {
                    camera.cycleFlashMode()
                } label: {
                    Label(flashTitle, systemImage: flashIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(camera.isFlashAvailable ? Color.yellow : Color.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(.black.opacity(0.64), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!camera.isFlashAvailable)
                .accessibilityLabel("闪光灯\(flashTitle)")

                HStack {
                    cameraControlButton(
                        systemName: "xmark",
                        accessibilityLabel: "关闭相机"
                    ) {
                        dismiss()
                    }

                    Spacer()

                    Button {
                        camera.capturePhoto()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 72, height: 72)
                            Circle()
                                .stroke(.white.opacity(0.55), lineWidth: 5)
                                .frame(width: 86, height: 86)
                        }
                        .opacity(camera.isCapturing ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isCapturing || camera.errorMessage != nil)
                    .accessibilityLabel("拍照")

                    Spacer()

                    cameraControlButton(
                        systemName: "arrow.triangle.2.circlepath.camera.fill",
                        accessibilityLabel: "切换前后镜头"
                    ) {
                        camera.switchCamera()
                    }
                }
                .padding(.horizontal, 34)
            }
            .padding(.bottom, 20)
            .background(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 250)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .onAppear {
            camera.start()
        }
        .onDisappear {
            camera.stop()
        }
        .onReceive(camera.$capturedImage) { capturedImage in
            guard let capturedImage else { return }
            image = capturedImage
            dismiss()
        }
    }

    private var flashTitle: String {
        switch camera.flashMode {
        case .on:
            return "开启"
        case .off:
            return "关闭"
        default:
            return "自动"
        }
    }

    private var flashIcon: String {
        switch camera.flashMode {
        case .on:
            return "bolt.fill"
        case .off:
            return "bolt.slash.fill"
        default:
            return "bolt.fill"
        }
    }

    private func cameraControlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.black.opacity(0.64), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published private(set) var isFlashAvailable = false
    @Published private(set) var isCapturing = false

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.caloriecapture.camera.session")
    private var currentInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorizedSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.startAuthorizedSession()
                } else {
                    self?.publishError("请在系统设置中允许相机权限。")
                }
            }
        case .denied, .restricted:
            publishError("请在系统设置中允许相机权限。")
        @unknown default:
            publishError("当前无法使用相机。")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        let requestedFlashMode = flashMode

        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else {
                DispatchQueue.main.async {
                    self?.isCapturing = false
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            if self.currentInput?.device.hasFlash == true {
                settings.flashMode = requestedFlashMode
            }

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func cycleFlashMode() {
        guard isFlashAvailable else { return }
        switch flashMode {
        case .auto:
            flashMode = .on
        case .on:
            flashMode = .off
        default:
            flashMode = .auto
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }

            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            guard let newDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: newPosition
            ), let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                return
            }

            self.session.beginConfiguration()
            if let currentInput = self.currentInput {
                self.session.removeInput(currentInput)
            }

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentInput = newInput
                self.cameraPosition = newPosition
            } else if let currentInput = self.currentInput,
                      self.session.canAddInput(currentInput) {
                self.session.addInput(currentInput)
            }
            self.session.commitConfiguration()

            let hasFlash = newPosition == .back && newDevice.hasFlash
            DispatchQueue.main.async {
                self.isFlashAvailable = hasFlash
                if !hasFlash {
                    self.flashMode = .off
                }
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "拍照失败：\(error.localizedDescription)"
            }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "无法读取拍摄的照片，请重试。"
            }
            return
        }

        DispatchQueue.main.async {
            self.isCapturing = false
            self.capturedImage = image
        }
    }

    private func startAuthorizedSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.configureSessionIfNeeded() else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureSessionIfNeeded() -> Bool {
        if isConfigured { return true }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            publishError("当前设备没有可用的相机。")
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
                publishError("相机初始化失败，请稍后重试。")
                return false
            }

            session.addInput(input)
            session.addOutput(photoOutput)
            currentInput = input
            isConfigured = true

            DispatchQueue.main.async {
                self.isFlashAvailable = device.hasFlash
            }
            return true
        } catch {
            publishError("相机初始化失败：\(error.localizedDescription)")
            return false
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isCapturing = false
        }
    }
}

// MARK: - Preference Row With Actions

struct PreferenceRowWithActions: View {
    @Environment(\.colorScheme) private var colorScheme

    let preference: FoodPreference
    let isRecordedForDate: Bool
    let onTap: () -> Void
    let onRecognize: () -> Void
    let onRecord: () -> Void
    let onDelete: () -> Void

    @State private var settledOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    private let deleteButtonWidth: CGFloat = 84

    private var currentOffset: CGFloat {
        min(0, max(-deleteButtonWidth, settledOffset + dragOffset))
    }

    private var deleteRevealProgress: Double {
        min(1, max(0, Double(-currentOffset / deleteButtonWidth)))
    }

    private var displayedEnergy: String {
        if let totalCalories = preference.defaultCalories {
            return "\(formatted(preference.energyUnit.fromKilocalories(totalCalories))) \(preference.energyUnit.symbol)"
        }
        if let unitCalories = preference.resolvedCaloriesPer100 {
            return "\(formatted(preference.energyUnit.fromKilocalories(unitCalories))) \(preference.energyUnit.symbol)/100\(preference.quantityUnitSymbol)"
        }
        return "--"
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    settledOffset = 0
                }
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.headline)
                    Text("删除")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .frame(width: deleteButtonWidth)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.red)
            .opacity(deleteRevealProgress)
            .contentShape(Rectangle())
            .allowsHitTesting(deleteRevealProgress > 0.5)
            .zIndex(2)

            rowContent
                .offset(x: currentOffset)
                .overlay {
                    if settledOffset != 0 {
                        Color.clear
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                            .onTapGesture {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                                    settledOffset = 0
                                }
                            }
                    }
                }
                .zIndex(1)
        }
        .background {
            HorizontalPanGestureBridge(
                onChanged: { dragOffset = $0 },
                onEnded: finishSwipe
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color(.separator).opacity(colorScheme == .dark ? 0.62 : 0.18),
                    lineWidth: colorScheme == .dark ? 1 : 0.5
                )
        }
        .shadow(
            color: colorScheme == .dark ? .clear : .black.opacity(0.08),
            radius: 4,
            x: 0,
            y: 2
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: settledOffset)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(action: onTap) {
                Label("编辑", systemImage: "pencil")
            }

            Button(action: onRecognize) {
                Label("AI识别", systemImage: "sparkles")
            }

            Button(action: onRecord) {
                Label(
                    isRecordedForDate ? "再次记录摄入" : "记录摄入",
                    systemImage: "plus.circle"
                )
            }

            Button(role: .destructive, action: onDelete) {
                Label("删除食物习惯", systemImage: "trash")
            }
        }
        .accessibilityAction(named: "删除") {
            onDelete()
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(preference.category.rawValue, systemImage: preference.category.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())

                    Text(preference.keyword)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let brand = preference.brand {
                        Text(brand)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let quantity = preference.defaultGrams {
                        Text("\(formatted(quantity))\(preference.quantityUnitSymbol)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("单位基准")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 4) {
                Button(action: onTap) {
                    Text(displayedEnergy)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.plain)

                HStack(spacing: 2) {
                    Button(action: onRecognize) {
                        AIRecognitionStatusIcon(
                            isComplete: preference.hasCompleteNutritionInfo
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("AI识别")
                    .accessibilityValue(preference.hasCompleteNutritionInfo ? "营养信息完整" : "营养信息待补全")

                    Button(action: onDelete) {
                        Image(systemName: "heart.fill")
                            .font(.title2)
                            .foregroundStyle(.pink)
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消保存习惯")
                    .accessibilityValue("已保存")

                    Button(action: onRecord) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isRecordedForDate ? Color.blue : Color.secondary)
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("记录摄入")
                    .accessibilityValue(isRecordedForDate ? "已添加到当日" : "未添加到当日")
                }
            }
        }
        .padding(14)
        .background(AppSurfaceStyle.cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func finishSwipe(translation: CGFloat, velocity: CGFloat) {
        let projectedOffset = settledOffset + translation + velocity * 0.12
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            dragOffset = 0
            settledOffset = projectedOffset < -deleteButtonWidth / 2 ? -deleteButtonWidth : 0
        }
    }

    private func formatted(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

enum BrandSuggestionCatalog {
    static func brands(
        entries: [FoodEntry],
        preferences: [FoodPreference]
    ) -> [String] {
        let values = entries.compactMap(\.brand) + preferences.compactMap(\.brand)
        var seen = Set<String>()

        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = normalized(trimmed)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum BrandAutocompleteStyle {
    case inset
    case plain
}

struct BrandAutocompleteField: View {
    @Binding var text: String
    let brands: [String]
    var placeholder = "品牌"
    var style: BrandAutocompleteStyle = .inset
    var inputBackground = AppSurfaceStyle.formInputBackground
    var textAlignment: TextAlignment = .leading

    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        let query = BrandSuggestionCatalog.normalized(text)
        let matches = brands.filter { brand in
            let normalizedBrand = BrandSuggestionCatalog.normalized(brand)
            if query.isEmpty {
                return true
            }
            return normalizedBrand != query && normalizedBrand.contains(query)
        }

        if query.isEmpty {
            return Array(matches.prefix(6))
        }

        return Array(
            matches.sorted { lhs, rhs in
                let lhsStartsWithQuery = BrandSuggestionCatalog.normalized(lhs).hasPrefix(query)
                let rhsStartsWithQuery = BrandSuggestionCatalog.normalized(rhs).hasPrefix(query)
                if lhsStartsWithQuery != rhsStartsWithQuery {
                    return lhsStartsWithQuery
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .prefix(6)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(textAlignment)
                .focused($isFocused)
                .submitLabel(.next)
                .padding(.horizontal, style == .inset ? 12 : 0)
                .padding(.vertical, style == .inset ? 12 : 0)
                .background(style == .inset ? inputBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: style == .inset ? 10 : 0))

            if isFocused && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                text = suggestion
                                isFocused = false
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AppSurfaceStyle.formInputBackground)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: suggestions)
    }
}

#Preview {
    FoodInputView()
        .modelContainer(for: [FoodEntry.self, FoodPreference.self], inMemory: true)
}
