import Foundation
import HealthKit

struct WeightRecord: Identifiable {
    let id = UUID()
    let date: Date
    let weight: Double // kg
}

struct DailyEnergyBurned: Identifiable {
    let date: Date
    let activeCalories: Double
    let restingCalories: Double

    var id: Date { date }
    var totalCalories: Double { activeCalories + restingCalories }
}

@MainActor
final class HealthKitService: ObservableObject {
    private static let foodEntryIDMetadataKey = "com.zyyang116.caloriecapture.foodEntryID"
    private static let nutritionSyncStateKey = "healthkit.nutrition.syncState.v2"
    private static var authorizationTask: Task<Void, Error>?

    private enum NutritionSyncKind: String, CaseIterable {
        case energy
        case protein
        case carbohydrates
        case fat

        var type: HKQuantityType {
            switch self {
            case .energy:
                return HKQuantityType(.dietaryEnergyConsumed)
            case .protein:
                return HKQuantityType(.dietaryProtein)
            case .carbohydrates:
                return HKQuantityType(.dietaryCarbohydrates)
            case .fat:
                return HKQuantityType(.dietaryFatTotal)
            }
        }

        var unit: HKUnit {
            switch self {
            case .energy:
                return .kilocalorie()
            case .protein, .carbohydrates, .fat:
                return .gram()
            }
        }

        func amount(for entry: FoodEntry) -> Double {
            switch self {
            case .energy:
                return entry.calories
            case .protein:
                return entry.protein
            case .carbohydrates:
                return entry.carbohydrates
            case .fat:
                return entry.fat
            }
        }
    }

    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var activeCaloriesBurned: Double = 0
    @Published var basalCaloriesBurned: Double = 0
    @Published var authorizationError: String?
    @Published var currentWeight: Double?
    @Published var weightHistory: [WeightRecord] = []
    @Published var dailyEnergyBurned: [Date: DailyEnergyBurned] = [:]
    @Published var recentAverageCaloriesBurned: Double?
    @Published var recentAverageCaloriesBurnedDays: Int = 0

    var totalCaloriesBurned: Double {
        activeCaloriesBurned + basalCaloriesBurned
    }

    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async {
        guard isHealthKitAvailable else {
            authorizationError = "HealthKit is not available on this device."
            return
        }

        let nutritionTypes = NutritionSyncKind.allCases.map(\.type)
        var typesToRead: Set<HKObjectType> = [
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.bodyMass)
        ]
        typesToRead.formUnion(nutritionTypes.map { $0 as HKObjectType })
        let typesToShare = Set(nutritionTypes.map { $0 as HKSampleType })

        let authorizationTask: Task<Void, Error>
        if let existingTask = Self.authorizationTask {
            authorizationTask = existingTask
        } else {
            let newTask = Task {
                try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
            }
            Self.authorizationTask = newTask
            authorizationTask = newTask
        }

