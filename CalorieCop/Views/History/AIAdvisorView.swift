import SwiftUI
import SwiftData

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
                                    streamingContent: streamingContent
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
                HStack(spacing: 12) {
                    TextField("问问AI顾问...", text: $userQuestion, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)

                    Button {
                        Task {
                            await sendMessage()
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(userQuestion.isEmpty ? .gray : .blue)
                    }
                    .disabled(userQuestion.isEmpty || isLoading)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle("AI顾问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !chatMessages.isEmpty {
                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
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
        }
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
                try await askAIStreaming(question: userQuestion) { content in
                    Task { @MainActor in
                        streamingContent = content
                    }
                }
                await MainActor.run {
                    emptyAIMessage.content = streamingContent
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
        for message in chatMessages {
            modelContext.delete(message)
        }
        try? modelContext.save()
    }

    private func sendMessage() async {
        let question = userQuestion
        userQuestion = ""

        // Save user message
        let userMessage = ChatMessage(role: "user", content: question)
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
            try await askAIStreaming(question: question) { content in
                // Update streaming content on main thread
                Task { @MainActor in
                    streamingContent = content
                }
            }
            // Final update with complete content
            await MainActor.run {
                assistantMessage.content = streamingContent
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

    private func askAI(question: String) async throws -> String {
        guard let apiKey = APIKeyManager.miniMaxAPIKey else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let dynamicSummary = summaryForQuestion(question)

        let systemPrompt = """
你是一位亲切友好的营养小助手，像朋友一样和用户聊天。\(currentTimeContext)

\(dynamicSummary)

风格：温暖亲切，多用emoji表情😊🎉💪，像好朋友聊天。用"你"称呼用户，多鼓励夸奖。
格式：用•列表，可用**粗体**强调。禁止表格和代码块。
规则：简洁实用，用数据支持，中文，不超过150字。
"""

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // Only include messages from current session (not persisted history)
        let currentSessionMessages = chatMessages.filter { $0.createdAt >= sessionStartTime }
        for msg in currentSessionMessages {
            // Skip if this is the current question we just inserted
            if msg.role == "user" && msg.content == question {
                continue
            }
            messages.append(["role": msg.role, "content": msg.content])
        }

        // Always add the current question explicitly
        messages.append(["role": "user", "content": question])

        // Use highspeed model for faster response
        let requestBody: [String: Any] = [
            "model": "MiniMax-M2.7-highspeed",
            "messages": messages
        ]

        var request = URLRequest(url: URL(string: "https://api.minimax.io/v1/text/chatcompletion_v2")!)
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

    private func askAIStreaming(question: String, onContent: @escaping (String) -> Void) async throws {
        guard let apiKey = APIKeyManager.miniMaxAPIKey else {
            throw AIServiceError.apiKeyNotConfigured
        }

        let dynamicSummary = summaryForQuestion(question)

        let systemPrompt = """
你是一位亲切友好的营养小助手，像朋友一样和用户聊天。\(currentTimeContext)

\(dynamicSummary)

风格：温暖亲切，多用emoji表情😊🎉💪，像好朋友聊天。用"你"称呼用户，多鼓励夸奖。
格式：用•列表，可用**粗体**强调。禁止表格和代码块。
规则：简洁实用，用数据支持，中文，不超过150字。
"""

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // Only include messages from current session (not persisted history)
        let currentSessionMessages = chatMessages.filter { $0.createdAt >= sessionStartTime }
        for msg in currentSessionMessages {
            // Skip empty messages (placeholder) and current question
            if msg.content.isEmpty || (msg.role == "user" && msg.content == question) {
                continue
            }
            messages.append(["role": msg.role, "content": msg.content])
        }

        messages.append(["role": "user", "content": question])

        let requestBody: [String: Any] = [
            "model": "MiniMax-M2.7-highspeed",
            "messages": messages,
            "stream": true
        ]

        var request = URLRequest(url: URL(string: "https://api.minimax.io/v1/text/chatcompletion_v2")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AIServiceError.parsingError("HTTP错误")
        }

        var accumulatedContent = ""

        for try await line in bytes.lines {
            // SSE format: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            // Skip [DONE] marker
            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8) else { continue }

            struct StreamChunk: Decodable {
                let choices: [Choice]?
                struct Choice: Decodable {
                    let delta: Delta
                    struct Delta: Decodable {
                        let content: String?
                    }
                }
            }

            if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: jsonData),
               let content = chunk.choices?.first?.delta.content,
               !content.isEmpty {
                accumulatedContent += content
                onContent(accumulatedContent)
            }
        }
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

    var body: some View {
        if message.role == "user" {
            UserMessageBubble(content: message.content)
        } else {
            let isStreaming = message.id == streamingMessageId
            let displayContent = (isStreaming && !streamingContent.isEmpty)
                ? streamingContent
                : message.content

            if displayContent.isEmpty && isStreaming {
                TypingIndicatorBubble()
            } else {
                AIMessageBubble(content: displayContent)
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
                .textSelection(.enabled)
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
                .textSelection(.enabled)
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
