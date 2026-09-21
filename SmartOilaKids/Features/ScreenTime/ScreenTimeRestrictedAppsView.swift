import FamilyControls
import ManagedSettings
import SwiftUI

/// Per-app blocking on an iPhone: the parent controls it from the web; this screen gives the phone
/// what Apple insists a human provide, in as few taps as Apple allows.
///
/// 1. THE FULL LIST, ONE TAP. "Ilovalarni tanlash" opens Apple's `FamilyActivityPicker` with a header
///    telling the parent to switch on "All Apps & Categories". With `includeEntireCategory` that one
///    switch yields an `ApplicationToken` for every app on the phone (measured 2026-09-16), and the
///    list below fills itself — every icon and name drawn by the system via `Label(token)`.
/// 2. LINKING, ONE TAP PER APP THE WEB ASKS ABOUT. The web already lists this phone's apps by name
///    and the parent blocks by name there. iOS acts on tokens, and the app cannot read a token's name
///    (see `ScreenTimeRestrictedAppsStore`), so when the web blocks TikTok the phone asks
///    "TikTok qaysi?" and the parent taps the TikTok icon in the full list. No picker, no search, no
///    typing. Pending apps are queued, so at pairing the parent taps through them in one run.
///    Fallback when the icon is not in the list (the parent did not tick everything): the same row
///    opens Apple's picker already titled "Tick TikTok".
/// 3. LINKED APPS are then controlled from the web alone; a tap offers to unlink a wrong one.
struct ScreenTimeRestrictedAppsView: View {
    @ObservedObject private var store = ScreenTimeRestrictedAppsStore.shared
    @ObservedObject private var authorization = ScreenTimeAuthorizationManager.shared
    @ObservedObject private var telemetry = OilaTelemetryService.shared

    @State private var isPickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    /// The catalogue app being linked right now. While set, the icon list is in "which one is it?"
    /// mode and the picker (if opened from here) labels its one new tick as this app.
    @State private var linking: AppCatalogueEntry?
    /// True when the picker was opened FROM link mode (fallback), so its result labels itself.
    @State private var pickerIsGuided = false
    @State private var guidedSelectionBefore = FamilyActivitySelection()
    @State private var message: String?
    @State private var installed: [AppCatalogueEntry] = []
    /// The linked row whose "unlink" confirmation is open.
    @State private var unlinking: ScreenTimeRestrictedAppsStore.Row?

    private var pendingGroups: (web: [AppCatalogueEntry], installed: [AppCatalogueEntry]) {
        store.pendingTargetGroups(
            lockedPackages: telemetry.lockedPackages,
            limitedPackages: telemetry.appLimits.map(\.packageName),
            installed: installed
        )
    }

    var body: some View {
        let pending = pendingGroups
        let rows = store.rows
        BolajonScreen(intent: .lavender, background: AppColors.screenBackground, title: L10n.tr("screentime.restricted.title")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("screentime.restricted.intro"))
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)

