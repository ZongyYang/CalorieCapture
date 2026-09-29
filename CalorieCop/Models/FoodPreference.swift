import Foundation
import SwiftData

enum FoodPreferenceMatchKind: Equatable {
    case exact
    case similar
}

struct FoodPreferenceMatch {
    let preference: FoodPreference
    let kind: FoodPreferenceMatchKind
    let score: Double
}

@Model
final class FoodPreference {
    var id: UUID
    var keyword: String          // 用户输入的关键词，如 "咖啡牛奶"
    var brand: String?
    var defaultDescription: String  // 默认描述，如 "150ml全脂牛奶"
    var createdAt: Date
    var usageCount: Int          // 使用次数，用于排序
    var categoryRawValue: String?
    var energyUnitRawValue: String?

    // 具体的营养数值，用于确保一致性
    var defaultGrams: Double?
    var defaultCalories: Double?
    var defaultProtein: Double?
    var defaultCarbs: Double?
    var defaultFat: Double?

    // 标准化到每 100g / 100ml，便于按本次摄入量重新计算。
    // 这些字段保持可选，以兼容升级前已经保存的习惯。
    var caloriesPer100: Double?
    var proteinPer100: Double?
    var carbsPer100: Double?
    var fatPer100: Double?

    var category: FoodEntryCategory {
        get {
            if let categoryRawValue,
               let category = FoodEntryCategory(rawValue: categoryRawValue) {
                return category
            }

            // Recover drink units for preferences saved before category was persisted.
            return FoodEntryCategory.inferred(
                for: keyword,
                description: defaultDescription
            )
        }
        set {
            categoryRawValue = newValue.rawValue
        }
    }

    var quantityUnitSymbol: String {
        category.quantityUnitSymbol
    }

    var energyUnit: EnergyUnit {
        get {
            guard let energyUnitRawValue,
                  let unit = EnergyUnit(rawValue: energyUnitRawValue) else {
                return .kilocalorie
            }
            return unit
        }
        set {
            energyUnitRawValue = newValue.rawValue
        }
    }

    var resolvedCaloriesPer100: Double? {
        resolvedPer100(storedValue: caloriesPer100, totalValue: defaultCalories)
    }

    var resolvedProteinPer100: Double? {
        resolvedPer100(storedValue: proteinPer100, totalValue: defaultProtein)
    }

    var resolvedCarbsPer100: Double? {
        resolvedPer100(storedValue: carbsPer100, totalValue: defaultCarbs)
    }

    var resolvedFatPer100: Double? {
        resolvedPer100(storedValue: fatPer100, totalValue: defaultFat)
    }

    var hasCompleteNutritionInfo: Bool {
        let unitMacroTotal = (resolvedProteinPer100 ?? 0)
            + (resolvedCarbsPer100 ?? 0)
            + (resolvedFatPer100 ?? 0)
        let totalMacroTotal = (defaultProtein ?? 0)
            + (defaultCarbs ?? 0)
            + (defaultFat ?? 0)
        let hasCompleteUnitReference = (resolvedCaloriesPer100 ?? 0) > 0
            && resolvedProteinPer100 != nil
            && resolvedCarbsPer100 != nil
            && resolvedFatPer100 != nil
            && unitMacroTotal > 0
        let hasCompleteTotalReference = (defaultCalories ?? 0) > 0
            && defaultProtein != nil
            && defaultCarbs != nil
            && defaultFat != nil
            && totalMacroTotal > 0
        return hasCompleteUnitReference || hasCompleteTotalReference
    }

    init(
        keyword: String,
        brand: String? = nil,
        defaultDescription: String,
        category: FoodEntryCategory = .meal,
        energyUnit: EnergyUnit = .kilocalorie
    ) {
        self.id = UUID()
        self.keyword = keyword
        self.brand = Self.normalizedOptionalText(brand)
        self.defaultDescription = defaultDescription
        self.createdAt = Date()
        self.usageCount = 1
        self.categoryRawValue = category.rawValue
        self.energyUnitRawValue = energyUnit.rawValue
    }

