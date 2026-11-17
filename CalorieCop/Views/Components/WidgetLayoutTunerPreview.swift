#if DEBUG
import SwiftUI

private struct WidgetLayoutTunerPreview: View {
    @State private var horizontalPadding = 16.0
    @State private var verticalPadding = 10.0
    @State private var verticalOffset = 4.0
    @State private var titleSpacing = 16.0
    @State private var rowSpacing = 1.0
    @State private var rowHeight = 28.0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                widgetPreview
                    .frame(width: 170, height: 170)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

                VStack(spacing: 14) {
                    tuningSlider(title: "左右边距", value: $horizontalPadding, range: 4...24)
                    tuningSlider(title: "内容上下内边距", value: $verticalPadding, range: 0...20)
                    tuningSlider(title: "整体上下位置", value: $verticalOffset, range: -24...24)
                    tuningSlider(title: "标题与指标间距", value: $titleSpacing, range: 0...16)
                    tuningSlider(title: "三行间距", value: $rowSpacing, range: 0...8)
                    tuningSlider(title: "每行高度", value: $rowHeight, range: 22...36)
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(
                    "当前值：左右 \(horizontalPadding, specifier: "%.0f")，上下内边距 \(verticalPadding, specifier: "%.0f")，整体位置 \(verticalOffset, specifier: "%.0f")，标题间距 \(titleSpacing, specifier: "%.0f")，行间距 \(rowSpacing, specifier: "%.0f")，行高 \(rowHeight, specifier: "%.0f")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var widgetPreview: some View {
        VStack(spacing: titleSpacing) {
            HStack(spacing: 7) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("今日热量")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }

            VStack(spacing: rowSpacing) {
                metricRow(title: "摄入", value: 1_328, color: .orange, systemImage: "fork.knife")
                metricRow(title: "消耗", value: 1_890, color: .red, systemImage: "flame.fill")
                metricRow(title: "缺口", value: 562, color: .green, systemImage: "arrow.down.circle.fill")
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: verticalOffset)
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
        .frame(maxWidth: .infinity, minHeight: rowHeight)
    }

    private func tuningSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
        }
    }
}

#Preview("小组件布局调节器") {
    WidgetLayoutTunerPreview()
}
#endif
