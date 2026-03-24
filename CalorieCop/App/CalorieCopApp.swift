import SwiftUI
import SwiftData

@main
struct CalorieCopApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FoodEntry.self,
            UserGoal.self,
            WeightEntry.self,
            UserSettings.self,
            ChatMessage.self,
            FoodPreference.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Migrate data from old app on first launch
                    let context = sharedModelContainer.mainContext
                    DataMigrationService.migrateIfNeeded(modelContext: context)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
