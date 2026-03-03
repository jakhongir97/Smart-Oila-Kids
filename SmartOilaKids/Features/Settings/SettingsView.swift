import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore

    @StateObject private var viewModel: SettingsViewModel
    @State private var userName: String = ""
    @State private var bannerText: String?
    @State private var showDeleteAlert = false
    @FocusState private var isNameFieldFocused: Bool

    init(viewModel: SettingsViewModel? = nil) {
        _viewModel = StateObject(
            wrappedValue: viewModel ?? SettingsViewModel(service: SettingsService())
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(30, max(16, proxy.size.width * 0.06))
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("settings.title"),
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: { Color.clear }
                    )

                    ChildPurpleSurface {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                SettingsAvatarSection()
                                    .padding(.top, compact ? 14 : 20)

                                Text(L10n.tr("settings.change_username"))
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 18 : 25)

                                TextField(L10n.tr("settings.username_placeholder"), text: $userName)
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .padding(.horizontal, 20)
                                    .frame(height: 50)
                                    .focused($isNameFieldFocused)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled(true)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        save()
                                    }
                                    .background(AppColors.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 8 : 10)

                                Text(L10n.tr("settings.appearance"))
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 16 : 20)

                                Picker("", selection: themeBinding) {
                                    ForEach(AppTheme.allCases) { theme in
                                        Text(themeTitle(theme)).tag(theme)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, sidePadding)
                                .padding(.top, compact ? 8 : 10)

                                Text(L10n.tr("settings.language"))
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 14 : 18)

                                Picker("", selection: languageBinding) {
                                    ForEach(AppLanguage.allCases) { language in
                                        Text(languageTitle(language)).tag(language)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, sidePadding)
                                .padding(.top, compact ? 8 : 10)

                                Text(L10n.tr("settings.connected_devices"))
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 16 : 20)

                                VStack(spacing: compact ? 14 : 20) {
                                    ForEach(viewModel.connectedDevices, id: \.self) { name in
                                        SettingsDeviceCard(name: name) {
                                            banner(L10n.tr("settings.edit_soon"))
                                        }
                                    }
                                }
                                .padding(.horizontal, sidePadding)
                                .padding(.top, compact ? 8 : 10)

                                Button {
                                    AppHaptics.tap()
                                    save()
                                } label: {
                                    Text(viewModel.isSaving ? L10n.tr("settings.saving") : L10n.tr("common.save"))
                                        .font(AppTypography.unbounded(16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 45)
                                        .background(AppColors.accentGreen)
                                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isSaving)
                                .padding(.horizontal, sidePadding + 16)
                                .padding(.top, compact ? 20 : 28)

                                HStack(spacing: 10) {
                                    Button {
                                        AppHaptics.tap()
                                        sessionStore.clearSession()
                                    } label: {
                                        Text(L10n.tr("settings.logout"))
                                            .font(AppTypography.unbounded(12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 40)
                                            .background(AppColors.primaryPurple)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        AppHaptics.tap()
                                        showDeleteAlert = true
                                    } label: {
                                        Text(L10n.tr("settings.delete_account"))
                                            .font(AppTypography.unbounded(12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 40)
                                            .background(AppColors.dangerRed)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, sidePadding + 16)
                                .padding(.top, compact ? 8 : 10)
                                .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 12))
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await loadRemoteDataIfNeeded()
        }
        .onChange(of: sessionStore.appLanguage) { _ in
            viewModel.refreshLocalizedFallbacksIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) {
                    isNameFieldFocused = false
                }
            }
        }
        .overlay(alignment: .top) {
            if let bannerText {
                Text(bannerText)
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 10)
            }
        }
        .alert(L10n.tr("settings.delete_title"), isPresented: $showDeleteAlert) {
            Button(L10n.tr("settings.delete_account"), role: .destructive) {
                AppHaptics.warning()
                sessionStore.clearSession()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.delete_message"))
        }
        .preferredColorScheme(sessionStore.appTheme.colorScheme)
    }

    private func save() {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppHaptics.warning()
            banner(L10n.tr("settings.enter_username"))
            return
        }

        Task {
            do {
                let remoteName = try await viewModel.saveProfileName(trimmed)
                userName = remoteName
                sessionStore.setProfileName(remoteName)
                AppHaptics.success()
                banner(L10n.tr("settings.saved"))
            } catch {
                // Keep local profile editable even when backend update is unavailable.
                sessionStore.setProfileName(trimmed)
                AppHaptics.warning()
                banner(L10n.tr("settings.save_failed"))
            }
        }
    }

    private func banner(_ text: String) {
        withAnimation {
            bannerText = text
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                bannerText = nil
            }
        }
    }

    private func loadRemoteDataIfNeeded() async {
        if userName.isEmpty {
            userName = sessionStore.profileName
        }

        await viewModel.loadIfNeeded()

        if let remoteProfileName = viewModel.remoteProfileName,
           remoteProfileName != sessionStore.profileName {
            userName = remoteProfileName
            sessionStore.setProfileName(remoteProfileName)
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { sessionStore.appTheme },
            set: { sessionStore.setTheme($0) }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { sessionStore.appLanguage },
            set: { sessionStore.setLanguage($0) }
        )
    }

    private func themeTitle(_ theme: AppTheme) -> String {
        switch theme {
        case .system:
            return L10n.tr("settings.theme.system")
        case .light:
            return L10n.tr("settings.theme.light")
        case .dark:
            return L10n.tr("settings.theme.dark")
        }
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .en:
            return L10n.tr("settings.language.en")
        case .ru:
            return L10n.tr("settings.language.ru")
        case .uz:
            return L10n.tr("settings.language.uz")
        }
    }
}
