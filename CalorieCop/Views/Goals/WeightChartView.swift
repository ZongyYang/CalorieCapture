import SwiftUI
import Charts

struct WeightChartView: View {
    let weightHistory: [WeightRecord]
    let targetWeight: Double?
    var weightUnit: WeightUnit = .kg

    private func formatWeight(_ kgValue: Double) -> String {
        weightUnit.format(kgValue)
    }

    private func convertWeight(_ kgValue: Double) -> Double {
        weightUnit.fromKg(kgValue)
    }

    private var xAxisDates: [Date] {
        let dates = weightHistory.map(\.date).sorted()
        let maxLabelCount = 5

        guard dates.count > maxLabelCount else {
            return dates
        }

        let lastIndex = dates.count - 1
        return (0..<maxLabelCount).map { index in
            let scaledIndex = Double(index) * Double(lastIndex) / Double(maxLabelCount - 1)
            return dates[Int(scaledIndex.rounded())]
        }
    }

    private func formatAxisDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else {
            return ""
        }
        return "\(month)/\(day)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("体重趋势")
                .font(.headline)

            if weightHistory.isEmpty {
                emptyState
            } else {
                chart
                    .frame(height: 200)

                statsRow
            }
        }
        .padding()
        .background(AppSurfaceStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "scalemass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无体重数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("请确保VeSync已同步到健康App")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private var chart: some View {
        Chart {
            ForEach(weightHistory) { record in
                LineMark(
                    x: .value("日期", record.date),
                    y: .value("体重", convertWeight(record.weight))
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("日期", record.date),
                    y: .value("体重", convertWeight(record.weight))
                )
                .foregroundStyle(.blue.opacity(0.1))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("日期", record.date),
                    y: .value("体重", convertWeight(record.weight))
                )
                .foregroundStyle(.blue)
                .symbolSize(30)
            }

            // Target weight line
            if let target = targetWeight {
                RuleMark(y: .value("目标", convertWeight(target)))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
            }
        }
        .chartYScale(domain: yAxisDomain)
        .chartXAxis {
            AxisMarks(values: xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(formatAxisDate(date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var yAxisDomain: ClosedRange<Double> {
        let weights = weightHistory.map { convertWeight($0.weight) }
        let margin = weightUnit == .lb ? 5.0 : 2.0
        let minWeight = (weights.min() ?? convertWeight(50)) - margin
        let maxWeight = (weights.max() ?? convertWeight(100)) + margin

        if let target = targetWeight {
            let convertedTarget = convertWeight(target)
            return min(minWeight, convertedTarget - margin)...max(maxWeight, convertedTarget + margin)
        }
        return minWeight...maxWeight
    }

    private var statsRow: some View {
        HStack {
            if let first = weightHistory.first, let last = weightHistory.last {
                let change = last.weight - first.weight

                VStack(alignment: .leading) {
                    Text("最新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatWeight(last.weight))
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .center) {
                    Text("变化")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: change < 0 ? "arrow.down" : "arrow.up")
                        Text(formatWeight(abs(change)))
                    }
                    .font(.headline)
                    .foregroundStyle(change < 0 ? .green : .red)
                }

                Spacer()

                if let target = targetWeight {
                    VStack(alignment: .trailing) {
                        Text("距目标")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatWeight(last.weight - target))
                            .font(.headline)
                            .foregroundStyle(last.weight > target ? .orange : .green)
                    }
                }
            }
        }
    }
}

#Preview {
    WeightChartView(
        weightHistory: [
            WeightRecord(date: Date().addingTimeInterval(-86400 * 30), weight: 75.5),
            WeightRecord(date: Date().addingTimeInterval(-86400 * 25), weight: 75.2),
            WeightRecord(date: Date().addingTimeInterval(-86400 * 20), weight: 74.8),
            WeightRecord(date: Date().addingTimeInterval(-86400 * 15), weight: 74.3),
            WeightRecord(date: Date().addingTimeInterval(-86400 * 10), weight: 73.9),
            WeightRecord(date: Date().addingTimeInterval(-86400 * 5), weight: 73.5),
            WeightRecord(date: Date(), weight: 73.2),
        ],
        targetWeight: 70.0
    )
    .padding()
}
