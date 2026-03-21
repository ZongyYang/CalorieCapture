import SwiftUI

struct APIKeySetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var miniMaxKey = ""
    @State private var qwenKey = ""
    @State private var showMiniMaxKey = false
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
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.05), radius: 5)

                    // MiniMax API Section
                    let _ = refreshTrigger  // Force refresh
                    apiKeySection(
                        title: "MiniMax API",
                        subtitle: "用于文字解析和 AI 顾问",
                        key: $miniMaxKey,
                        showKey: $showMiniMaxKey,
                        isConfigured: APIKeyManager.isMiniMaxConfigured,
                        hasUserKey: APIKeyManager.hasUserMiniMaxKey,
                        instructions: miniMaxInstructions,
                        websiteURL: miniMaxWebsiteURL
                    )

                    // Qwen API Section (Optional)
                    apiKeySection(
                        title: "阿里云 Qwen API（可选）",
                        subtitle: "用于图片食物识别",
                        key: $qwenKey,
                        showKey: $showQwenKey,
                        isConfigured: APIKeyManager.isQwenConfigured,
                        hasUserKey: APIKeyManager.hasUserQwenKey,
                        instructions: qwenInstructions,
                        websiteURL: qwenWebsiteURL
                    )

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
                    if APIKeyManager.hasUserMiniMaxKey || APIKeyManager.hasUserQwenKey {
                        Button(role: .destructive) {
                            APIKeyManager.clearUserKeys()
                            miniMaxKey = ""
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
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle("API 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Load existing settings
                selectedRegion = APIKeyManager.region
                // Don't show anything in input fields for existing keys
                // The "已配置" badge indicates the key is set
            }
        }
    }

    private var canSave: Bool {
        // Can save if region changed or new key entered
        let regionChanged = selectedRegion != APIKeyManager.region
        let hasMiniMax = !miniMaxKey.isEmpty
        let hasQwen = !qwenKey.isEmpty
        return regionChanged || hasMiniMax || hasQwen
    }

    // MARK: - Region-specific instructions

    private var miniMaxInstructions: [String] {
        switch selectedRegion {
        case .international:
            return [
                "1. 访问 minimax.io 并注册账号",
                "2. 进入控制台 → API Keys",
                "3. 创建新的 API Key",
                "4. 复制密钥并粘贴到下方"
            ]
        case .china:
            return [
                "1. 访问 minimaxi.com 并注册账号",
                "2. 进入控制台 → API Keys",
                "3. 创建新的 API Key",
                "4. 复制密钥并粘贴到下方"
            ]
        }
    }

    private var miniMaxWebsiteURL: String {
        switch selectedRegion {
        case .international:
            return "https://www.minimax.io"
        case .china:
            return "https://www.minimaxi.com"
        }
    }

    private var qwenInstructions: [String] {
        switch selectedRegion {
        case .international:
            return [
                "1. 访问阿里云国际站 DashScope",
                "2. 进入控制台 → API-KEY 管理",
                "3. 创建新的 API Key",
                "4. 复制密钥并粘贴到下方"
            ]
        case .china:
            return [
                "1. 访问阿里云 DashScope 并注册",
                "2. 进入控制台 → API-KEY 管理",
                "3. 创建新的 API Key",
                "4. 复制密钥并粘贴到下方"
            ]
        }
    }

    private var qwenWebsiteURL: String {
        switch selectedRegion {
        case .international:
            return "https://www.alibabacloud.com/product/dashscope"
        case .china:
            return "https://dashscope.console.aliyun.com"
        }
    }

    private func apiKeySection(
        title: String,
        subtitle: String,
        key: Binding<String>,
        showKey: Binding<Bool>,
        isConfigured: Bool,
        hasUserKey: Bool,
        instructions: [String],
        websiteURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            // Instructions
            VStack(alignment: .leading, spacing: 4) {
                ForEach(instructions, id: \.self) { step in
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let url = URL(string: websiteURL) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("打开官网")
                    }
                    .font(.caption)
                }
                .padding(.top, 4)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 5)
    }

    private func saveKeys() {
        // Always save region
        APIKeyManager.region = selectedRegion

        if !miniMaxKey.isEmpty {
            APIKeyManager.setUserMiniMaxKey(miniMaxKey)
        }
        if !qwenKey.isEmpty {
            APIKeyManager.setUserQwenKey(qwenKey)
        }
        onComplete?()
        dismiss()
    }
}

// MARK: - Compact API Key Prompt View

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
