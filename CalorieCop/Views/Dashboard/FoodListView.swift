import SwiftUI
import SwiftData

struct FoodListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FoodEntry.createdAt, order: .reverse)
    private var allEntries: [FoodEntry]

    @State private var entryToDelete: FoodEntry?
    @State private var showingDeleteConfirmation = false

    private var todayEntries: [FoodEntry] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return allEntries.filter { $0.createdAt >= startOfDay }
    }

    var body: some View {
        Group {
            if todayEntries.isEmpty {
                emptyState
            } else {
                foodList
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {
                entryToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let entry = entryToDelete {
                    modelContext.delete(entry)
                    entryToDelete = nil
                }
            }
        } message: {
            if let entry = entryToDelete {
                Text("确定要删除「\(entry.foodName)」吗？")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("今天还没有记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击下方按钮记录你的第一餐")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var foodList: some View {
        List {
            ForEach(todayEntries) { entry in
                FoodEntryRow(entry: entry)
                    .contextMenu {
                        Button(role: .destructive) {
                            entryToDelete = entry
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            entryToDelete = entry
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
}

struct FoodEntryRow: View {
    let entry: FoodEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.foodName)
                    .font(.headline)

                if let brand = entry.brand {
                    Text(brand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Label(entry.displayCategoryName, systemImage: entry.displayCategorySystemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(entry.grams.formattedGrams)\(entry.category.quantityUnitSymbol)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(entry.calories.formattedCalories) kcal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)

                Text(entry.createdAt.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    FoodListView()
        .modelContainer(for: FoodEntry.self, inMemory: true)
}
