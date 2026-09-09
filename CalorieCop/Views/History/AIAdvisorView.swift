import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct AIAdvisorToolbarButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("AI顾问")
    }
}

struct AIAdvisorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.createdAt) private var chatMessages: [ChatMessage]

    let foodEntries: [FoodEntry]
    let userGoal: UserGoal?
    let currentWeight: Double?
    let weightHistory: [WeightRecord]
    var initialPrompt: String = ""

    @State private var userQuestion = ""
    @State private var hasUsedInitialPrompt = false
    @State private var isLoading = false
    @State private var showingDeleteConfirmation = false
    @State private var sessionStartTime = Date()  // Track current session for API calls
    @State private var streamingMessageId: UUID?  // Track message being streamed
    @State private var streamingContent = ""  // Accumulate streaming content
    @State private var showingSettings = false  // Unified settings sheet
    @State private var apiKeyRefreshTrigger = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var capturedImage: UIImage?
    @State private var showingCamera = false
    @State private var inputAlertMessage: String?
    @State private var isAdvisorInputFocused = false

    private var isAdvisorAPIConfigured: Bool {
        APIKeyManager.isDeepSeekConfigured || APIKeyManager.isMiniMaxConfigured || APIKeyManager.isQwenConfigured
    }

    /// Analyze question to determine what data to include
    private func detectDataNeeds(from question: String) -> (needsWeight: Bool, needsFood: Bool, foodDays: Int) {
        let q = question.lowercased()

        // Weight-related keywords
        let weightKeywords = ["体重", "重量", "瘦", "胖", "减重", "增重", "kg", "斤", "公斤"]
        let needsWeight = weightKeywords.contains { q.contains($0) }

        // Food/calorie-related keywords
        let foodKeywords = ["吃", "热量", "卡路里", "营养", "蛋白", "碳水", "脂肪", "饮食", "摄入", "kcal"]
        let needsFood = foodKeywords.contains { q.contains($0) }

        // Time range detection
        var foodDays = 3 // default
        if q.contains("一周") || q.contains("这周") || q.contains("7天") || q.contains("七天") {
            foodDays = 7
        } else if q.contains("两周") || q.contains("14天") || q.contains("半个月") {
            foodDays = 14
        } else if q.contains("今天") || q.contains("今日") {
            foodDays = 1
        } else if q.contains("昨天") {
            foodDays = 2
        } else if q.contains("最近") || q.contains("这几天") {
            foodDays = 5
        }

        // If neither detected, include basic data
        if !needsWeight && !needsFood {
            return (true, true, 3)
        }

        return (needsWeight, needsFood, foodDays)
    }

    /// Generate summary based on question context
    private func summaryForQuestion(_ question: String) -> String {
        let needs = detectDataNeeds(from: question)
        var summaryLines: [String] = []

        // Always include basic goal info (compact)
        if let goal = userGoal, let weight = currentWeight {
            var goalInfo = "【目标】当前\(String(format: "%.1f", weight))kg→目标\(String(format: "%.1f", goal.targetWeight))kg"
            if let targetDate = goal.targetDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/M/d"
                let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: targetDate).day ?? 0
                goalInfo += ", 目标日期:\(formatter.string(from: targetDate))(还剩\(daysLeft)天)"
            }
            goalInfo += ", TDEE:\(Int(goal.calculateTDEE(currentWeight: weight)))kcal, 建议摄入:\(Int(goal.recommendedDailyCalories(currentWeight: weight)))kcal"
            summaryLines.append(goalInfo)
        }

        // Weight history (if needed) - past 3 weeks
        if needs.needsWeight && !weightHistory.isEmpty {
            let threeWeeksAgo = Calendar.current.date(byAdding: .day, value: -21, to: Date()) ?? Date()
            let recentWeights = weightHistory.filter { $0.date >= threeWeeksAgo }
            if !recentWeights.isEmpty {
                summaryLines.append("【体重】")
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d"
                for record in recentWeights {
                    summaryLines.append("\(formatter.string(from: record.date)):\(String(format: "%.1f", record.weight))kg")
                }
            }
        }

        // Food entries (if needed)
        if needs.needsFood {
            let grouped = Dictionary(grouping: foodEntries) { entry in
                Calendar.current.startOfDay(for: entry.createdAt)
            }.sorted { $0.key > $1.key }

            summaryLines.append("【饮食】")
            if grouped.isEmpty {
                summaryLines.append("暂无记录")
            } else {
                for day in grouped.prefix(needs.foodDays) {
                    let totalCal = day.value.reduce(0) { $0 + $1.calories }
                    let totalProtein = day.value.reduce(0) { $0 + $1.protein }
                    let totalCarbs = day.value.reduce(0) { $0 + $1.carbohydrates }
                    let totalFat = day.value.reduce(0) { $0 + $1.fat }
                    let dateStr = formatDate(day.key)
                    summaryLines.append("\(dateStr):\(Int(totalCal))kcal P\(Int(totalProtein)) C\(Int(totalCarbs)) F\(Int(totalFat))")
                }
            }
        }

        return summaryLines.joined(separator: "\n")
    }

    private func activityLevelText(_ level: String) -> String {
        switch level {
        case "sedentary": return "久坐（很少运动）"
        case "light": return "轻度（每周1-3次运动）"
        case "moderate": return "中度（每周3-5次运动）"
        case "active": return "活跃（每周6-7次运动）"
        case "very_active": return "非常活跃（运动员/体力劳动）"
        default: return level
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                let _ = apiKeyRefreshTrigger
                if !isAdvisorAPIConfigured {
                    // API Key not configured - show setup prompt
                    Spacer()
                    apiKeyPromptSection
                    Spacer()
                } else {
                    // Conversation
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                // Welcome message
                                AIMessageBubble(content: "嗨～我是你的营养小助手 🥗\n\n我已经看到你的目标和饮食记录啦，随时可以帮你分析！\n\n试着问我：\n• 我最近吃得怎么样？\n• 照这个节奏多久能达标？\n• 有什么建议给我吗？")

                            ForEach(chatMessages) { message in
                                MessageRow(
                                    message: message,
                                    streamingMessageId: streamingMessageId,
                                    streamingContent: streamingContent,
                                    canDelete: message.id != streamingMessageId,
                                    onDelete: {
                                        deleteMessage(message)
                                    }
                                )
                                .id(message.id)
                            }

                            if isLoading && streamingMessageId == nil {
                                HStack {
                                    ProgressView()
                                        .padding()
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded { _ in
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                    )
                    .onChange(of: chatMessages.count) {
                        withAnimation {
                            if let lastMessage = chatMessages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input
                VStack(spacing: 0) {
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                selectedImages.remove(at: index)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.title3)
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.65))
                                            }
                                            .buttonStyle(.plain)
                                            .offset(x: 6, y: -6)
                                            .accessibilityLabel("移除第\(index + 1)张照片")
                                        }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }
                    }

                    HStack(spacing: 12) {
                        ImagePasteTextField(
                            text: $userQuestion,
                            placeholder: "输入问题或图片说明",
                            isEnabled: !isLoading,
                            returnKeyType: .send,
                            focusBinding: $isAdvisorInputFocused,
                            onSubmit: {
                                guard canSendMessage, !isLoading else { return }
                                Task { await sendMessage() }
                            },
                            onPasteImage: { image in
                                appendAdvisorImage(image)
                            },
                            onPasteFailure: {
                                inputAlertMessage = "剪贴板中没有可用的文字或图片。"
                            }
                        )
                        .frame(height: 36)

                        if !userQuestion.isEmpty {
                            Button {
                                userQuestion = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空文字")
                        }

                        Divider()
                            .frame(height: 22)

                        if isLoading {
                            TextRecognitionActionButton(
                                isProcessing: true,
                                isEnabled: false,
                                action: {},
                                accessibilityLabel: "发送给 AI 顾问",
                                processingAccessibilityLabel: "正在分析",
                                modelSelectionHint: "长按可切换 AI 顾问模型"
                            )
                        } else {
                            TextRecognitionActionButton(
                                isProcessing: false,
                                isEnabled: canSendMessage,
                                action: {
                                    Task {
                                        await sendMessage()
                                    }
                                },
                                accessibilityLabel: "发送给 AI 顾问",
                                processingAccessibilityLabel: "正在分析",
                                modelSelectionHint: "长按可切换 AI 顾问模型"
                            )
                        }

                        Button {
                            openCamera()
                        } label: {
                            Image(systemName: "camera.fill")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .disabled(isLoading)
                        .accessibilityLabel("拍照")

                        PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 8, matching: .images) {
                            Image(systemName: "photo.fill")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .disabled(isLoading)
                        .accessibilityLabel("从相册选择照片")
                    }
                    .frame(height: 36)
                    .foodSearchBarSurface()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemBackground))
                }  // End of else block for API configured
            }
            .navigationTitle("AI顾问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !chatMessages.isEmpty {
                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Text("清空")
                                .foregroundStyle(.red)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("清空聊天记录", isPresented: $showingDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    deleteAllMessages()
                }
            } message: {
                Text("确定要删除所有聊天记录吗？此操作无法撤销。")
            }
            .onAppear {
                // Resume interrupted conversation if there's an empty AI message
                resumeInterruptedConversation()

                // Auto-send initial prompt if provided
                if !initialPrompt.isEmpty && !hasUsedInitialPrompt {
                    hasUsedInitialPrompt = true
                    userQuestion = initialPrompt
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // Small delay for UI
                        await sendMessage()
                    }
                }
            }
            .onDisappear {
                // Save any streaming content before disappearing
                saveStreamingContent()
            }
            .sheet(isPresented: $showingSettings) {
                AppSettingsView {
                    apiKeyRefreshTrigger.toggle()
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView(image: $capturedImage)
            }
            .alert("提示", isPresented: Binding(
                get: { inputAlertMessage != nil },
                set: { if !$0 { inputAlertMessage = nil } }
            )) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(inputAlertMessage ?? "")
            }
            .onChange(of: selectedPhotos) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    var loadedImages: [UIImage] = []
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            loadedImages.append(image)
                        }
                    }
                    await MainActor.run {
                        let availableSlots = max(0, 8 - selectedImages.count)
                        selectedImages.append(contentsOf: loadedImages.prefix(availableSlots))
                        selectedPhotos = []
                        if loadedImages.isEmpty {
                            inputAlertMessage = "无法读取所选照片，请重新选择。"
                        } else if loadedImages.count > availableSlots {
                            inputAlertMessage = "每次提问最多可添加 8 张照片。"
                        }
                    }
                }
            }
            .onChange(of: showingCamera) { _, isShowing in
                guard !isShowing, let capturedImage else { return }
                appendAdvisorImage(capturedImage)
                self.capturedImage = nil
            }
        }
    }

    private var canSendMessage: Bool {
        !userQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            inputAlertMessage = "当前设备没有可用的相机。"
            return
        }
        showingCamera = true
    }

    private func appendAdvisorImage(_ image: UIImage) {
        guard selectedImages.count < 8 else {
            inputAlertMessage = "每次提问最多可添加 8 张照片。"
            return
        }
        selectedImages.append(image)
    }

    private var apiKeyPromptSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("需要设置 API 密钥")
                .font(.title2)
                .fontWeight(.bold)

            Text("AI 顾问需要 DeepSeek、MiniMax 或 Qwen API 密钥才能使用。请先设置至少一个 API 密钥。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

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
            .padding(.horizontal)
        }
        .padding()
    }

    private func saveStreamingContent() {
        guard let messageId = streamingMessageId,
              let message = chatMessages.first(where: { $0.id == messageId }) else {
            return
        }

        if !streamingContent.isEmpty {
            // Save partial content
            message.content = streamingContent
            try? modelContext.save()
        }
        // If empty, keep the placeholder - we'll resume on appear
    }

    private func resumeInterruptedConversation() {
        // Find empty AI message (interrupted streaming)
        let sortedMessages = chatMessages.sorted { $0.createdAt < $1.createdAt }
        guard let emptyAIMessage = sortedMessages.last(where: { $0.role == "assistant" && $0.content.isEmpty }) else {
            return
        }

        // Find the user question before it
        guard let index = sortedMessages.firstIndex(where: { $0.id == emptyAIMessage.id }),
              index > 0,
              sortedMessages[index - 1].role == "user" else {
            // No valid user question, clean up orphan
            modelContext.delete(emptyAIMessage)
            try? modelContext.save()
            return
        }

        let userQuestion = sortedMessages[index - 1].content

        // Resume streaming
        streamingMessageId = emptyAIMessage.id
        streamingContent = ""
        isLoading = true

        Task {
            do {
                let finalContent = try await askAIStreaming(question: userQuestion) { content in
                    Task { @MainActor in
                        streamingContent = content
                    }
                }
                await MainActor.run {
                    emptyAIMessage.content = finalContent
                    try? modelContext.save()
                    streamingMessageId = nil
                    streamingContent = ""
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    emptyAIMessage.content = "抱歉，出现了错误：\(error.localizedDescription)"
                    try? modelContext.save()
                    streamingMessageId = nil
                    streamingContent = ""
                    isLoading = false
                }
            }
        }
    }

    private func deleteAllMessages() {
        streamingMessageId = nil
        streamingContent = ""
        isLoading = false

        for message in chatMessages {
            modelContext.delete(message)
        }
        try? modelContext.save()
    }

    private func deleteMessage(_ message: ChatMessage) {
        guard message.id != streamingMessageId else { return }
        modelContext.delete(message)
        try? modelContext.save()
    }

    private func sendMessage() async {
        let typedQuestion = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = selectedImages
        guard !typedQuestion.isEmpty else { return }

        let question = typedQuestion
        userQuestion = ""
        selectedImages = []
        selectedPhotos = []

        // Save user message
        let displayedQuestion = images.isEmpty ? question : "📷×\(images.count) \(question)"
        let userMessage = ChatMessage(role: "user", content: displayedQuestion)
        modelContext.insert(userMessage)
        try? modelContext.save()

        isLoading = true
        streamingContent = ""

        // Create placeholder assistant message for streaming
        let assistantMessage = ChatMessage(role: "assistant", content: "")
        modelContext.insert(assistantMessage)
        try? modelContext.save()
        streamingMessageId = assistantMessage.id

        do {
            let finalContent = try await askAIStreaming(question: question, images: images) { content in
                // Update streaming content on main thread
                Task { @MainActor in
                    streamingContent = content
                }
            }
            // Final update with complete content
            await MainActor.run {
                assistantMessage.content = finalContent
                try? modelContext.save()
                streamingMessageId = nil
                streamingContent = ""
                isLoading = false
            }
        } catch {
            await MainActor.run {
                assistantMessage.content = "抱歉，出现了错误：\(error.localizedDescription)"
                try? modelContext.save()
                streamingMessageId = nil
                streamingContent = ""
                isLoading = false
            }
        }
    }

    private var currentTimeContext: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let timeString = formatter.string(from: Date())

        let hour = Calendar.current.component(.hour, from: Date())
        let period: String
        if hour < 6 {
            period = "凌晨"
        } else if hour < 9 {
            period = "早晨"
        } else if hour < 11 {
            period = "上午"
        } else if hour < 13 {
            period = "中午"
        } else if hour < 17 {
            period = "下午"
        } else if hour < 19 {
            period = "傍晚"
        } else {
            period = "晚上"
        }

        return "当前时间：\(timeString)（\(period)）"
    }

    /// Compress older messages into a brief summary to reduce context length
    private func compressMessages(_ messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else { return "" }

        var summaryParts: [String] = []

        // Group by topic/question
        var currentQuestion = ""
        var currentAnswer = ""

        for msg in messages {
            if msg.role == "user" {
                // Save previous Q&A if exists
                if !currentQuestion.isEmpty && !currentAnswer.isEmpty {
                    let shortQ = currentQuestion.prefix(30)
                    let shortA = currentAnswer.prefix(50)
                    summaryParts.append("问:\(shortQ)… 答:\(shortA)…")
                }
                currentQuestion = msg.content
                currentAnswer = ""
            } else {
                currentAnswer = msg.content
            }
        }

        // Don't forget last pair
        if !currentQuestion.isEmpty && !currentAnswer.isEmpty {
            let shortQ = currentQuestion.prefix(30)
            let shortA = currentAnswer.prefix(50)
            summaryParts.append("问:\(shortQ)… 答:\(shortA)…")
        }

        // Limit total summary length
        let summary = summaryParts.joined(separator: " | ")
        if summary.count > 300 {
            return String(summary.prefix(300)) + "…"
        }
        return summary
    }

    private func askAI(question: String) async throws -> String {
        guard let apiKey = APIKeyManager.miniMaxAPIKey else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let dynamicSummary = summaryForQuestion(question)

        // Include chat history with compression for long conversations
        let sortedMessages = chatMessages
            .filter { !$0.content.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }

        let maxRecentMessages = 6
        var historySummary = ""

        if sortedMessages.count > maxRecentMessages {
            let olderMessages = sortedMessages.prefix(sortedMessages.count - maxRecentMessages)
            historySummary = compressMessages(Array(olderMessages))
        }

        // Build single system prompt
        var systemPrompt = """
你是一位亲切友好的营养小助手，像朋友一样和用户聊天。\(currentTimeContext)

\(dynamicSummary)
"""
        if !historySummary.isEmpty {
            systemPrompt += "\n\n之前对话摘要：\(historySummary)"
        }

        systemPrompt += """

风格：温暖亲切，多用emoji表情😊🎉💪，像好朋友聊天。用"你"称呼用户，多鼓励夸奖。
格式：用•列表，可用**粗体**强调。禁止表格和代码块。
规则：简洁实用，用数据支持，中文，不超过150字。
"""

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // Add recent messages
        let recentMessages = sortedMessages.count > maxRecentMessages
            ? Array(sortedMessages.suffix(maxRecentMessages))
            : sortedMessages

        for msg in recentMessages {
            if msg.role == "user" && msg.content == question { continue }
            messages.append(["role": msg.role, "content": msg.content])
        }

        messages.append(["role": "user", "content": question])

        // Use highspeed model for faster response
        let requestBody: [String: Any] = [
            "model": "MiniMax-M2.7-highspeed",
            "messages": messages
        ]

        var request = URLRequest(url: APIKeyManager.miniMaxEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Log response for debugging
        let rawString = String(data: data, encoding: .utf8) ?? ""
        if let httpResponse = response as? HTTPURLResponse {
            DebugLogger.shared.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

            // Check HTTP status
            guard (200...299).contains(httpResponse.statusCode) else {
                throw AIServiceError.parsingError("HTTP错误 \(httpResponse.statusCode): \(rawString.prefix(200))")
            }
        }

        struct APIResponse: Decodable {
            let choices: [Choice]?
            let error: APIError?

            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String
                }
            }

            struct APIError: Decodable {
                let message: String?
                let code: String?
            }
        }

        let apiResponse: APIResponse
        do {
            apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            DebugLogger.shared.logError(error, context: "AI Advisor JSON decode")
            throw AIServiceError.parsingError("JSON解析失败: \(rawString.prefix(300))")
        }

        // Check for API error
        if let error = apiResponse.error {
            throw AIServiceError.parsingError("API错误: \(error.message ?? error.code ?? "未知")")
        }

        // Check for empty choices
        guard let choices = apiResponse.choices, !choices.isEmpty else {
            throw AIServiceError.parsingError("API返回为空: \(rawString.prefix(300))")
        }

        return choices.first?.message.content ?? "无法获取回复"
    }

    private func askAIStreaming(
        question: String,
        images: [UIImage] = [],
        onContent: @escaping (String) -> Void
    ) async throws -> String {
        if !images.isEmpty {
            guard let qwenAPIKey = APIKeyManager.qwenAPIKey, !qwenAPIKey.isEmpty else {
                throw AIServiceError.chatError("照片分析需要先在 API 设置中配置 Qwen API 密钥。")
            }
            let content = try await requestQwenVisionAdvisor(
                apiKey: qwenAPIKey,
                question: question,
                images: images
            )
            onContent(content)
            return content
        }

        let messages = advisorMessages(for: question)
        let selectedModel = APIKeyManager.textParsingModel
        guard APIKeyManager.isTextParsingModelConfigured(selectedModel) else {
            throw AIServiceError.chatError(
                "当前选择 \(selectedModel.displayName)，请先在设置中配置 \(selectedModel.providerName) API 密钥。"
            )
        }

        switch selectedModel {
        case .flash, .pro:
            guard let apiKey = APIKeyManager.deepSeekAPIKey, !apiKey.isEmpty else {
                throw AIServiceError.apiKeyNotConfigured
            }
            let content = try await requestDeepSeekAdvisor(
                apiKey: apiKey,
                messages: messages,
                model: selectedModel.apiModelName,
                reasoningEnabled: selectedModel.usesDeepSeekReasoning
            )
            onContent(content)
            return content
        case .highspeed:
            guard let apiKey = APIKeyManager.miniMaxAPIKey, !apiKey.isEmpty else {
                throw AIServiceError.apiKeyNotConfigured
            }
            do {
                return try await requestMiniMaxStreaming(
                    apiKey: apiKey,
                    messages: messages,
                    onContent: onContent
                )
            } catch {
                DebugLogger.shared.logError(error, context: "AI Advisor MiniMax streaming failed")
                let content = try await requestMiniMaxNonStreaming(apiKey: apiKey, messages: messages)
                onContent(content)
                return content
            }
        }
    }

    private func advisorMessages(for question: String) -> [[String: String]] {
        let dynamicSummary = summaryForQuestion(question)
        let sortedMessages = chatMessages
            .filter { !$0.content.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }

        let maxRecentMessages = 6
        var historySummary = ""

        if sortedMessages.count > maxRecentMessages {
            let olderMessages = sortedMessages.prefix(sortedMessages.count - maxRecentMessages)
            historySummary = compressMessages(Array(olderMessages))
        }

        var systemPrompt = """
你是一位亲切友好的营养小助手，像朋友一样和用户聊天。\(currentTimeContext)

\(dynamicSummary)
"""
        if !historySummary.isEmpty {
            systemPrompt += "\n\n之前对话摘要：\(historySummary)"
        }

        systemPrompt += """

风格：温暖亲切，多用emoji表情😊🎉💪，像好朋友聊天。用"你"称呼用户，多鼓励夸奖。
格式：用•列表，可用**粗体**强调。禁止表格和代码块。
规则：简洁实用，用数据支持，中文，不超过150字。
图片可用于识别食物、营养标签、餐盘份量或辅助健康建议；无法确认的信息要明确说明不确定性。
"""

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        let recentMessages = sortedMessages.count > maxRecentMessages
            ? Array(sortedMessages.suffix(maxRecentMessages))
            : sortedMessages

        for message in recentMessages {
            if message.role == "user" && message.content == question { continue }
            messages.append(["role": message.role, "content": message.content])
        }

        messages.append(["role": "user", "content": question])
        return messages
    }

    private func requestMiniMaxStreaming(
        apiKey: String,
        messages: [[String: String]],
        onContent: @escaping (String) -> Void
    ) async throws -> String {
        let requestBody: [String: Any] = [
            "model": "MiniMax-M2.7-highspeed",
            "messages": messages,
            "stream": true,
            "max_completion_tokens": 512
        ]

        var request = URLRequest(url: APIKeyManager.miniMaxEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData
        DebugLogger.shared.logAPIRequest(
            endpoint: APIKeyManager.miniMaxEndpoint.absoluteString,
            body: String(data: bodyData, encoding: .utf8)
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.parsingError("无效响应")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw AIServiceError.chatError("请求失败 (\(httpResponse.statusCode)): \(errorBody.prefix(200))")
        }

        var accumulatedContent = ""
        var loggedLineCount = 0

        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("data:") else { continue }

            let jsonString = String(trimmedLine.dropFirst(5))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonString == "[DONE]" { break }

            if loggedLineCount < 3 {
                DebugLogger.shared.log("AI Advisor stream chunk: \(jsonString.prefix(500))")
                loggedLineCount += 1
            }

            guard let text = extractResponseText(fromJSONString: jsonString) else { continue }
            accumulatedContent += text
            onContent(accumulatedContent)
        }

        guard !accumulatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.chatError("AI 返回为空，请重试")
        }

        return accumulatedContent
    }

    private func requestMiniMaxNonStreaming(apiKey: String, messages: [[String: String]]) async throws -> String {
        let requestBody: [String: Any] = [
            "model": "MiniMax-M2.7-highspeed",
            "messages": messages,
            "stream": false,
            "max_completion_tokens": 512
        ]

        return try await requestChatCompletion(
            endpoint: APIKeyManager.miniMaxEndpoint,
            apiKey: apiKey,
            requestBody: requestBody,
            providerName: "MiniMax"
        )
    }

    private func requestQwenAdvisor(apiKey: String, messages: [[String: String]]) async throws -> String {
        let requestBody: [String: Any] = [
            "model": "qwen-plus",
            "messages": messages,
            "temperature": 0.7
        ]

        return try await requestChatCompletion(
            endpoint: APIKeyManager.qwenEndpoint,
            apiKey: apiKey,
            requestBody: requestBody,
            providerName: "Qwen"
        )
    }

    private func requestQwenVisionAdvisor(
        apiKey: String,
        question: String,
        images: [UIImage]
    ) async throws -> String {
        var encodedImages: [String] = []
        for image in images {
            let resizedImage = resizeAdvisorImage(image, maxDimension: 1024)
            guard let imageData = resizedImage.jpegData(compressionQuality: 0.72) else {
                throw AIServiceError.chatError("无法处理所选照片，请重新选择。")
            }
            encodedImages.append(imageData.base64EncodedString())
        }

        let textMessages = advisorMessages(for: question)
        var contextMessages = Array(textMessages.dropLast())
        if contextMessages.last?["role"] == "user",
           contextMessages.last?["content"]?.hasSuffix(question) == true,
           contextMessages.last?["content"]?.hasPrefix("📷×") == true {
            contextMessages.removeLast()
        }
        var messages: [[String: Any]] = contextMessages.map {
            ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""]
        }
        var multimodalContent: [[String: Any]] = encodedImages.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0)"]]
        }
        multimodalContent.append(["type": "text", "text": question])
        messages.append([
            "role": "user",
            "content": multimodalContent
        ])

        let requestBody: [String: Any] = [
            "model": "qwen3-vl-plus",
            "messages": messages,
            "temperature": 0.4,
            "stream": false,
            "max_completion_tokens": 512
        ]

        return try await requestChatCompletion(
            endpoint: APIKeyManager.qwenEndpoint,
            apiKey: apiKey,
            requestBody: requestBody,
            providerName: "Qwen Vision",
            logRequestBody: false
        )
    }

    private func requestDeepSeekAdvisor(
        apiKey: String,
        messages: [[String: String]],
        model: String,
        reasoningEnabled: Bool
    ) async throws -> String {
        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "thinking": ["type": reasoningEnabled ? "enabled" : "disabled"],
            "stream": false
        ]

        return try await requestChatCompletion(
            endpoint: APIKeyManager.deepSeekEndpoint,
            apiKey: apiKey,
            requestBody: requestBody,
            providerName: "DeepSeek"
        )
    }

    private func requestChatCompletion(
        endpoint: URL,
        apiKey: String,
        requestBody: [String: Any],
        providerName: String,
        logRequestBody: Bool = true
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData
        DebugLogger.shared.logAPIRequest(
            endpoint: endpoint.absoluteString,
            body: logRequestBody ? String(data: bodyData, encoding: .utf8) : "包含图片的多模态请求（已省略图片数据）"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let rawString = String(data: data, encoding: .utf8) ?? "无法解码响应"

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        DebugLogger.shared.logAPIResponse(statusCode: httpResponse.statusCode, body: rawString)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.chatError("\(providerName)请求失败 (\(httpResponse.statusCode)): \(rawString.prefix(200))")
        }

        if let errorMessage = extractAPIErrorMessage(fromJSONString: rawString) {
            throw AIServiceError.chatError("\(providerName)错误：\(errorMessage)")
        }

        guard let content = extractResponseText(fromJSONString: rawString),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.chatError("\(providerName)返回为空: \(rawString.prefix(300))")
        }

        return content
    }

    private func resizeAdvisorImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largestDimension = max(image.size.width, image.size.height)
        guard largestDimension > maxDimension else { return image }

        let scale = maxDimension / largestDimension
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func extractResponseText(fromJSONString jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let choices = object["choices"] as? [[String: Any]],
           let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let content = nonEmptyText(delta["content"]) {
                    return content
                }
                if let text = nonEmptyText(delta["text"]) {
                    return text
                }
            }

            if let message = choice["message"] as? [String: Any],
               let content = nonEmptyText(message["content"]) {
                return content
            }

            if let text = nonEmptyText(choice["text"]) {
                return text
            }
        }

        if let outputText = nonEmptyText(object["output_text"]) {
            return outputText
        }
        if let reply = nonEmptyText(object["reply"]) {
            return reply
        }
        if let content = nonEmptyText(object["content"]) {
            return content
        }

        return nil
    }

    private func extractAPIErrorMessage(fromJSONString jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = object["error"] as? [String: Any] {
            return nonEmptyText(error["message"]) ?? nonEmptyText(error["code"])
        }

        if let baseResponse = object["base_resp"] as? [String: Any],
           let statusCode = baseResponse["status_code"] as? Int,
           statusCode != 0 {
            return nonEmptyText(baseResponse["status_msg"]) ?? "status_code \(statusCode)"
        }

        return nil
    }

    private func nonEmptyText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func compactChatError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.count > 120 {
            return String(message.prefix(120)) + "..."
        }
        return message
    }

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let streamingMessageId: UUID?
    let streamingContent: String
    let canDelete: Bool
    let onDelete: () -> Void

    private var isStreaming: Bool {
        message.id == streamingMessageId
    }

    private var displayContent: String {
        if message.role == "assistant" && isStreaming && !streamingContent.isEmpty {
            return streamingContent
        }
        return message.content
    }

    var body: some View {
        Group {
            if message.role == "user" {
                UserMessageBubble(content: displayContent)
            } else {
                if displayContent.isEmpty && isStreaming {
                    TypingIndicatorBubble()
                } else {
                    AIMessageBubble(content: displayContent)
                }
            }
        }
        .contextMenu {
            if !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    UIPasteboard.general.string = displayContent
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }

                ShareLink(item: displayContent) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }

            if canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }
}

