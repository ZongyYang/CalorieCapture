import HealthKit
import SwiftUI
import WidgetKit

private let quickActionsWidgetKind = "CalorieCaptureSummaryWidget"
private let metricsOnlyWidgetKind = "CalorieCaptureMetricsWidget"
private let foodEntryIDMetadataKey = "com.zyyang116.caloriecapture.foodEntryID"
private let lastSuccessfulSnapshotKey = "CalorieCaptureWidget.lastSuccessfulSnapshot.v1"
private let widgetRefreshInterval: TimeInterval = 15 * 60

private struct CalorieSummaryEntry: TimelineEntry {
    let date: Date
    let intake: Double
    let burned: Double

    var gap: Double {
        burned - intake
    }

    static let preview = CalorieSummaryEntry(
        date: .now,
        intake: 1_328,
        burned: 1_890
    )
}

private struct CalorieSummarySnapshot: Codable {
    let date: Date
    let intake: Double
    let burned: Double

    var entry: CalorieSummaryEntry {
        // Keep the cached values visible immediately, even when the snapshot
        // was created on a previous day and HealthKit is temporarily unavailable.
        CalorieSummaryEntry(date: .now, intake: intake, burned: burned)
    }
}

private struct CalorieMetricsLayout {
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 10
    var verticalOffset: CGFloat = 4
    var titleSpacing: CGFloat = 16
    var rowSpacing: CGFloat = 1
    var rowHeight: CGFloat = 28
}

private struct CalorieSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalorieSummaryEntry {
        .preview
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (CalorieSummaryEntry) -> Void
    ) {
        if context.isPreview {
            completion(.preview)
            return
        }

        Task {
            completion(await loadCurrentEntry())
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<CalorieSummaryEntry>) -> Void
    ) {
        Task {
            let entry = await loadCurrentEntry()
            // WidgetKit may defer refreshes to respect its budget, but a short
            // policy interval keeps the widget from remaining stale for hours.
            let nextRefresh = Date().addingTimeInterval(widgetRefreshInterval)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func loadCurrentEntry() async -> CalorieSummaryEntry {
        guard HKHealthStore.isHealthDataAvailable() else {
            return cachedEntry() ?? fallbackEntry
        }

        let healthStore = HKHealthStore()
        // HealthKit may briefly fail while the app or Apple Watch is syncing.
        // Retry once before falling back to the last successful read.
        if let entry = await readCurrentEntry(from: healthStore) {
            saveSnapshot(for: entry)
            return entry
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        if let entry = await readCurrentEntry(from: healthStore) {
            saveSnapshot(for: entry)
            return entry
        }

        return cachedEntry() ?? fallbackEntry
    }

    private func readCurrentEntry(from healthStore: HKHealthStore) async -> CalorieSummaryEntry? {
        async let intake = fetchCalorieCaptureIntake(from: healthStore)
        async let active = fetchEnergy(.activeEnergyBurned, from: healthStore)
        async let resting = fetchEnergy(.basalEnergyBurned, from: healthStore)

        let (intakeValue, activeValue, restingValue) = await (intake, active, resting)
        let cached = cachedEntry()

        // A temporary failure in one HealthKit query should not discard a
        // successful result from the other queries or replace the widget with
        // zeros. Keep the last known value only for the failed component.
        guard intakeValue != nil || activeValue != nil || restingValue != nil else {
            return nil
        }

        let burnedValue: Double
        if let activeValue, let restingValue {
            burnedValue = activeValue + restingValue
        } else {
            burnedValue = cached?.burned ?? 0
        }

        let entry = CalorieSummaryEntry(
            date: .now,
            intake: intakeValue ?? cached?.intake ?? 0,
            burned: burnedValue
        )

#if targetEnvironment(simulator)
        if entry.intake == 0, entry.burned == 0 {
            return .preview
        }
#endif
        return entry
    }

    private func saveSnapshot(for entry: CalorieSummaryEntry) {
#if targetEnvironment(simulator)
        guard entry.intake != CalorieSummaryEntry.preview.intake
                || entry.burned != CalorieSummaryEntry.preview.burned else {
            return
        }
#endif
        let snapshot = CalorieSummarySnapshot(
            date: entry.date,
            intake: entry.intake,
            burned: entry.burned
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: lastSuccessfulSnapshotKey)
    }

    private func cachedEntry() -> CalorieSummaryEntry? {
        guard let data = UserDefaults.standard.data(forKey: lastSuccessfulSnapshotKey),
              let snapshot = try? JSONDecoder().decode(CalorieSummarySnapshot.self, from: data) else {
            return nil
        }
        return snapshot.entry
    }

    private var fallbackEntry: CalorieSummaryEntry {
#if targetEnvironment(simulator)
        return .preview
#else
        return CalorieSummaryEntry(date: .now, intake: 0, burned: 0)
#endif
    }

    private func fetchEnergy(
        _ identifier: HKQuantityTypeIdentifier,
        from healthStore: HKHealthStore
    ) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: todayPredicate,
                options: .cumulativeSum
            ) { _, result, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let value = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func fetchCalorieCaptureIntake(from healthStore: HKHealthStore) async -> Double? {
        let quantityType = HKQuantityType(.dietaryEnergyConsumed)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
            sampleType: quantityType,
            predicate: todayPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
            ) { _, samples, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let total = (samples as? [HKQuantitySample])?
                    .filter { $0.metadata?[foodEntryIDMetadataKey] != nil }
                    .reduce(0) {
                        $0 + $1.quantity.doubleValue(for: .kilocalorie())
                    } ?? 0
                continuation.resume(returning: total)
            }
            healthStore.execute(query)
        }
    }

    private var todayPredicate: NSPredicate {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: .now,
            options: []
        )
    }
}

