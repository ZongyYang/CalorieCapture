import Foundation
import SwiftData

enum FoodEntryCategory: String, CaseIterable, Identifiable, Codable {
    case meal = "正餐"
    case drink = "饮品"
    case other = "其他"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .meal:
            return "fork.knife"
        case .drink:
            return "cup.and.saucer.fill"
        case .other:
            return "square.grid.2x2.fill"
        }
    }

    var quantityUnitSymbol: String {
        switch self {
        case .drink:
            return "ml"
        case .meal, .other:
            return "g"
        }
    }

    static func inferred(for foodName: String, description: String = "") -> FoodEntryCategory {
        if description.localizedCaseInsensitiveContains("ml") {
            return .drink
        }

        let normalizedName = foodName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let drinkKeywords = [
            "豆浆", "牛奶", "奶茶", "咖啡", "拿铁", "美式", "果汁", "饮料", "饮品",
            "汽水", "可乐", "苏打水", "气泡水", "矿泉水", "纯净水", "椰子水", "柠檬水",
            "蜂蜜水", "绿茶", "红茶", "乌龙茶", "普洱茶", "花茶", "啤酒", "红酒",
            "白酒", "鸡尾酒", "酸奶", "乳饮"
        ]
        return drinkKeywords.contains(where: normalizedName.contains) ? .drink : .meal
    }
}

enum FoodMealType: String, CaseIterable, Identifiable, Codable {
    case breakfast = "早餐"
    case lunch = "午餐"
    case dinner = "晚餐"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .breakfast:
            return "sunrise.fill"
        case .lunch:
            return "sun.max.fill"
        case .dinner:
            return "moon.stars.fill"
        }
    }

    static func defaultType(for date: Date = Date()) -> FoodMealType {
        let hour = Calendar.current.component(.hour, from: date)

        if hour < 11 {
            return .breakfast
        } else if hour < 17 {
            return .lunch
        } else {
            return .dinner
        }
    }
}

@Model
final class FoodEntry {
    var id: UUID
    var rawInput: String
    var foodName: String
    var brand: String?
    var grams: Double
    var calories: Double
    var protein: Double
    var carbohydrates: Double
    var fat: Double
    var createdAt: Date
    var categoryRawValue: String?
    var mealTypeRawValue: String?
    var energyUnitRawValue: String?
    var nutritionEstimatedByAI: Bool?

    var category: FoodEntryCategory {
        get {
            guard let categoryRawValue,
                  let category = FoodEntryCategory(rawValue: categoryRawValue) else {
                return .meal
            }
            return category
        }
        set {
            categoryRawValue = newValue.rawValue
        }
    }

    var mealType: FoodMealType? {
        get {
            guard category == .meal,
                  let mealTypeRawValue,
                  let mealType = FoodMealType(rawValue: mealTypeRawValue) else {
                return nil
            }
            return mealType
        }
        set {
            mealTypeRawValue = category == .meal ? newValue?.rawValue : nil
        }
    }

    var displayCategoryName: String {
        if category == .meal, let mealType {
            return mealType.rawValue
        }
        return category.rawValue
    }

    var displayCategorySystemImage: String {
        if category == .meal, let mealType {
            return mealType.systemImage
        }
        return category.systemImage
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

    var displayedEnergy: Double {
        energyUnit.fromKilocalories(calories)
    }

    var isNutritionMissing: Bool {
        protein <= 0 && carbohydrates <= 0 && fat <= 0
    }

    var hasCompleteNutritionInfo: Bool {
        if nutritionEstimatedByAI == true {
            return true
        }
        return calories > 0 && protein > 0 && carbohydrates > 0 && fat > 0
    }

    init(rawInput: String, foodName: String, brand: String? = nil, grams: Double,
         calories: Double, protein: Double, carbohydrates: Double, fat: Double,
         date: Date = Date(), category: FoodEntryCategory = .meal, mealType: FoodMealType? = nil,
         energyUnit: EnergyUnit = .kilocalorie, nutritionEstimatedByAI: Bool = false) {
        self.id = UUID()
        self.rawInput = rawInput
        self.foodName = foodName
        self.brand = Self.normalizedOptionalText(brand)
        self.grams = grams
        self.calories = calories
        self.protein = protein
        self.carbohydrates = carbohydrates
        self.fat = fat
        self.createdAt = date
        self.categoryRawValue = category.rawValue
        self.mealTypeRawValue = category == .meal ? mealType?.rawValue : nil
        self.energyUnitRawValue = energyUnit.rawValue
        self.nutritionEstimatedByAI = nutritionEstimatedByAI
    }

    convenience init(rawInput: String, nutrition: NutritionInfo) {
        self.init(
            rawInput: rawInput,
            foodName: nutrition.foodName,
            brand: nutrition.brand,
            grams: nutrition.grams,
            calories: nutrition.calories,
            protein: nutrition.protein,
            carbohydrates: nutrition.carbohydrates,
            fat: nutrition.fat,
            date: nutrition.entryDate
        )
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedText.isEmpty ? nil : trimmedText
    }
}
