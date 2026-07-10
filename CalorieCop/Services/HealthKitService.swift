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

        let typesToRead: Set<HKObjectType> = [
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.bodyMass)
        ]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            isAuthorized = true
            await fetchTodayCaloriesBurned()
            await fetchWeightHistory()
        } catch {
            authorizationError = "Failed to authorize HealthKit: \(error.localizedDescription)"
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
