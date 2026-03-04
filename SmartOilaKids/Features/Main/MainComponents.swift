import SwiftUI
import UIKit

struct MainHeaderSection: View {
    let profileName: String
    let notificationBadgeCount: Int
    let onInfoTap: () -> Void
    let onNotificationTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChildStatusBar(background: AppColors.white)

            HStack(spacing: 10) {
                Circle()
                    .fill(AppColors.surfacePurple)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if UIImage(named: "ProfileCircleBg") != nil {
                            Image("ProfileCircleBg")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                        }

                        if UIImage(named: "UserAvatarGlyph") != nil {
                            Image("UserAvatarGlyph")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppColors.white)
                        }
                    }

                Text(profileName)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    MainHeaderIconButton(
                        action: onInfoTap,
                        accessibilityLabel: L10n.tr("main.info_title")
                    ) {
                        iconOrFallback(asset: "IconInfo", system: "info.circle", size: 18)
                    }

                    MainHeaderIconButton(
                        action: onNotificationTap,
                        accessibilityLabel: L10n.tr("main.notifications")
                    ) {
                        ZStack(alignment: .topTrailing) {
                            iconOrFallback(asset: "IconNotification", system: "bell", size: 18)

                            if notificationBadgeCount > 0 {
                                Text("\(min(99, notificationBadgeCount))")
                                    .font(AppTypography.unbounded(8, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(AppColors.dangerRed)
                                    .clipShape(Capsule())
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }

                    MainHeaderIconButton(
                        action: onSettingsTap,
                        accessibilityLabel: L10n.tr("settings.title")
                    ) {
                        iconOrFallback(asset: "IconSettings", system: "gearshape", size: 18)
                    }
                }
                .foregroundStyle(AppColors.black)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(AppColors.white)
        .clipShape(RoundedCornerShape(corners: [.bottomLeft, .bottomRight], radius: 20))
    }

    @ViewBuilder
    private func iconOrFallback(asset: String, system: String, size: CGFloat) -> some View {
        if UIImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: system)
                .font(.system(size: size, weight: .regular))
        }
    }
}

