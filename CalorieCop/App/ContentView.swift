import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var foodEntries: [FoodEntry]
    @StateObject private var healthKitService = HealthKitService()

    private var nutritionSyncIdentifier: String {
        foodEntries
            .map {
                [
                    $0.id.uuidString,
                    String($0.calories.bitPattern),
                    String($0.protein.bitPattern),
                    String($0.carbohydrates.bitPattern),
                    String($0.fat.bitPattern),
                    String($0.createdAt.timeIntervalSinceReferenceDate.bitPattern)
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("今日", systemImage: "chart.pie.fill")
                }

            FoodInputView()
                .tabItem {
                    Label("记录", systemImage: "plus.circle.fill")
                }

            GoalsView()
                .tabItem {
                    Label("统计", systemImage: "chart.line.uptrend.xyaxis")
                }

            HistoryView()
                .tabItem {
                    Label("历史", systemImage: "calendar")
                }
        }
        .task(id: nutritionSyncIdentifier) {
            if !healthKitService.isAuthorized {
                await healthKitService.requestAuthorization()
            }
            await healthKitService.synchronizeNutrition(with: foodEntries)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self], inMemory: true)
}