    /// 创建带有具体营养数值的偏好
    convenience init(
        keyword: String,
        brand: String? = nil,
        grams: Double,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        category: FoodEntryCategory? = nil,
        energyUnit: EnergyUnit = .kilocalorie
    ) {
        let resolvedCategory = category ?? FoodEntryCategory.inferred(for: keyword)
        self.init(
            keyword: keyword,
            brand: brand,
            defaultDescription: "\(Int(grams))\(resolvedCategory.quantityUnitSymbol), \(Int(calories))kcal",
            category: resolvedCategory,
            energyUnit: energyUnit
        )
        self.updateNutritionReference(
            quantity: grams,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
    }

    convenience init(entry: FoodEntry) {
        self.init(
            keyword: entry.foodName,
            brand: entry.brand,
            grams: entry.grams,
            calories: entry.calories,
            protein: entry.protein,
            carbs: entry.carbohydrates,
            fat: entry.fat,
            category: entry.category,
            energyUnit: entry.energyUnit
        )
    }

    /// 保存一次实际摄入的营养数据，并换算成每 100g / 100ml 的基准值。
    func updateNutritionReference(
        quantity: Double,
        calories: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?
    ) {
        defaultGrams = quantity > 0 ? quantity : nil
        defaultCalories = calories
        defaultProtein = protein
        defaultCarbs = carbs
        defaultFat = fat

        guard quantity > 0 else { return }

        let scale = 100 / quantity
        if caloriesPer100 == nil {
            caloriesPer100 = calories.map { $0 * scale }
        }
        if proteinPer100 == nil {
            proteinPer100 = protein.map { $0 * scale }
        }
        if carbsPer100 == nil {
            carbsPer100 = carbs.map { $0 * scale }
        }
        if fatPer100 == nil {
            fatPer100 = fat.map { $0 * scale }
        }
    }

    /// 独立保存每 100g / 100ml 的营养基准，不覆盖总量数据。
    func updatePer100Nutrition(
        calories: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?
    ) {
        caloriesPer100 = calories
        proteinPer100 = protein
        carbsPer100 = carbs
        fatPer100 = fat
    }

    /// 独立保存一份总量数据；摄入量未知时可以不提供 quantity。
    func updateTotalNutrition(
        quantity: Double?,
        calories: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?
    ) {
        defaultGrams = quantity.flatMap { $0 > 0 ? $0 : nil }
        defaultCalories = calories
        defaultProtein = protein
        defaultCarbs = carbs
        defaultFat = fat
    }

    /// 生成用于 AI prompt 的详细描述
    var promptDescription: String {
        if let calories = resolvedCaloriesPer100 {
            var parts = ["每100\(quantityUnitSymbol), \(String(format: "%.1f", calories))kcal"]
            if let protein = resolvedProteinPer100 {
                parts.append("蛋白质\(String(format: "%.1f", protein))g")
            }
            if let carbs = resolvedCarbsPer100 {
                parts.append("碳水\(String(format: "%.1f", carbs))g")
            }
            if let fat = resolvedFatPer100 {
                parts.append("脂肪\(String(format: "%.1f", fat))g")
            }
            return parts.joined(separator: ", ")
        }
        return defaultDescription
    }

    private func resolvedPer100(storedValue: Double?, totalValue: Double?) -> Double? {
        if let storedValue {
            return storedValue
        }
        guard let quantity = defaultGrams, quantity > 0, let totalValue else {
            return nil
        }
        return totalValue * 100 / quantity
    }

    func updateBrand(_ value: String?) {
        brand = Self.normalizedOptionalText(value)
    }

    func matches(keyword: String, brand: String?) -> Bool {
        Self.normalizedText(self.keyword) == Self.normalizedText(keyword)
            && Self.normalizedOptionalText(self.brand) == Self.normalizedOptionalText(brand)
    }

    func similarityScore(foodName: String, brand candidateBrand: String?) -> Double {
        let savedName = Self.searchNormalizedText(keyword)
        let candidateName = Self.searchNormalizedText(foodName)
        guard savedName.count >= 2, candidateName.count >= 2 else { return 0 }

        let nameScore: Double
        if savedName == candidateName {
            nameScore = 1
        } else if savedName.contains(candidateName) || candidateName.contains(savedName) {
            let ratio = Double(min(savedName.count, candidateName.count))
                / Double(max(savedName.count, candidateName.count))
            nameScore = 0.72 + 0.23 * ratio
        } else {
            nameScore = Self.bigramSimilarity(savedName, candidateName)
        }

        guard nameScore >= 0.58 else { return 0 }

        let savedBrand = Self.normalizedOptionalText(brand)
        let comparedBrand = Self.normalizedOptionalText(candidateBrand)
        var score = nameScore
        if let savedBrand, let comparedBrand {
            if savedBrand == comparedBrand {
                score += 0.05
            } else if savedBrand.contains(comparedBrand) || comparedBrand.contains(savedBrand) {
                score += 0.02
            } else {
                score -= 0.08
            }
        }
        return min(max(score, 0), 1)
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func searchNormalizedText(_ text: String) -> String {
        normalizedText(text).filter { character in
            character.isLetter || character.isNumber
        }
    }

    private static func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsPairs = bigrams(lhs)
        let rhsPairs = bigrams(rhs)
        guard !lhsPairs.isEmpty, !rhsPairs.isEmpty else { return 0 }

        var remaining = rhsPairs
        var intersection = 0
        for pair in lhsPairs {
            if let index = remaining.firstIndex(of: pair) {
                intersection += 1
                remaining.remove(at: index)
            }
        }
        return Double(2 * intersection) / Double(lhsPairs.count + rhsPairs.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map {
            String(characters[$0...($0 + 1)])
        }
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmedText.isEmpty ? nil : trimmedText
    }
}

extension Array where Element == FoodPreference {
    func bestMatch(foodName: String, brand: String?) -> FoodPreferenceMatch? {
        if let exact = first(where: { $0.matches(keyword: foodName, brand: brand) }) {
            return FoodPreferenceMatch(preference: exact, kind: .exact, score: 1)
        }

        let candidate = compactMap { preference -> FoodPreferenceMatch? in
            let score = preference.similarityScore(foodName: foodName, brand: brand)
            guard score >= 0.62 else { return nil }
            return FoodPreferenceMatch(preference: preference, kind: .similar, score: score)
        }
        return candidate.max { $0.score < $1.score }
    }
}