private struct MainHeaderIconButton<Content: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            content()
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MainAdInfoCard: View {
    var status: MainDeviceStatus?

    private var hasStatusData: Bool {
        guard let status else { return false }
        return status.deviceName.trimmedNonEmpty != nil
            || status.battery != nil
            || status.connectionType?.trimmedNonEmpty != nil
            || status.soundMode?.trimmedNonEmpty != nil
            || (status.latitude != nil && status.longitude != nil)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(AppColors.neutral200)
            .frame(maxWidth: .infinity)
            .aspectRatio(1.7, contentMode: .fit)
            .frame(maxHeight: 240)
            .overlay(alignment: .leading) {
                if hasStatusData {
                    liveStatusContent
                        .padding(.horizontal, 22)
                } else {
                    Text(L10n.tr("main.ad_info"))
                        .font(AppTypography.unbounded(15.6, weight: .medium))
                        .foregroundStyle(AppColors.black)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                }
            }
    }

    private var liveStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("main.device_live_status"))
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(AppColors.black)
                .lineLimit(1)

            if let deviceName = status?.deviceName.trimmedNonEmpty {
                statusRow(
                    iconSystemName: "iphone",
                    text: L10n.tr("main.device_name", deviceName)
                )
            }

            if let battery = status?.battery {
                statusRow(
                    iconSystemName: "battery.75",
                    text: L10n.tr("main.device_battery", "\(battery)%")
                )
            }

            if let connectionRaw = status?.connectionType?.trimmedNonEmpty {
                statusRow(
                    iconSystemName: "antenna.radiowaves.left.and.right",
                    text: L10n.tr("main.device_connection", formatConnection(connectionRaw))
                )
            }

            if let soundRaw = status?.soundMode?.trimmedNonEmpty {
                statusRow(
                    iconSystemName: "speaker.wave.2.fill",
                    text: L10n.tr("main.device_sound_mode", formatSoundMode(soundRaw))
                )
            }

            if let latitude = status?.latitude,
               let longitude = status?.longitude {
                let coordinates = String(format: "%.4f, %.4f", latitude, longitude)
                statusRow(
                    iconSystemName: "location.fill",
                    text: L10n.tr("main.device_location", coordinates)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func statusRow(iconSystemName: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.black.opacity(0.78))
                .frame(width: 16, alignment: .leading)

            Text(text)
                .font(AppTypography.unbounded(11, weight: .medium))
                .foregroundStyle(AppColors.black.opacity(0.86))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func formatConnection(_ value: String) -> String {
        let normalized = value.lowercased()
        switch normalized {
        case "wifi", "wi-fi":
            return L10n.tr("main.connection_wifi")
        case "mobile", "cellular":
            return L10n.tr("main.connection_mobile")
        case "offline":
            return L10n.tr("main.connection_offline")
        default:
            return value.capitalized
        }
    }

    private func formatSoundMode(_ value: String) -> String {
        let normalized = value.lowercased()
        switch normalized {
        case "normal":
            return L10n.tr("main.sound_normal")
        case "silent":
            return L10n.tr("main.sound_silent")
        case "vibrate":
            return L10n.tr("main.sound_vibrate")
        default:
            return value.capitalized
        }
    }
}

struct MainPrimaryActions: View {
    let pendingTasksCount: Int?
    let unreadChatCount: Int?
    let onTasksTap: () -> Void
    let onChatTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                AppHaptics.tap()
                onTasksTap()
            } label: {
                MainActionButton(title: L10n.tr("main.tasks"), badgeCount: pendingTasksCount)
            }
            .buttonStyle(.plain)

            Button {
                AppHaptics.tap()
                onChatTap()
            } label: {
                MainActionButton(title: L10n.tr("main.message"), badgeCount: unreadChatCount)
            }
            .buttonStyle(.plain)
        }
    }
}

struct MainSOSFloatingButton: View {
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if isSending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 16, weight: .semibold))
                }

                Text(L10n.tr("main.sos_title"))
                    .font(AppTypography.unbounded(13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 45)
            .background(AppColors.dangerRed)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.tr("main.sos_title"))
    }
}

private struct MainActionButton: View {
    let title: String
    let badgeCount: Int?

    init(title: String, badgeCount: Int? = nil) {
        self.title = title
        self.badgeCount = badgeCount
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(title)
                .font(AppTypography.unbounded(16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(AppColors.primaryPurple)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            if let badgeCount, badgeCount > 0 {
                Text("\(min(99, badgeCount))")
                    .font(AppTypography.unbounded(9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(AppColors.dangerRed)
                    .clipShape(Capsule())
                    .offset(x: -6, y: -8)
            }
        }
    }
}

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
        VStack(spacing: 16) {
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
                        .strokeBorder(Color.white, lineWidth: 5)

                    ForEach(0...lineCount, id: \.self) { index in
                        let progress = CGFloat(index) / CGFloat(lineCount)
                        let y = chartTop + (progress * plotHeight)
                        let hourValue = Int(maxHours) - index

                        Path { path in
                            path.move(to: CGPoint(x: outerPadding + yLabelWidth, y: y))
                            path.addLine(to: CGPoint(x: outerPadding + yLabelWidth + plotWidth, y: y))
                        }
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.white.opacity(0.45))

                        if hourValue > 0 {
                            Text("\(hourValue)\(L10n.tr("main.hours_short"))")
                                .font(AppTypography.unbounded(14, weight: .semibold))
                                .foregroundStyle(.white)
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
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .position(x: x, y: chartTop + plotHeight + (dayLabelHeight / 2))
                    }
                }
            }
            .frame(height: compact ? 260 : 300)
            .frame(maxWidth: .infinity)

            Text(L10n.tr("main.weekly_stats"))
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
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
