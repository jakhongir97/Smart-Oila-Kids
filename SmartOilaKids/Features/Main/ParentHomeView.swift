import SwiftUI
import UIKit

struct ParentHomeView: View {
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: ParentHomeViewModel

    @State private var selectedChild: ParentHomeChildSummary?
    @State private var showDashboard = false
    @State private var showNotifications = false
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var showAddChild = false

    init(viewModel: ParentHomeViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                AppColors.white
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ParentHomeHeader(
                        profileName: resolvedProfileName,
                        onInfoTap: { showGuide = true },
                        onNotificationTap: { showNotifications = true },
                        onSettingsTap: { showSettings = true }
                    )

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 18) {
                            ParentHomeGuideCard(action: { showGuide = true })

                            VStack(spacing: 18) {
                                if let errorMessage = viewModel.phase.errorMessage, viewModel.children.isEmpty {
                                    ParentHomeErrorCard(
                                        message: errorMessage,
                                        retry: {
                                            Task { await viewModel.load() }
                                        }
                                    )
                                } else if viewModel.children.isEmpty, !viewModel.phase.isLoading {
                                    ParentHomeEmptyCard()
                                } else {
                                    VStack(spacing: 20) {
                                        ForEach(viewModel.children) { child in
                                            ParentHomeChildCard(
                                                child: child,
                                                action: {
                                                    openChild(child)
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 30)
                        }
                        .padding(.top, 15)
                        .padding(.bottom, max(140, proxy.safeAreaInsets.bottom + 120))
                    }
                }

                ChildWatermarkOverlay(size: 200, opacity: 0.5)

                VStack {
                    Spacer()

                    ParentHomeAddButton(title: L10n.tr("parent_home.add_button")) {
                        showAddChild = true
                    }
                    .padding(.horizontal, 31)
                    .padding(.bottom, max(30, proxy.safeAreaInsets.bottom - 4))
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: sessionStore.selectedRemoteDSN) { newValue in
            guard let normalized = newValue?.trimmedNonEmpty else { return }
            selectedChild = viewModel.children.first { child in
                guard let childDSN = child.dsn?.trimmedNonEmpty else { return false }
                return childDSN.caseInsensitiveCompare(normalized) == .orderedSame
            }
        }
        .fullScreenCover(isPresented: $showDashboard, onDismiss: {
            selectedChild = nil
        }) {
            if let selectedChild {
                MainView(viewModel: dependencies.makeMainViewModel())
                    .onAppear {
                        sessionStore.setSelectedRemoteDSN(selectedChild.dsn)
                    }
                .environmentObject(sessionStore)
            }
        }
        .fullScreenCover(isPresented: $showNotifications) {
            AppNavigationContainer {
                NotificationsInboxView(dsn: activeRemoteDSN, onOpenDestination: { _ in })
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            AppNavigationContainer {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        }
        .fullScreenCover(isPresented: $showAddChild, onDismiss: {
            Task { await viewModel.load() }
        }) {
            AuthView(viewModel: dependencies.makeAuthViewModel())
            .environmentObject(sessionStore)
        }
        .onChange(of: sessionStore.dsn) { newValue in
            guard showAddChild, newValue?.trimmedNonEmpty != nil else { return }
            showAddChild = false
            Task { await viewModel.load() }
        }
        .sheet(isPresented: $showGuide) {
            AppNavigationContainer {
                ParentHomeGuideSheet {
                    showGuide = false
                }
            }
            .appMediumLargeSheetPresentation()
        }
    }

    private var resolvedProfileName: String {
        viewModel.profileName?.trimmedNonEmpty
            ?? sessionStore.profileName.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? L10n.tr("common.user_default")
    }

    private var activeRemoteDSN: String? {
        sessionStore.selectedRemoteDSN?.trimmedNonEmpty ?? sessionStore.dsn?.trimmedNonEmpty
    }

    private func isSelected(_ child: ParentHomeChildSummary) -> Bool {
        guard let childDSN = child.dsn?.trimmedNonEmpty,
              let selectedDSN = activeRemoteDSN else {
            return false
        }
        return childDSN.caseInsensitiveCompare(selectedDSN) == .orderedSame
    }

    private func openChild(_ child: ParentHomeChildSummary) {
        guard child.dsn?.trimmedNonEmpty != nil else { return }
        sessionStore.setSelectedRemoteDSN(child.dsn)
        selectedChild = child
        showDashboard = true
    }
}

private struct ParentHomeHeader: View {
    let profileName: String
    let onInfoTap: () -> Void
    let onNotificationTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChildStatusBar(background: AppColors.surfacePurple)

            HStack(spacing: 12) {
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
                    .overlay {
                        if UIImage(named: "ParentHomeUserGlyph") != nil {
                            Image("ParentHomeUserGlyph")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .opacity(0.3)
                        } else if UIImage(named: "UserAvatarGlyph") != nil {
                            Image("UserAvatarGlyph")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .opacity(0.3)
                        } else {
                            Image(systemName: "person")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(AppColors.neutral700)
                                .opacity(0.7)
                        }
                    }

                Text(profileName)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 15) {
                    ParentHomeHeaderIcon(assetName: "ParentHomeInfo", fallbackSystemName: "info.circle") { onInfoTap() }
                    ParentHomeHeaderIcon(assetName: "ParentHomeNotification", fallbackSystemName: "bell") { onNotificationTap() }
                    ParentHomeHeaderIcon(assetName: "ParentHomeSettings", fallbackSystemName: "gearshape") { onSettingsTap() }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 31)
            .padding(.bottom, 0)
        }
        .frame(height: 165, alignment: .top)
        .background(AppColors.surfacePurple)
        .clipShape(BottomRoundedShape(radius: 20))
    }
}

private struct ParentHomeHeaderIcon: View {
    let assetName: String
    let fallbackSystemName: String
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Group {
                if UIImage(named: assetName) != nil {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                } else {
                    Image(systemName: fallbackSystemName)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct ParentHomeGuideCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 19) {
            Button {
                AppHaptics.tap()
                action()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(AppColors.neutral200)
                        .frame(height: 217)

                    ParentHomeGuidePhoneArt()
                        .padding(.horizontal, 39)
                        .padding(.vertical, 28)
                }
            }
            .buttonStyle(.plain)

            ParentHomeGuideCaption()
        }
    }
}

private struct ParentHomeGuidePhoneArt: View {
    var body: some View {
        if UIImage(named: "ParentHomeGuideRectBase") != nil {
            ParentHomeGuidePhoneArtAsset()
        } else {
            ParentHomeGuidePhoneArtFallback()
        }
    }
}

private struct ParentHomeGuidePhoneArtAsset: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black)
                .frame(width: 333, height: 160)
                .overlay {
                    ZStack {
                        Group {
                            if UIImage(named: "ParentHomeGuideVectorPanel") != nil {
                                Image("ParentHomeGuideVectorPanel")
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .rotationEffect(.degrees(-90))
                            } else {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(AppColors.primaryPurple)
                            }
                        }
                        .frame(width: 321, height: 149)
                        .overlay {
                            LinearGradient(
                                colors: [
                                    AppColors.primaryPurple.opacity(0.98),
                                    AppColors.primaryPurple.opacity(0.92),
                                    AppColors.surfacePurple.opacity(0.84)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                        guideDecor("ParentHomeGuideTriangle", width: 72, height: 63, x: -112, y: -34)
                        guideDecor("ParentHomeGuideRectBlock", width: 83, height: 62, x: 109, y: -35)
                        guideDecor("ParentHomeGuideEllipseLarge", width: 83, height: 68, x: 66, y: 45)

                        Group {
                            if UIImage(named: "ParentHomeGuideVectorSide") != nil {
                                Image("ParentHomeGuideVectorSide")
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .rotationEffect(.degrees(-90))
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.black, lineWidth: 1.1)
                            }
                        }
                        .frame(width: 15, height: 48)
                        .offset(x: -144, y: -1)

                        RoundedRectangle(cornerRadius: 45, style: .continuous)
                            .fill(Color(red: 134 / 255, green: 134 / 255, blue: 134 / 255, opacity: 0.3))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 45, style: .continuous))
                            .frame(width: 208, height: 83)
                            .overlay {
                                HStack(spacing: 18) {
                                    ZStack {
                                        if UIImage(named: "ParentHomeGuideEllipseButton") != nil {
                                            Image("ParentHomeGuideEllipseButton")
                                                .resizable()
                                                .renderingMode(.original)
                                                .scaledToFit()
                                        } else {
                                            Circle()
                                                .fill(.white)
                                        }

                                        if UIImage(named: "ParentHomeGuidePlayButton") != nil {
                                            Image("ParentHomeGuidePlayButton")
                                                .resizable()
                                                .renderingMode(.original)
                                                .scaledToFit()
                                                .frame(width: 25, height: 25)
                                        } else {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 24, weight: .bold))
                                                .foregroundStyle(.black)
                                                .offset(x: 2)
                                        }
                                    }
                                    .frame(width: 67, height: 67)

                                    Text(L10n.tr("parent_home.guide_button"))
                                        .font(AppTypography.unbounded(16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(2)
                                        .frame(width: 102, height: 40)
                                }
                                .padding(.horizontal, 8)
                            }
                            .offset(x: 1, y: 8)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }

    @ViewBuilder
    private func guideDecor(_ assetName: String, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        if UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: width, height: height)
                .offset(x: x, y: y)
        }
    }
}

