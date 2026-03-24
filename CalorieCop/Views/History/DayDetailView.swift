import SwiftUI
import SwiftData

struct DayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let date: Date
    @State private var entries: [FoodEntry]
    @State private var entryToDelete: FoodEntry?
    @State private var showingDeleteConfirmation = false
    @State private var showingBackfillSheet = false

    init(date: Date, entries: [FoodEntry]) {
        self.date = date
        self._entries = State(initialValue: entries)
    }

    private var totalCalories: Double {
        entries.reduce(0) { $0 + $1.calories }
    }

    private var totalProtein: Double {
        entries.reduce(0) { $0 + $1.protein }
    }

    private var totalCarbs: Double {
        entries.reduce(0) { $0 + $1.carbohydrates }
    }

    private var totalFat: Double {
        entries.reduce(0) { $0 + $1.fat }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Summary card
                VStack(spacing: 16) {
                    Text("总摄入")
                        .font(.headline)

                    Text("\(totalCalories.formattedCalories)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.orange)

                    Text("千卡")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        NutritionCard(
                            title: "蛋白质",
                            value: totalProtein.formattedGrams,
                            unit: "g",
                            color: .red
                        )
                        NutritionCard(
                            title: "碳水",
                            value: totalCarbs.formattedGrams,
                            unit: "g",
                            color: .blue
                        )
                        NutritionCard(
                            title: "脂肪",
                            value: totalFat.formattedGrams,
                            unit: "g",
                            color: .yellow
                        )
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)

                // Food list
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("食物明细")
                            .font(.headline)
                        Spacer()
                        Text("长按可删除")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(entries.sorted { $0.createdAt < $1.createdAt }) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.foodName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(entry.grams.formattedGrams)g · \(entry.createdAt.formattedTime)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("\(entry.calories.formattedCalories) kcal")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contextMenu {
                            Button(role: .destructive) {
                                entryToDelete = entry
                                showingDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(formatDate(date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingBackfillSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                    Text("补录")
                }
            }
        }
        .sheet(isPresented: $showingBackfillSheet) {
            NavigationStack {
                FoodInputView(targetDate: date) {
                    // Refresh entries after saving
                    refreshEntries()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showingBackfillSheet = false
                        }
                    }
                }
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {
                entryToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let entry = entryToDelete {
                    deleteEntry(entry)
                }
            }
        } message: {
            if let entry = entryToDelete {
                Text("确定要删除「\(entry.foodName)」吗？此操作无法撤销。")
            }
        }
    }

    private func deleteEntry(_ entry: FoodEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        entries.removeAll { $0.id == entry.id }
        entryToDelete = nil
    }

    private func refreshEntries() {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate<FoodEntry> { entry in
                entry.createdAt >= startOfDay && entry.createdAt < endOfDay
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )

        if let fetchedEntries = try? modelContext.fetch(descriptor) {
            entries = fetchedEntries
        }
    }

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    NavigationStack {
        DayDetailView(
            date: Date(),
            entries: []
        )
    }
}
