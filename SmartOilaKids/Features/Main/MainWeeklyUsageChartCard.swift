import SwiftUI
import UIKit

struct WeeklyUsageChartCard: View {
    var compact: Bool = false
    var usageHours: [Double] = Array(repeating: 0, count: 7)

    private struct DayUsage: Identifiable {
        let id: Int
        let dayKey: String
        let hours: CGFloat
    }

    private var usage: [DayUsage] {
        let keys = [
            "weekday.mon",
            "weekday.tue",
            "weekday.wed",
            "weekday.thu",
            "weekday.fri",
            "weekday.sat",
            "weekday.sun"
        ]

        let normalized = normalizeUsageHours(usageHours)
        return keys.enumerated().map { index, dayKey in
            DayUsage(id: index, dayKey: dayKey, hours: CGFloat(normalized[index]))
        }
    }

    private var maxHours: CGFloat {
        let maxFromData = usage.map(\.hours).max() ?? 0
        let rounded = ceil(maxFromData)
        return max(5, rounded)
    }

    private func normalizeUsageHours(_ value: [Double]) -> [Double] {
        var normalized = value.prefix(7).map { max(0, $0) }
        if normalized.count < 7 {
            normalized.append(contentsOf: Array(repeating: 0, count: 7 - normalized.count))
        }
        return normalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("main.weekly_stats"))
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let outerPadding = max(14, width * 0.035)
                let yLabelWidth = min(76, max(56, width * 0.2))
                let dayLabelHeight = min(34, max(26, height * 0.12))
                let chartTop = max(14, height * 0.04)
                let chartBottom = dayLabelHeight + 14
                let plotHeight = max(120, height - chartTop - chartBottom)
                let plotWidth = max(120, width - (outerPadding * 2) - yLabelWidth - 6)
                let lineCount = Int(maxHours)
                let barWidth = min(18, max(9, (plotWidth / CGFloat(usage.count)) * 0.24))
                let slotWidth = plotWidth / CGFloat(usage.count)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 3)

                    ForEach(0...lineCount, id: \.self) { index in
                        let progress = CGFloat(index) / CGFloat(lineCount)
                        let y = chartTop + (progress * plotHeight)
                        let hourValue = Int(maxHours) - index

                        Path { path in
                            path.move(to: CGPoint(x: outerPadding + yLabelWidth, y: y))
                            path.addLine(to: CGPoint(x: outerPadding + yLabelWidth + plotWidth, y: y))
                        }
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.white.opacity(0.28))

                        if hourValue > 0 {
                            Text("\(hourValue)\(L10n.tr("main.hours_short"))")
                                .font(AppTypography.unbounded(14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: yLabelWidth - 6, alignment: .trailing)
                                .position(x: outerPadding + (yLabelWidth / 2), y: y)
                        }
                    }

                    ForEach(usage) { item in
                        let x = outerPadding + yLabelWidth + (slotWidth * CGFloat(item.id)) + (slotWidth / 2)
                        let ratio = min(max(item.hours / maxHours, 0), 1)
                        let barHeight = max(8, plotHeight * ratio)
                        let y = chartTop + plotHeight - (barHeight / 2)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white)
                            .frame(width: barWidth, height: barHeight)
                            .position(x: x, y: y)

                        Text(L10n.tr(item.dayKey))
                            .font(AppTypography.unbounded(14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .position(x: x, y: chartTop + plotHeight + (dayLabelHeight / 2))
                    }
                }
            }
            .frame(height: compact ? 240 : 280)
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .mainDashboardCard(cornerRadius: 28)
    }
}

struct RoundedCornerShape: Shape {
    let corners: UIRectCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
