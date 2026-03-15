import Foundation

enum FoodParsingPrompt {
    static let basePrompt = """
你是一个专业的营养分析师。用户会用自然语言描述他们吃的食物，请解析并返回JSON格式的营养信息。

规则：
1. 如果用户没有指定克重，根据常识估算合理份量
2. 营养数据基于中国常见食物数据库
3. 如果食物描述模糊，选择最常见的理解方式
4. 所有数值保留1位小数
5. 注意识别时间描述：
   - "昨天"、"昨晚" = days_ago: 1
   - "前天" = days_ago: 2
   - "今天"、"刚才"、"刚刚" 或没有时间描述 = days_ago: 0
   - "上周X" = 计算距今天数
   - "X天前" = days_ago: X

【重要 - 多食物支持】
用户可能同时输入多种食物（用逗号、顿号、空格或换行分隔）。
- 如果输入包含多种食物，返回 JSON 数组
- 如果只有一种食物，也返回 JSON 数组（只有一个元素）

【必须返回严格的JSON数组格式】
单个食物示例：
[{"food_name": "煮玉米", "grams": 200, "calories": 196, "protein": 4.2, "carbohydrates": 41.2, "fat": 2.4, "confidence": "high", "notes": "一根中等大小", "days_ago": 0}]

多个食物示例：
[
  {"food_name": "咖啡牛奶", "grams": 300, "calories": 120, "protein": 6.0, "carbohydrates": 12.0, "fat": 5.0, "confidence": "high", "notes": "", "days_ago": 0},
  {"food_name": "鸡蛋", "grams": 50, "calories": 72, "protein": 6.3, "carbohydrates": 0.6, "fat": 5.0, "confidence": "high", "notes": "一个中等大小", "days_ago": 0},
  {"food_name": "黄瓜", "grams": 100, "calories": 16, "protein": 0.7, "carbohydrates": 2.9, "fat": 0.2, "confidence": "high", "notes": "", "days_ago": 0}
]

字段说明：
- food_name: 食物名称（中文字符串）
- grams: 克重（数字）
- calories: 卡路里（数字）
- protein: 蛋白质克数（数字）
- carbohydrates: 碳水化合物克数（数字）
- fat: 脂肪克数（数字）
- confidence: "high"/"medium"/"low"
- notes: 可选备注
- days_ago: 距今天数（0=今天，1=昨天）
"""

    /// Generate system prompt with user's food preferences
    static func systemPrompt(with preferences: [FoodPreference] = []) -> String {
        var prompt = basePrompt

        if !preferences.isEmpty {
            prompt += "\n\n【用户的食物习惯 - 重要！必须严格遵循】\n"
            prompt += "以下是用户的个人食物偏好设定。当用户提到这些关键词时，**必须**使用以下精确数值，不要估算：\n"

            for pref in preferences {
                prompt += "- \"\(pref.keyword)\" → \(pref.promptDescription)\n"
            }

            prompt += "\n**关键规则**：\n"
            prompt += "1. 如果用户输入匹配上述关键词，必须使用预设的精确数值\n"
            prompt += "2. 只有当用户明确指定了不同的份量时，才使用用户指定的数值\n"
            prompt += "3. 这些数值是用户反复确认过的，不要自行调整"
        }

        return prompt
    }

    // Keep backward compatibility
    static var systemPrompt: String {
        basePrompt
    }
}
