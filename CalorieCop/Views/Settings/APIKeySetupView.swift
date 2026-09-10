import SwiftUI
import SwiftData

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthKitService = HealthKitService()
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Query(sort: \FoodPreference.usageCount, order: .reverse) private var foodPreferences: [FoodPreference]

    var onAPISettingsChanged: (() -> Void)?

    private var currentWeight: Double? {
        healthKitService.currentWeight ?? weightEntries.first?.weight
    }

    var body: some View {
        NavigationStack {
            List {
                Section("目标") {
                    NavigationLink {
                        GoalSettingView(
                            passedCurrentWeight: currentWeight,
                            passedAverageDailyCaloriesBurned: healthKitService.recentAverageCaloriesBurned,
                            passedAverageDailyCaloriesBurnedDays: healthKitService.recentAverageCaloriesBurnedDays
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("设置目标")
                                    .foregroundStyle(.primary)
                                Text("目标体重、目标日期和热量缺口")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "target")
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Section("AI 服务") {
                    NavigationLink {
                        APIKeySetupView {
                            onAPISettingsChanged?()
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("API 设置")
                                    .foregroundStyle(.primary)
                                Text("配置 DeepSeek、MiniMax 和 Qwen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("数据") {
                    NavigationLink {
                        FoodPreferencesSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("保存的习惯")
                                    .foregroundStyle(.primary)
                        Text("管理已保存的食物习惯")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                await healthKitService.requestAuthorization()
                await healthKitService.fetchRecentAverageCaloriesBurned()
            }
        }
    }
}

struct AppSettingsToolbarButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("设置")
    }
}

struct APIKeySetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var miniMaxKey = ""
    @State private var deepSeekKey = ""
    @State private var qwenKey = ""
    @State private var showMiniMaxKey = false
    @State private var showDeepSeekKey = false
    @State private var showQwenKey = false
    @State private var selectedRegion: APIRegion = .international
    @State private var refreshTrigger = false  // Force UI refresh

    var onComplete: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设置 API 密钥")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("CalorieCop 使用 AI 来识别食物和提供健康建议。请设置以下 API 密钥以启用这些功能。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Region selector
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(.blue)
                            Text("选择地区")
                                .font(.headline)
                        }

                        Text("根据您的位置选择合适的服务器，以获得最佳连接速度。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("地区", selection: $selectedRegion) {
                            ForEach(APIRegion.allCases, id: \.self) { region in
                                Text(region.displayName).tag(region)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .background(AppSurfaceStyle.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 3)

                    let _ = refreshTrigger  // Force refresh

                    VStack(alignment: .leading, spacing: 12) {
                        // DeepSeek API Section
                        apiKeySection(
                            title: "DeepSeek API",
                            subtitle: "用于文字、图片食物识别、按需联网检索和 AI 顾问",
                            key: $deepSeekKey,
                            showKey: $showDeepSeekKey,
                            isConfigured: APIKeyManager.isDeepSeekConfigured,
                            hasUserKey: APIKeyManager.hasUserDeepSeekKey
                        )

                        // Qwen API Section
                        apiKeySection(
                            title: "阿里云 Qwen API",
                            subtitle: "用于 AI 顾问图片分析（可选）",
                            key: $qwenKey,
                            showKey: $showQwenKey,
                            isConfigured: APIKeyManager.isQwenConfigured,
                            hasUserKey: APIKeyManager.hasUserQwenKey
                        )

                        // MiniMax API Section
                        apiKeySection(
                            title: "MiniMax API",
                            subtitle: "用于 Highspeed 文字解析和 AI 顾问",
                            key: $miniMaxKey,
                            showKey: $showMiniMaxKey,
                            isConfigured: APIKeyManager.isMiniMaxConfigured,
                            hasUserKey: APIKeyManager.hasUserMiniMaxKey
                        )
                    }

                    // Save button
                    Button {
                        saveKeys()
                    } label: {
                        Text("保存设置")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canSave ? Color.blue : Color.gray)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canSave)

                    // Note
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.green)
                            Text("安全说明")
                                .fontWeight(.medium)
                        }

                        Text("您的 API 密钥仅存储在本地设备上，不会上传到任何服务器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Clear keys button - show if user has entered keys
                    if APIKeyManager.hasUserMiniMaxKey || APIKeyManager.hasUserDeepSeekKey || APIKeyManager.hasUserQwenKey {
                        Button(role: .destructive) {
                            APIKeyManager.clearUserKeys()
                            miniMaxKey = ""
                            deepSeekKey = ""
                            qwenKey = ""
                            refreshTrigger.toggle()  // Force UI refresh
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("清除已保存的密钥")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // Note about developer keys
                    let _ = refreshTrigger  // Use refreshTrigger to force view update
                    if !APIKeyManager.hasUserMiniMaxKey && APIKeyManager.isMiniMaxConfigured {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("MiniMax 正在使用开发者预设密钥")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !APIKeyManager.hasUserDeepSeekKey && APIKeyManager.isDeepSeekConfigured {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("DeepSeek 正在使用开发者预设密钥")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !APIKeyManager.hasUserQwenKey && APIKeyManager.isQwenConfigured {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("Qwen 正在使用开发者预设密钥")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .background(AppSurfaceStyle.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle("API 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppSurfaceStyle.pageBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedRegion = APIKeyManager.region
                // User-entered values stay masked in SecureField until the
                // matching eye button is tapped. Developer defaults are not
                // copied into editable fields.
                miniMaxKey = APIKeyManager.userMiniMaxAPIKey ?? ""
                deepSeekKey = APIKeyManager.userDeepSeekAPIKey ?? ""
                qwenKey = APIKeyManager.userQwenAPIKey ?? ""
                showMiniMaxKey = false
                showDeepSeekKey = false
                showQwenKey = false
            }
        }
    }

    private var canSave: Bool {
        // Can save if region changed or new key entered
        let regionChanged = selectedRegion != APIKeyManager.region
        let hasMiniMax = !miniMaxKey.isEmpty
        let hasDeepSeek = !deepSeekKey.isEmpty
        let hasQwen = !qwenKey.isEmpty
        return regionChanged || hasMiniMax || hasDeepSeek || hasQwen
    }

    private func apiKeySection(
        title: String,
        subtitle: String,
        key: Binding<String>,
        showKey: Binding<Bool>,
        isConfigured: Bool,
        hasUserKey: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppSurfaceStyle.formSecondaryText)
                }

                Spacer()

                if hasUserKey {
                    Label("用户已配置", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if isConfigured {
                    Label("开发者预设", systemImage: "wrench.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("未配置", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Key input
            HStack {
                if showKey.wrappedValue {
                    TextField("输入 API Key", text: key)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textSelection(.enabled)
                } else {
                    SecureField("输入 API Key", text: key)
                        .textFieldStyle(.plain)
                }

                // Paste button
                Button {
                    if let clipboardString = UIPasteboard.general.string {
                        key.wrappedValue = clipboardString
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.blue)
                }

                // Clear button
                if !key.wrappedValue.isEmpty {
                    Button {
                        key.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                // Show/hide button
                Button {
                    showKey.wrappedValue.toggle()
                } label: {
                    Image(systemName: showKey.wrappedValue ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(AppSurfaceStyle.formInputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppSurfaceStyle.inputBorder, lineWidth: 1)
            }
            .contextMenu {
                Button {
                    if let clipboardString = UIPasteboard.general.string {
                        key.wrappedValue = clipboardString
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }

                Button {
                    key.wrappedValue = ""
                } label: {
                    Label("清除", systemImage: "trash")
                }
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppSurfaceStyle.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 3)
    }

    private func saveKeys() {
        // Always save region
        APIKeyManager.region = selectedRegion

        if !miniMaxKey.isEmpty {
            APIKeyManager.setUserMiniMaxKey(miniMaxKey)
        }
        if !deepSeekKey.isEmpty {
            APIKeyManager.setUserDeepSeekKey(deepSeekKey)
        }
        if !qwenKey.isEmpty {
            APIKeyManager.setUserQwenKey(qwenKey)
        }
        onComplete?()
        dismiss()
    }
}

// MARK: - Compact API Key Prompt View

struct APISettingsToolbarButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "gear")
        }
        .accessibilityLabel("API设置")
    }
}

struct APIKeyPromptView: View {
    let onSetup: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("需要设置 API 密钥")
                .font(.headline)

            Text("CalorieCop 使用 AI 来识别食物。请先设置 API 密钥以启用此功能。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                onSetup()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("设置 API 密钥")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 10)
        .padding()
    }
}

#Preview {
    APIKeySetupView()
}
