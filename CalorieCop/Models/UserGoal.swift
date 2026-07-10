import Foundation
import SwiftData

@Model
final class UserGoal {
    var id: UUID
    var targetWeight: Double          // kg
    var targetDate: Date?             // optional target date
    var height: Double                // cm
    var age: Int
    var gender: String                // "male" or "female"
    var activityLevel: String         // "sedentary", "light", "moderate", "active", "very_active"
    var dailyCalorieDeficit: Double?  // User-defined daily calorie deficit
    var createdAt: Date
    var updatedAt: Date

    init(
        targetWeight: Double,
        height: Double,
        age: Int,
        gender: String,
        activityLevel: String,
        targetDate: Date? = nil,
        dailyCalorieDeficit: Double? = nil
    ) {
        self.id = UUID()
        self.targetWeight = targetWeight
        self.height = height
        self.age = age
        self.gender = gender
        self.activityLevel = activityLevel
        self.targetDate = targetDate
        self.dailyCalorieDeficit = dailyCalorieDeficit
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Calculate BMR using Mifflin-St Jeor equation
    func calculateBMR(currentWeight: Double) -> Double {
        if gender == "male" {
            return 10 * currentWeight + 6.25 * height - 5 * Double(age) + 5
        } else {
            return 10 * currentWeight + 6.25 * height - 5 * Double(age) - 161
        }
    }

    // Activity multiplier
    var activityMultiplier: Double {
        switch activityLevel {
        case "sedentary": return 1.2
        case "light": return 1.375
        case "moderate": return 1.55
        case "active": return 1.725
        case "very_active": return 1.9
        default: return 1.2
        }
    }

    // Calculate TDEE (Total Daily Energy Expenditure)
    func calculateTDEE(currentWeight: Double) -> Double {
        return calculateBMR(currentWeight: currentWeight) * activityMultiplier
    }

    func automaticDailyDeficit(currentWeight: Double) -> Double {
        let weightToLose = currentWeight - targetWeight

        if weightToLose <= 0 {
            return 0
        }

        // Calculate deficit based on target date or default 0.5kg/week
        var dailyDeficit: Double = 500 // default

        if let targetDate = targetDate {
            let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: targetDate).day ?? 1
            if daysRemaining > 0 {
                // 7700 kcal ≈ 1 kg of fat
                dailyDeficit = (weightToLose * 7700) / Double(daysRemaining)
                // Cap at 1000 kcal deficit for safety
                dailyDeficit = min(dailyDeficit, 1000)
            }
        }

        return dailyDeficit
    }

    func plannedDailyDeficit(currentWeight: Double) -> Double {
        if let dailyCalorieDeficit {
            return max(dailyCalorieDeficit, 0)
        }
        return automaticDailyDeficit(currentWeight: currentWeight)
    }

    // Calculate recommended daily calories for weight loss.
    // If HealthKit average expenditure is available, use it instead of formula TDEE.
    func recommendedDailyCalories(currentWeight: Double, dailyEnergyExpenditure: Double? = nil) -> Double {
        let expenditure = dailyEnergyExpenditure ?? calculateTDEE(currentWeight: currentWeight)
        let dailyDeficit = plannedDailyDeficit(currentWeight: currentWeight)

        // Minimum 1200 kcal for safety
        return max(expenditure - dailyDeficit, 1200)
    }
}
