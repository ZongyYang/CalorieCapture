import SwiftUI
import SwiftData
import PhotosUI

struct FoodInputView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodPreference.usageCount, order: .reverse) private var foodPreferences: [FoodPreference]

    @State private var inputText = ""
    @State private var isLoading = false
    @State private var parsedNutrition: NutritionInfo?
    @State private var parsedNutritionList: [NutritionInfo] = []
    @State private var errorMessage: String?
    @State private var showConfirmation = false
    @State private var showMultipleConfirmation = false

    // Image picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingCamera = false
    @State private var showingCameraAlert = false

    // Food preferences
    @State private var preferenceSearchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var preferenceToDelete: FoodPreference?

    // API Key setup
    @State private var showingAPIKeySetup = false
    @State private var apiKeyCheckTrigger = false  // Used to refresh state

    private let aiService = MiniMaxService()

    private var isAPIConfigured: Bool {
        // Text parsing needs MiniMax, image needs both MiniMax and Qwen
        APIKeyManager.isMiniMaxConfigured
    }

    private var isImageAPIConfigured: Bool {
        APIKeyManager.isQwenConfigured
    }

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // API Key setup prompt if not configured
                    // Use apiKeyCheckTrigger to force SwiftUI to re-evaluate
                    let _ = apiKeyCheckTrigger
                    if !isAPIConfigured {
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
            .navigationTitle("记录食物")
            .toolbar {
                if isAPIConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAPIKeySetup = true
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
            }
            .sheet(isPresented: $showConfirmation) {
                if let nutrition = parsedNutrition {
                    FoodConfirmationView(
                        rawInput: inputText.isEmpty ? "图片识别" : inputText,
                        originalNutrition: nutrition
                    ) { editedNutrition in
                        saveFoodEntry(with: editedNutrition)
                    }
                }
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
            .onChange(of: showingAPIKeySetup) { _, isShowing in
                // Refresh when sheet is dismissed
                if !isShowing {
                    apiKeyCheckTrigger.toggle()
                }
            }
        }
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

            Text("请设置 MiniMax API 密钥以启用文字解析功能。图片识别功能为可选。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                apiStatusRow(
                    name: "MiniMax API",
                    purpose: "文字解析（必需）",
                    isConfigured: APIKeyManager.isMiniMaxConfigured
                )
                apiStatusRow(
                    name: "Qwen API",
                    purpose: "图片识别（可选）",
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
        Text("拍照识别食物，可配合文字补充说明")
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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            selectedImage = nil
                            selectedPhoto = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .padding(8)
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

    private var canParse: Bool {
        !inputText.isEmpty || selectedImage != nil
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
                            onTap: { addPreferenceAsFood(pref) },
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

            Text("点击添加并编辑 | 删除用右侧按钮")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addPreferenceAsFood(_ preference: FoodPreference) {
        // If we have complete nutrition data, add directly
        if let grams = preference.defaultGrams,
           let calories = preference.defaultCalories,
           let protein = preference.defaultProtein,
           let carbs = preference.defaultCarbs,
           let fat = preference.defaultFat {
            let nutrition = NutritionInfo(
                foodName: preference.keyword,
                grams: grams,
                calories: calories,
                protein: protein,
                carbohydrates: carbs,
                fat: fat,
                confidence: "saved",
                notes: "从已保存习惯添加",
                daysAgo: 0
            )

            // Update usage count
            preference.usageCount += 1
            try? modelContext.save()

            // Show confirmation for review
            parsedNutrition = nutrition
            showConfirmation = true
        } else {
            // No complete data, use as input text
            inputText = preference.keyword
        }
    }

    private func parseFood() async {
        // Dismiss keyboard first
        _ = await MainActor.run {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        // Check API keys before parsing
        if selectedImage != nil && !isImageAPIConfigured {
            errorMessage = "图片识别需要设置 Qwen API 密钥。请在设置中配置。"
            showingAPIKeySetup = true
            return
        }

        if !APIKeyManager.isMiniMaxConfigured {
            errorMessage = "请先设置 MiniMax API 密钥"
            showingAPIKeySetup = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let nutritionList: [NutritionInfo]

            if let image = selectedImage {
                // Image parsing now supports multiple items via Qwen VL Plus
                nutritionList = try await aiService.parseFoodImageMultiple(image, additionalContext: inputText.isEmpty ? nil : inputText, preferences: foodPreferences)
            } else {
                // Text parsing supports multiple items
                nutritionList = try await aiService.parseFoodInputMultiple(inputText, preferences: foodPreferences)
            }

            if nutritionList.count == 1 {
                // Single item - show normal confirmation
                parsedNutrition = nutritionList.first
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

    private func saveFoodEntry(with nutrition: NutritionInfo) {
        let entry = FoodEntry(rawInput: inputText.isEmpty ? "图片识别: \(nutrition.foodName)" : inputText, nutrition: nutrition)
        modelContext.insert(entry)

        // Explicitly save to ensure Dashboard updates immediately
        try? modelContext.save()

        // Reset state
        inputText = ""
        selectedImage = nil
        selectedPhoto = nil
        parsedNutrition = nil
        showConfirmation = false

        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func saveMultipleFoodEntries(_ nutritionList: [NutritionInfo]) {
        for nutrition in nutritionList {
            let entry = FoodEntry(rawInput: inputText, nutrition: nutrition)
            modelContext.insert(entry)
        }
        try? modelContext.save()

        inputText = ""
        selectedImage = nil
        selectedPhoto = nil
        parsedNutritionList = []
        showMultipleConfirmation = false

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    let onConfirm: ([NutritionInfo]) -> Void

    @State private var editableList: [NutritionInfo]
    @State private var selectedItems: Set<Int>
    @State private var editingItem: EditingItem?
    @State private var saveAsPreferences: Set<Int> = []  // Track which items to save as preferences

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
                    Text("点击❤️保存习惯，点击✏️编辑")
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
            }
            .navigationTitle("确认食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认 (\(selectedItems.count))") {
                        // Save preferences for marked items
                        for index in saveAsPreferences {
                            if index < editableList.count {
                                savePreference(editableList[index])
                            }
                        }

                        let confirmed = selectedItems.sorted().compactMap { index in
                            index < editableList.count ? editableList[index] : nil
                        }
                        onConfirm(confirmed)
                        dismiss()
                    }
                    .disabled(selectedItems.isEmpty)
                    .fontWeight(.semibold)
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

    private func savePreference(_ nutrition: NutritionInfo) {
        let preference = FoodPreference(
            keyword: nutrition.foodName,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbs: nutrition.carbohydrates,
            fat: nutrition.fat
        )
        modelContext.insert(preference)
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
                    HStack {
                        Text("克重")
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
            // Tap to add - main content area
            Button {
                onTap()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preference.keyword)
                            .font(.subheadline)
                            .fontWeight(.medium)

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
            }
            .buttonStyle(.plain)

            // Delete button
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash.circle")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview {
    FoodInputView()
        .modelContainer(for: [FoodEntry.self, FoodPreference.self], inMemory: true)
}