        do {
            try await authorizationTask.value
            isAuthorized = true
            await fetchTodayCaloriesBurned()
            await fetchWeightHistory()
        } catch {
            Self.authorizationTask = nil
            authorizationError = "Failed to authorize HealthKit: \(error.localizedDescription)"
        }
    }

    // MARK: - Nutrition Sync

    /// Keeps CalorieCop entries and HealthKit nutrition samples in sync. Each entry
    /// owns one sample per nutrient, identified by private metadata. This allows
    /// edits and deletions without touching nutrition data written by other apps.
    func synchronizeNutrition(with entries: [FoodEntry]) async {
        guard isHealthKitAvailable else { return }

        var syncState = UserDefaults.standard.dictionary(forKey: Self.nutritionSyncStateKey) as? [String: String] ?? [:]
        let currentEntryIDs = Set(entries.map { $0.id.uuidString })

        for kind in NutritionSyncKind.allCases {
            guard !Task.isCancelled,
                  healthStore.authorizationStatus(for: kind.type) == .sharingAuthorized else {
                continue
            }

            let deletedStateKeys = syncState.keys.filter { stateKey in
                let components = stateKey.split(separator: "|", maxSplits: 1).map(String.init)
                return components.count == 2
                    && components[1] == kind.rawValue
                    && !currentEntryIDs.contains(components[0])
            }
            let pendingEntries = entries.filter { entry in
                let entryID = entry.id.uuidString
                let amount = kind.amount(for: entry)
                let stateKey = "\(entryID)|\(kind.rawValue)"
                let signature = nutritionSignature(amount: amount, date: entry.createdAt)
                return syncState[stateKey] != signature
            }

            let pendingEntryIDs = pendingEntries.map { $0.id.uuidString }
            let deletedEntryIDs = deletedStateKeys.compactMap {
                $0.split(separator: "|", maxSplits: 1).first.map(String.init)
            }
            let entryIDsToReplace = Set(pendingEntryIDs + deletedEntryIDs)

            guard !entryIDsToReplace.isEmpty else { continue }

            do {
                try await deleteNutritionSamples(forEntryIDs: entryIDsToReplace, type: kind.type)

                let samples: [HKObject] = pendingEntries.compactMap { entry in
                    let amount = kind.amount(for: entry)
                    guard amount > 0 else { return nil }

                    return HKQuantitySample(
                        type: kind.type,
                        quantity: HKQuantity(unit: kind.unit, doubleValue: amount),
                        start: entry.createdAt,
                        end: entry.createdAt,
                        metadata: [Self.foodEntryIDMetadataKey: entry.id.uuidString]
                    )
                }
                try await saveHealthKitObjects(samples)

                deletedStateKeys.forEach { syncState.removeValue(forKey: $0) }
                for entry in pendingEntries {
                    let amount = kind.amount(for: entry)
                    let stateKey = "\(entry.id.uuidString)|\(kind.rawValue)"
                    syncState[stateKey] = nutritionSignature(amount: amount, date: entry.createdAt)
                }
                persistNutritionSyncState(syncState)
            } catch {
                authorizationError = "无法将营养摄入同步到健康 App：\(error.localizedDescription)"
            }
        }
    }

    private func nutritionSignature(amount: Double, date: Date) -> String {
        "\(amount.bitPattern):\(date.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private func persistNutritionSyncState(_ syncState: [String: String]) {
        UserDefaults.standard.set(syncState, forKey: Self.nutritionSyncStateKey)
    }

    private func deleteNutritionSamples(
        forEntryIDs entryIDs: Set<String>,
        type: HKQuantityType
    ) async throws {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: Self.foodEntryIDMetadataKey,
            allowedValues: Array(entryIDs)
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.deleteObjects(of: type, predicate: predicate) { success, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.deleteFailed)
                }
            }
        }
    }

    private func saveHealthKitObjects(_ objects: [HKObject]) async throws {
        guard !objects.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(objects) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.saveFailed)
                }
            }
        }
    }

    func fetchTodayCaloriesBurned() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.fetchActiveCalories()
            }
            group.addTask {
                await self.fetchBasalCalories()
            }
        }
    }

    private func fetchActiveCalories() async {
        let calories = await fetchCalories(for: .activeEnergyBurned)
        activeCaloriesBurned = calories
    }

    private func fetchBasalCalories() async {
        let calories = await fetchCalories(for: .basalEnergyBurned)
        basalCaloriesBurned = calories
    }

    private func fetchCalories(for identifier: HKQuantityTypeIdentifier) async -> Double {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return 0
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        // Energy samples may span midnight. strictStartDate drops samples that
        // overlap this day but started before 00:00, which can undercount
        // Health App resting energy totals.
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: [])

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let sum = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: sum)
            }
            healthStore.execute(query)
        }
    }

    func fetchDailyCaloriesBurned(from startDate: Date, to endDate: Date = Date()) async {
        async let activeByDay = fetchDailyCalories(for: .activeEnergyBurned, from: startDate, to: endDate)
        async let restingByDay = fetchDailyCalories(for: .basalEnergyBurned, from: startDate, to: endDate)

        let (activeCaloriesByDay, restingCaloriesByDay) = await (activeByDay, restingByDay)
        let days = Set(activeCaloriesByDay.keys).union(restingCaloriesByDay.keys)

        dailyEnergyBurned = Dictionary(uniqueKeysWithValues: days.map { day in
            let record = DailyEnergyBurned(
                date: day,
                activeCalories: activeCaloriesByDay[day] ?? 0,
                restingCalories: restingCaloriesByDay[day] ?? 0
            )
            return (day, record)
        })
    }

    func fetchRecentAverageCaloriesBurned(days: Int = 14) async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDay = calendar.date(byAdding: .day, value: -1, to: today) else {
            recentAverageCaloriesBurned = nil
            recentAverageCaloriesBurnedDays = 0
            return
        }

        let requestedDays = max(days, 1)
        let startDay = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: endDay) ?? endDay

        async let activeByDay = fetchDailyCalories(for: .activeEnergyBurned, from: startDay, to: endDay)
        async let restingByDay = fetchDailyCalories(for: .basalEnergyBurned, from: startDay, to: endDay)

        let (activeCaloriesByDay, restingCaloriesByDay) = await (activeByDay, restingByDay)
        let daysWithData = Set(activeCaloriesByDay.keys)
            .union(restingCaloriesByDay.keys)
            .filter { $0 >= startDay && $0 <= endDay }
            .sorted()

        let totals = daysWithData.compactMap { day -> Double? in
            let total = (activeCaloriesByDay[day] ?? 0) + (restingCaloriesByDay[day] ?? 0)
            return total > 0 ? total : nil
        }

        guard !totals.isEmpty else {
            recentAverageCaloriesBurned = nil
            recentAverageCaloriesBurnedDays = 0
            return
        }

        recentAverageCaloriesBurned = totals.reduce(0, +) / Double(totals.count)
        recentAverageCaloriesBurnedDays = totals.count
    }

    func fetchCaloriesBurned(for date: Date) async -> DailyEnergyBurned? {
        async let activeByDay = fetchDailyCalories(for: .activeEnergyBurned, from: date, to: date)
        async let restingByDay = fetchDailyCalories(for: .basalEnergyBurned, from: date, to: date)

        let day = Calendar.current.startOfDay(for: date)
        let (activeCaloriesByDay, restingCaloriesByDay) = await (activeByDay, restingByDay)
        let activeCalories = activeCaloriesByDay[day] ?? 0
        let restingCalories = restingCaloriesByDay[day] ?? 0

        guard activeCalories + restingCalories > 0 else {
            return nil
        }

        return DailyEnergyBurned(
            date: day,
            activeCalories: activeCalories,
            restingCalories: restingCalories
        )
    }

    private func fetchDailyCalories(
        for identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async -> [Date: Double] {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return [:]
        }

        let calendar = Calendar.current
        let startOfRange = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let endOfRange = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDate
        // Match Health App day totals more closely by including samples that
        // overlap the requested day range, including midnight-spanning samples.
        let predicate = HKQuery.predicateForSamples(withStart: startOfRange, end: endOfRange, options: [])

        return await withCheckedContinuation { continuation in
            var interval = DateComponents()
            interval.day = 1

            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startOfRange,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, _ in
                var caloriesByDay: [Date: Double] = [:]

                results?.enumerateStatistics(from: startOfRange, to: endOfRange) { statistics, _ in
                    let calories = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    if calories > 0 {
                        let day = calendar.startOfDay(for: statistics.startDate)
                        caloriesByDay[day] = calories
                    }
                }

                continuation.resume(returning: caloriesByDay)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Weight Data

    func fetchWeightHistory(days: Int = 90) async {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            return
        }

        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { [weak self] _, samples, _ in
                Task { @MainActor in
                    guard let samples = samples as? [HKQuantitySample] else {
                        continuation.resume()
                        return
                    }

                    self?.weightHistory = samples.map { sample in
                        WeightRecord(
                            date: sample.startDate,
                            weight: sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                        )
                    }

                    // Set current weight as most recent
                    self?.currentWeight = self?.weightHistory.first?.weight

                    continuation.resume()
                }
            }
            healthStore.execute(query)
        }
    }

    // Get daily average weights for charting
    var dailyWeights: [WeightRecord] {
        let grouped = Dictionary(grouping: weightHistory) { record in
            Calendar.current.startOfDay(for: record.date)
        }

        return grouped.map { (date, records) in
            let avgWeight = records.reduce(0) { $0 + $1.weight } / Double(records.count)
            return WeightRecord(date: date, weight: avgWeight)
        }.sorted { $0.date < $1.date }
    }
}

private enum HealthKitSyncError: LocalizedError {
    case saveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "健康数据写入失败"
        case .deleteFailed:
            return "健康数据删除失败"
        }
    }
}