private struct ParentHomeGuideCaption: View {
    private let textColor = AppColors.black.opacity(0.3)

    var body: some View {
        VStack(spacing: 0) {
            guideLine("parent_home.guide_caption_line_1")
            guideLine("parent_home.guide_caption_line_2")

            (
                Text(L10n.tr("parent_home.guide_caption_line_3_link"))
                    .underline(true, color: textColor)
                +
                Text(L10n.tr("parent_home.guide_caption_line_3_suffix"))
            )
            .font(AppTypography.unbounded(14, weight: .medium))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 336)
    }

    private func guideLine(_ key: String) -> some View {
        Text(L10n.tr(key))
            .font(AppTypography.unbounded(14, weight: .medium))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
    }
}

private struct ParentHomeGuidePhoneArtFallback: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 160)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppColors.primaryPurple, AppColors.secondaryPurple, AppColors.surfacePurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 146)
                .padding(.horizontal, 8)

            VStack {
                HStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black)
                        .frame(width: 14, height: 52)
                    Spacer()
                }
                .padding(.leading, 10)
                Spacer()
            }

            Circle()
                .fill(AppColors.surfacePurple.opacity(0.5))
                .frame(width: 84, height: 84)
                .offset(x: 70, y: 40)

            Triangle()
                .fill(AppColors.surfacePurple.opacity(0.75))
                .frame(width: 68, height: 62)
                .offset(x: -110, y: -28)

            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(AppColors.surfacePurple.opacity(0.72))
                .frame(width: 84, height: 62)
                .offset(x: 118, y: -42)

            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(.white.opacity(0.2))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 50, style: .continuous))
                .frame(width: 214, height: 78)
                .overlay {
                    HStack(spacing: 24) {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.black)
                                    .offset(x: 2)
                            }

                        Text(L10n.tr("parent_home.guide_button"))
                            .font(AppTypography.unbounded(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                }
        }
    }
}