struct UserMessageBubble: View {
    let content: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(content)
                .padding(12)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct AIMessageBubble: View {
    let content: String

    private var renderedContent: AttributedString {
        // Use inlineOnly to preserve newlines, handle headers manually
        var processed = content

        // Convert headers to bold with line break
        let lines = processed.components(separatedBy: "\n")
        let processedLines = lines.map { line -> String in
            if line.hasPrefix("### ") {
                return "**" + line.dropFirst(4) + "**"
            } else if line.hasPrefix("## ") {
                return "**" + line.dropFirst(3) + "**"
            } else if line.hasPrefix("# ") {
                return "**" + line.dropFirst(2) + "**"
            }
            return line
        }
        processed = processedLines.joined(separator: "\n")

        return (try? AttributedString(markdown: processed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(renderedContent)
                .padding(12)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
    }
}

struct TypingIndicatorBubble: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 4) {
                Text("🤔 让我想想")
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(dotCount % 4 > index ? 1.0 : 0.3)
                    }
                }
            }
            .padding(12)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
        .onReceive(timer) { _ in
            dotCount += 1
        }
    }
}

#Preview {
    AIAdvisorView(foodEntries: [], userGoal: nil, currentWeight: nil, weightHistory: [])
        .modelContainer(for: ChatMessage.self, inMemory: true)
}
