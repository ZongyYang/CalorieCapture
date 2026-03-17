import SwiftUI
import SwiftData

struct AIAdvisorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.createdAt) private var chatMessages: [ChatMessage]

    let foodEntries: [FoodEntry]
    let userGoal: UserGoal?
    let currentWeight: Double?
    let weightHistory: [WeightEntry]
    var initialPrompt: String = ""

    @State private var userQuestion = ""
    @State private var hasUsedInitialPrompt = false
    @State private var isLoading = false
    @State private var showingDeleteConfirmation = false
    @State private var sessionStartTime = Date()  // Track current session for API calls

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
            summaryLines.append("【目标】\(String(format: "%.1f", weight))kg→\(goal.targetWeight)kg, TDEE:\(Int(goal.calculateTDEE(currentWeight: weight)))kcal, 建议摄入:\(Int(goal.recommendedDailyCalories(currentWeight: weight)))kcal")
        }

        // Weight history (if needed)
        if needs.needsWeight && !weightHistory.isEmpty {
            summaryLines.append("【体重】")
            for entry in weightHistory.prefix(7) {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d"
                summaryLines.append("\(formatter.string(from: entry.date)):\(String(format: "%.1f", entry.weight))kg")
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
                            AIMessageBubble(content: "你好！我是你的AI营养顾问。我可以看到你的目标设定、体重变化和饮食记录。\n\n你可以问我：\n• 按我的计划多久能达到目标？\n• 我这周吃得健康吗？\n• 我的热量缺口够吗？\n• 有什么改善建议？")

                            ForEach(chatMessages) { message in
                                if message.role == "user" {
                                    UserMessageBubble(content: message.content)
                                        .id(message.id)
                                } else {
                                    AIMessageBubble(content: message.content)
                                        .id(message.id)
                                }
                            }

                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .padding()
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                    }
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
            .onTapGesture {
                // Dismiss keyboard when tapping outside text field
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .onAppear {
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

        do {
            let response = try await askAI(question: question)
            // Save assistant message on main thread
            await MainActor.run {
                let assistantMessage = ChatMessage(role: "assistant", content: response)
                modelContext.insert(assistantMessage)
                try? modelContext.save()
                isLoading = false
            }
        } catch {
            await MainActor.run {
                let errorMessage = ChatMessage(role: "assistant", content: "抱歉，出现了错误：\(error.localizedDescription)")
                modelContext.insert(errorMessage)
                try? modelContext.save()
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
营养顾问AI。\(currentTimeContext)

\(dynamicSummary)

规则：简洁回答，用数据支持，中文，不超过150字。用•列表，可用**粗体**。
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
            "model": "MiniMax-M2.5-highspeed",
            "messages": messages
        ]

        var request = URLRequest(url: URL(string: "https://api.minimaxi.chat/v1/text/chatcompletion_v2")!)
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

struct UserMessageBubble: View {
    let content: String

    var body: some View {
        HStack {
            Spacer()
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

    var body: some View {
        HStack(alignment: .top) {
            Text(.init(content))  // This enables markdown rendering
                .textSelection(.enabled)
                .padding(12)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }
}

#Preview {
    AIAdvisorView(foodEntries: [], userGoal: nil, currentWeight: nil, weightHistory: [])
        .modelContainer(for: ChatMessage.self, inMemory: true)
}