private struct ParentHomeChildCard: View {
    let child: ParentHomeChildSummary
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            HStack(spacing: 15) {
                ParentHomeAvatar(avatarURL: child.avatarURL)

                Text(child.name)
                    .font(AppTypography.unbounded(16, weight: .medium))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    ParentHomeSoundStatusIcon(soundMode: child.soundMode)
                    ParentHomeBatteryStatusIcon(level: child.battery)
                }
                .foregroundStyle(AppColors.black)
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 15)
            .frame(height: 80)
            .background(.white)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppColors.primaryPurple, lineWidth: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ParentHomeAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(AppTypography.unbounded(16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(AppColors.accentGreen)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ParentHomeAvatar: View {
    let avatarURL: URL?

    var body: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(AppColors.surfacePurple, lineWidth: 3)
            .frame(width: 50, height: 50)
            .overlay {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty, .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(4)
                } else {
                    placeholder
                        .padding(4)
                }
            }
    }

    private var placeholder: some View {
        Group {
            if UIImage(named: "ParentHomeUserGlyph") != nil {
                Image("ParentHomeUserGlyph")
                    .resizable()
                    .scaledToFit()
                    .opacity(0.3)
            } else if UIImage(named: "UserAvatarGlyph") != nil {
                Image("UserAvatarGlyph")
                    .resizable()
                    .scaledToFit()
                    .opacity(0.3)
            } else {
                Image(systemName: "person")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(AppColors.neutral700)
                    .opacity(0.7)
            }
        }
    }
}

