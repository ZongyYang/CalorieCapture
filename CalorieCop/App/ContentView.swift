import SwiftUI

struct ContentView: View {
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
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [FoodEntry.self, UserGoal.self], inMemory: true)
}
