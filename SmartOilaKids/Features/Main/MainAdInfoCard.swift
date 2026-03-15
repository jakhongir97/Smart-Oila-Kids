import SwiftUI

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
        VStack(alignment: .leading, spacing: 0) {
            if hasStatusData {
                liveStatusContent
                    .padding(.horizontal, 22)
            } else {
                emptyStateContent
                    .padding(.horizontal, 22)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.7, contentMode: .fit)
        .frame(maxHeight: 240)
        .mainDashboardCard(cornerRadius: 30)
    }

    private var liveStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("main.device_live_status"))
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(.white)
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

    private var emptyStateContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("main.device_live_status"))
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(L10n.tr("main.device_status_waiting"))
                .font(AppTypography.unbounded(11, weight: .medium))
                .foregroundStyle(AppColors.neutral600)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func statusRow(iconSystemName: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.neutral600)
                .frame(width: 16, alignment: .leading)

            Text(text)
                .font(AppTypography.unbounded(11, weight: .medium))
                .foregroundStyle(.white)
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