private struct ParentHomeSoundStatusIcon: View {
    let soundMode: String?

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackIconName)
                    .font(.system(size: 28, weight: .regular))
            }
        }
        .frame(width: 30, height: 30)
    }

    private var assetName: String? {
        switch soundMode?.lowercased() {
        case "mute", "silent":
            return UIImage(named: "ParentHomeSoundMuted") != nil ? "ParentHomeSoundMuted" : nil
        case "vibrate", "normal":
            return UIImage(named: "ParentHomeSoundMedium") != nil ? "ParentHomeSoundMedium" : nil
        default:
            return UIImage(named: "ParentHomeSoundMedium") != nil ? "ParentHomeSoundMedium" : nil
        }
    }

    private var fallbackIconName: String {
        switch soundMode?.lowercased() {
        case "mute", "silent":
            return "speaker.slash.fill"
        case "vibrate":
            return "iphone.radiowaves.left.and.right"
        case "normal":
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

private struct ParentHomeBatteryStatusIcon: View {
    let level: Int?

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbolName)
                    .font(.system(size: 28, weight: .regular))
                    .rotationEffect(.degrees(90))
            }
        }
        .frame(width: 30, height: 30)
    }

    private var assetName: String? {
        guard let level else {
            return UIImage(named: "ParentHomeBatteryMedium") != nil ? "ParentHomeBatteryMedium" : nil
        }
        if level >= 80 {
            return UIImage(named: "ParentHomeBatteryFull") != nil ? "ParentHomeBatteryFull" : nil
        }
        return UIImage(named: "ParentHomeBatteryMedium") != nil ? "ParentHomeBatteryMedium" : nil
    }

    private var fallbackSymbolName: String {
        guard let level else { return "battery.50" }
        switch level {
        case ..<20:
            return "battery.25"
        case ..<50:
            return "battery.50"
        case ..<80:
            return "battery.75"
        default:
            return "battery.100"
        }
    }
}

private struct ParentHomeEmptyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("parent_home.empty_title"))
                .font(AppTypography.unbounded(16, weight: .semibold))
                .foregroundStyle(AppColors.black)

            Text(L10n.tr("parent_home.empty_subtitle"))
                .font(AppTypography.unbounded(12, weight: .medium))
                .foregroundStyle(AppColors.neutral500)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ParentHomeErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .font(AppTypography.unbounded(12, weight: .medium))
                .foregroundStyle(AppColors.black)
                .lineSpacing(2)

            Button(L10n.tr("common.retry")) {
                AppHaptics.tap()
                retry()
            }
            .font(AppTypography.unbounded(11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(AppColors.primaryPurple)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ParentHomeGuideSheet: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            AppColors.white.ignoresSafeArea()

            VStack(spacing: 0) {
                ChildTitleBar(
                    title: L10n.tr("parent_home.guide_sheet_title"),
                    leading: { ChildTopBackButton(action: onClose) },
                    trailing: { Color.clear }
                )

                ChildPurpleSurface {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            ParentHomeGuideCard(action: {})
                                .allowsHitTesting(false)

                            Text(L10n.tr("parent_home.guide_sheet_body"))
                                .font(AppTypography.unbounded(12, weight: .medium))
                                .foregroundStyle(AppColors.neutral600)
                                .lineSpacing(3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

private struct BottomRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.bottomLeft, .bottomRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
