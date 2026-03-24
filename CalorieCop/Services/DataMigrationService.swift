import Foundation
import SwiftData

/// Service to migrate data from the old app (com.example.CalorieCop) to the new bundle ID
enum DataMigrationService {
    private static let migrationCompletedKey = "data_migration_completed_v1"

    static var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: migrationCompletedKey)
    }

    /// Migrates data from the bundled migration_data.json file
    /// Call this once on first launch of the new app
    static func migrateIfNeeded(modelContext: ModelContext) {
        guard !hasMigrated else { return }

        guard let url = Bundle.main.url(forResource: "migration_data", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[Migration] No migration data found")
            markMigrationCompleted()
            return
        }

        do {
            let migrationData = try JSONDecoder().decode(MigrationData.self, from: data)

            // Migrate food entries
            for entry in migrationData.foodEntries {
                let foodEntry = FoodEntry(
                    rawInput: entry.rawInput,
                    foodName: entry.foodName,
                    grams: entry.grams,
                    calories: entry.calories,
                    protein: entry.protein,
                    carbohydrates: entry.carbohydrates,
                    fat: entry.fat,
                    date: Date(timeIntervalSince1970: entry.createdAt)
                )
                modelContext.insert(foodEntry)
            }
            print("[Migration] Migrated \(migrationData.foodEntries.count) food entries")

            // Migrate food preferences
            for pref in migrationData.foodPreferences {
                let foodPref = FoodPreference(
                    keyword: pref.keyword,
                    grams: pref.defaultGrams,
                    calories: pref.defaultCalories,
                    protein: pref.defaultProtein,
                    carbs: pref.defaultCarbs,
                    fat: pref.defaultFat
                )
                foodPref.usageCount = pref.usageCount
                foodPref.createdAt = Date(timeIntervalSince1970: pref.createdAt)
                modelContext.insert(foodPref)
            }
            print("[Migration] Migrated \(migrationData.foodPreferences.count) food preferences")

            // Migrate user goal
            if let goal = migrationData.userGoal {
                let userGoal = UserGoal(
                    targetWeight: goal.targetWeight,
                    height: goal.height,
                    age: goal.age,
                    gender: goal.gender,
                    activityLevel: goal.activityLevel,
                    targetDate: Date(timeIntervalSince1970: goal.targetDate)
                )
                modelContext.insert(userGoal)
                print("[Migration] Migrated user goal")
            }

            try modelContext.save()
            markMigrationCompleted()
            print("[Migration] Migration completed successfully")

        } catch {
            print("[Migration] Error: \(error)")
            markMigrationCompleted() // Don't retry on error
        }
    }

    private static func markMigrationCompleted() {
        UserDefaults.standard.set(true, forKey: migrationCompletedKey)
    }
}

// MARK: - Migration Data Structures

private struct MigrationData: Decodable {
    let exportedAt: String
    let foodEntries: [MigrationFoodEntry]
    let foodPreferences: [MigrationFoodPreference]
    let userGoal: MigrationUserGoal?

    enum CodingKeys: String, CodingKey {
        case exportedAt = "exported_at"
        case foodEntries = "food_entries"
        case foodPreferences = "food_preferences"
        case userGoal = "user_goal"
    }
}

private struct MigrationFoodEntry: Decodable {
    let foodName: String
    let grams: Double
    let calories: Double
    let protein: Double
    let carbohydrates: Double
    let fat: Double
    let rawInput: String
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case foodName = "food_name"
        case grams, calories, protein, carbohydrates, fat
        case rawInput = "raw_input"
        case createdAt = "created_at"
    }
}

private struct MigrationFoodPreference: Decodable {
    let keyword: String
    let defaultGrams: Double
    let defaultCalories: Double
    let defaultProtein: Double
    let defaultCarbs: Double
    let defaultFat: Double
    let defaultDescription: String
    let usageCount: Int
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case keyword
        case defaultGrams = "default_grams"
        case defaultCalories = "default_calories"
        case defaultProtein = "default_protein"
        case defaultCarbs = "default_carbs"
        case defaultFat = "default_fat"
        case defaultDescription = "default_description"
        case usageCount = "usage_count"
        case createdAt = "created_at"
    }
}

private struct MigrationUserGoal: Decodable {
    let age: Int
    let height: Double
    let targetWeight: Double
    let targetDate: Double
    let activityLevel: String
    let gender: String

    enum CodingKeys: String, CodingKey {
        case age, height, gender
        case targetWeight = "target_weight"
        case targetDate = "target_date"
        case activityLevel = "activity_level"
    }
}