                if authorization.status != .granted {
                    InfoCard {
                        Text(L10n.tr("screentime.restricted.not_authorized"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.sosCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 1. The full list, one tap.
                BolajonPrimaryButton(
                    title: L10n.tr(rows.isEmpty ? "screentime.restricted.pick" : "screentime.restricted.pick_again"),
                    disabled: authorization.status != .granted
                ) {
                    linking = nil
                    pickerIsGuided = false
                    draftSelection = store.selection
                    isPickerPresented = true
                }
                if rows.isEmpty {
                    Text(L10n.tr("screentime.restricted.pick_hint"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }

                // 2. What the web is waiting for — the queue the parent taps through.
                if let linking {
                    linkModeCard(linking, canTapIcons: rows.contains { !$0.isLabelled })
                } else if !pending.web.isEmpty {
                    sectionTitle(L10n.tr("screentime.restricted.pending_web_title"))
                    VStack(spacing: 10) {
                        ForEach(pending.web, id: \.bundleId) { entry in
                            pendingRow(entry, caption: L10n.tr("screentime.restricted.pending_web"))
                        }
                    }
                }

                if let message {
                    InfoCard {
                        Text(message)
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.sosCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The list itself: every picked app. In link mode the unlinked icons are the answer.
                if !rows.isEmpty {
                    sectionTitle(L10n.tr("screentime.restricted.list_title", rows.count))
                    Text(L10n.tr(linking == nil ? "screentime.restricted.list_hint" : "screentime.restricted.list_hint_linking"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(linking == nil ? AppColors.inkTertiary : AppColors.glyphPurple)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    // Lazy: `Label(token)` is drawn out-of-process, and "All Apps" is dozens of rows.
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            appRow(row)
                        }
                    }
                    Text(L10n.tr("screentime.restricted.summary", store.labelledCount, pending.web.count))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(pending.web.isEmpty ? AppColors.inkSecondary : AppColors.sosCoral)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    if store.labelledCount > ScreenTimeUsageMonitoring.maximumEvents {
                        Text(L10n.tr("screentime.restricted.too_many", ScreenTimeUsageMonitoring.maximumEvents))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.sosCoral)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                }

                // 3. Found on this phone, nobody asked yet — optional, saves a trip later.
                if linking == nil, !pending.installed.isEmpty, authorization.status == .granted {
                    sectionTitle(L10n.tr("screentime.restricted.pending_installed_title"))
                    Text(L10n.tr("screentime.restricted.pending_installed_hint"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    VStack(spacing: 10) {
                        ForEach(pending.installed, id: \.bundleId) { entry in
                            pendingRow(entry, caption: nil)
                        }
                    }
                }

                if !rows.isEmpty, !ScreenTimeUsageMonitoring.isSupported {
                    Text(L10n.tr("screentime.restricted.usage_unsupported"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }

                // Deletion protection is device-wide by Apple's design; a parent who finds that
                // Calculator can no longer be deleted must have been told why, here, in advance.
                if authorization.status == .granted, AppRuntime.appRemovalProtectionEnabled {
                    Text(L10n.tr("screentime.restricted.removal_protection"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                }
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            ScreenTimeAppPickerView(
                purpose: .restricted,
                selection: $draftSelection,
                onDone: { selection in
                    guard pickerIsGuided, let target = linking else {
                        store.updateSelection(selection)
                        return
                    }
                    pickerIsGuided = false
                    switch store.labelNewlyPicked(previous: guidedSelectionBefore, current: selection, as: target) {
                    case .labelled:
                        message = nil
                        advanceLinking(after: target)
                    case .nothingNew:
                        message = L10n.tr("screentime.restricted.guided_nothing", target.name)
                    case .ambiguous(let count):
                        message = L10n.tr("screentime.restricted.guided_ambiguous", target.name, count)
                    }
                },
                guidedName: pickerIsGuided ? linking?.name : nil
            )
        }
        .alert(
            L10n.tr("screentime.restricted.unlink_title"),
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            presenting: unlinking
        ) { row in
            Button(L10n.tr("screentime.restricted.unlink"), role: .destructive) {
                store.removeLabel(for: row.token)
                unlinking = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) { unlinking = nil }
        } message: { row in
            Text(L10n.tr("screentime.restricted.unlink_message", row.name ?? ""))
        }
        .onAppear {
            authorization.refreshStatus()
            installed = InstalledAppProbe.installedEntries(canOpen: ScreenTimeEnforcementCoordinator.shared.canOpenScheme)
        }
    }

    // MARK: - Link mode

    /// After one app is linked, the next one the web is waiting for is asked about at once, so a
    /// parent at pairing taps through the whole queue without returning to the list each time.
    private func advanceLinking(after done: AppCatalogueEntry) {
        let remaining = pendingGroups.web.filter { $0.bundleId != done.bundleId }
        linking = remaining.first
    }

    private func linkModeCard(_ entry: AppCatalogueEntry, canTapIcons: Bool) -> some View {
        InfoCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("screentime.restricted.link_title", entry.name))
                    .font(AppTypography.bodyStrong(16))
                    .foregroundStyle(AppColors.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr(canTapIcons ? "screentime.restricted.link_hint" : "screentime.restricted.link_hint_empty"))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        AppHaptics.selection()
                        // Fallback: the icon is not in the list — let Apple's picker find it.
                        pickerIsGuided = true
                        guidedSelectionBefore = store.selection
                        draftSelection = store.selection
                        isPickerPresented = true
                    } label: {
                        Text(L10n.tr("screentime.restricted.link_via_picker"))
                            .font(AppTypography.bodyStrong(13))
                            .foregroundStyle(AppColors.glyphPurple)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Button {
                        AppHaptics.selection()
                        linking = nil
                        message = nil
                    } label: {
                        Text(L10n.tr("screentime.restricted.link_skip"))
                            .font(AppTypography.bodyStrong(13))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.bodyStrong(14))
            .foregroundStyle(AppColors.inkPrimary)
            .padding(.horizontal, 2)
            .padding(.top, 6)
    }

    /// "<App> — Belgilash": enters link mode for this app.
    private func pendingRow(_ entry: AppCatalogueEntry, caption: String?) -> some View {
        Button {
            AppHaptics.selection()
            message = nil
            linking = entry
        } label: {
            InfoCard(padding: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(AppTypography.bodyStrong(15))
                            .foregroundStyle(AppColors.inkPrimary)
                            .lineLimit(1)
                        if let caption {
                            Text(caption)
                                .font(AppTypography.caption(12))
                                .foregroundStyle(AppColors.sosCoral)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(L10n.tr("screentime.restricted.guided_cta"))
                        .font(AppTypography.bodyStrong(13))
                        .foregroundStyle(AppColors.glyphPurple)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(authorization.status != .granted)
    }

    /// One picked app. Outside link mode a linked row can be unlinked and an unlinked row is inert.
    /// In link mode an unlinked row IS the answer to "which one is <App>?".
    private func appRow(_ row: ScreenTimeRestrictedAppsStore.Row) -> some View {
        let isAnswer = linking != nil && !row.isLabelled
        return Button {
            AppHaptics.selection()
            if let target = linking, !row.isLabelled {
                store.label(row.token, as: target)
                message = nil
                advanceLinking(after: target)
            } else if row.isLabelled, linking == nil {
                unlinking = row
            }
        } label: {
            InfoCard(padding: 14) {
                HStack(spacing: 12) {
                    // The system renders the true icon + name. Our process never sees them.
                    Label(row.token)
                        .labelStyle(.titleAndIcon)
                        .font(AppTypography.bodyStrong(15))
                        .foregroundStyle(AppColors.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if row.isLabelled {
                        Text(row.name ?? "")
                            .font(AppTypography.bodyStrong(13))
                            .foregroundStyle(AppColors.pillGreenInk)
                            .lineLimit(1)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.pillGreenInk)
                    } else if isAnswer {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.glyphPurple)
                    }
                }
            }
            .opacity(linking != nil && row.isLabelled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(linking != nil ? row.isLabelled : !row.isLabelled)
    }
}
