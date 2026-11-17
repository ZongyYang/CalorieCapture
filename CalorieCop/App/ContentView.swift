import SwiftUI
import SwiftData
import WidgetKit

extension Notification.Name {
    static let focusFoodRecordSearch = Notification.Name("focusFoodRecordSearch")
    static let openFoodRecordCamera = Notification.Name("openFoodRecordCamera")
    static let openFoodRecordPhotoLibrary = Notification.Name("openFoodRecordPhotoLibrary")
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var foodEntries: [FoodEntry]
    @StateObject private var healthKitService = HealthKitService()
    @State private var selectedTab = 0

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
        TabView(selection: $selectedTab) {
            DashboardView()
                .tag(0)
                .tabItem {
                    Label("今日", systemImage: "chart.pie.fill")
                }

            FoodInputView()
                .tag(1)
                .tabItem {
                    Label("记录", systemImage: "plus.circle.fill")
                }

            GoalsView()
                .tag(2)
                .tabItem {
                    Label("统计", systemImage: "chart.line.uptrend.xyaxis")
                }

            HistoryView()
                .tag(3)
                .tabItem {
                    Label("历史", systemImage: "calendar")
                }
        }
        .task(id: nutritionSyncIdentifier) {
            await synchronizeHealthKitAndReloadWidgets()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await healthKitService.fetchTodayCaloriesBurned()
                    await synchronizeHealthKitAndReloadWidgets()
                }
            case .background:
                // When the user returns from the app to the Home Screen, ask
                // WidgetKit for a fresh timeline based on this session's data.
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
        .onOpenURL { url in
            guard url.scheme == "caloriecapture", url.host == "record" else { return }

            selectedTab = 1
            Task {
                await synchronizeHealthKitAndReloadWidgets()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "mode" })?
                    .value

                switch mode {
                case "camera":
                    NotificationCenter.default.post(name: .openFoodRecordCamera, object: nil)
                case "photo":
                    NotificationCenter.default.post(name: .openFoodRecordPhotoLibrary, object: nil)
                default:
                    NotificationCenter.default.post(name: .focusFoodRecordSearch, object: nil)
                }
            }
        }
    }

    private func synchronizeHealthKitAndReloadWidgets() async {
        if !healthKitService.isAuthorized {
            await healthKitService.requestAuthorization()
        }
        await healthKitService.synchronizeNutrition(with: foodEntries)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self], inMemory: true)
}