private struct CalorieCaptureWidgetView: View {
    let entry: CalorieSummaryEntry

    private var gapColor: Color {
        entry.gap >= 0 ? .green : .red
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                metricRow(
                    title: "摄入",
                    value: entry.intake,
                    color: .orange,
                    systemImage: "fork.knife"
                )
                Divider()
                metricRow(
                    title: "消耗",
                    value: entry.burned,
                    color: .red,
                    systemImage: "flame.fill"
                )
                Divider()
                metricRow(
                    title: "缺口",
                    value: entry.gap,
                    color: gapColor,
                    systemImage: entry.gap >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                )
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 0) {
                quickAction(
                    systemImage: "plus",
                    accessibilityLabel: "输入食物",
                    destination: "caloriecapture://record?mode=text"
                )
                quickAction(
                    systemImage: "camera.fill",
                    accessibilityLabel: "拍照记录食物",
                    destination: "caloriecapture://record?mode=camera"
                )
                quickAction(
                    systemImage: "photo.fill",
                    accessibilityLabel: "从相册记录食物",
                    destination: "caloriecapture://record?mode=photo"
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            Color(uiColor: .secondarySystemBackground)
        }
        // Tapping any area other than the three dedicated quick actions opens
        // the app, which synchronizes data before the widget is refreshed.
        .widgetURL(URL(string: "caloriecapture://record?mode=text"))
    }

    private func quickAction(
        systemImage: String,
        accessibilityLabel: String,
        destination: String
    ) -> some View {
        Link(destination: URL(string: destination)!) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func metricRow(
        title: String,
        value: Double,
        color: Color,
        systemImage: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.formatted(.number.grouping(.never).precision(.fractionLength(0))))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .monospacedDigit()
                Text("kcal")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 24)
    }
}

private struct CalorieMetricsOnlyWidgetView: View {
    let entry: CalorieSummaryEntry
    var layout = CalorieMetricsLayout()

    private var gapColor: Color {
        entry.gap >= 0 ? .green : .red
    }

    var body: some View {
        VStack(spacing: layout.titleSpacing) {
            HStack(spacing: 7) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("今日热量")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }

            VStack(spacing: layout.rowSpacing) {
                metricRow(
                    title: "摄入",
                    value: entry.intake,
                    color: .orange,
                    systemImage: "fork.knife"
                )
                metricRow(
                    title: "消耗",
                    value: entry.burned,
                    color: .red,
                    systemImage: "flame.fill"
                )
                metricRow(
                    title: "缺口",
                    value: entry.gap,
                    color: gapColor,
                    systemImage: entry.gap >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                )
            }
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: layout.verticalOffset)
        .containerBackground(for: .widget) {
            Color(uiColor: .secondarySystemBackground)
        }
        .widgetURL(URL(string: "caloriecapture://record?mode=text"))
    }

    private func metricRow(
        title: String,
        value: Double,
        color: Color,
        systemImage: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.formatted(.number.grouping(.never).precision(.fractionLength(0))))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .monospacedDigit()
                Text("kcal")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: layout.rowHeight)
    }
}

struct CalorieCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: quickActionsWidgetKind, provider: CalorieSummaryProvider()) { entry in
            CalorieCaptureWidgetView(entry: entry)
        }
        .configurationDisplayName("今日热量")
        .description("查看今日摄入、消耗和热量缺口，并快速记录食物。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct CalorieMetricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: metricsOnlyWidgetKind, provider: CalorieSummaryProvider()) { entry in
            CalorieMetricsOnlyWidgetView(entry: entry)
        }
        .configurationDisplayName("热量概览")
        .description("仅显示今日摄入、消耗和热量缺口。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

@main
struct CalorieCaptureWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalorieCaptureWidget()
        CalorieMetricsWidget()
    }
}

#Preview("今日热量", as: .systemSmall) {
    CalorieCaptureWidget()
} timeline: {
    CalorieSummaryEntry.preview
}

#Preview("热量概览", as: .systemSmall) {
    CalorieMetricsWidget()
} timeline: {
    CalorieSummaryEntry.preview
}
