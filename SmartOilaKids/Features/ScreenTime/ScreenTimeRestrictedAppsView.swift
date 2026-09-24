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
/// 3. NAMING ANY APP, ONE TAP + A PICK. The web can only see an app the phone can NAME. So any grey
///    row — Paynet, Click, a game — opens "Bu qaysi ilova?": the parent picks the name from the
///    catalogue (installed apps first; the Uzbek apps are in it) or, only for an app nobody
///    listed, types it. That is the ONLY mechanism on iOS that makes an un-detectable app visible
///    and controllable from the web, so it stays (product rule 2026-09-21). A linked row opens the
///    same sheet, which also offers to remove the name.
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
    /// The row whose "which app is this?" sheet is open.
    @State private var labelling: ScreenTimeRestrictedAppsStore.Row?
    /// Opened from Home's "N ta ilova belgilanmagan" card (`ScreenTimeLinkNudgeCard`): link mode
    /// starts at once and walks EVERY pending app — the web's, then the detected ones — instead of
    /// the web queue alone, and "O'tkazib yuborish" moves to the next app rather than leaving.
    private let startsLinkQueue: Bool
    @State private var didStartLinkQueue = false
    /// Apps passed over with "O'tkazib yuborish" in this visit, so the queue does not come back to them.
    @State private var skippedInQueue: Set<String> = []

    init(startsLinkQueue: Bool = false) {
        self.startsLinkQueue = startsLinkQueue
    }

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
                    // Two caps, stated apart: Apple blocks at most 50 apps; the phone TIMES at most 49,
                    // because one of the fifty event slots is kept for the phone's total (build 26).
                    // Both `%d`s get an argument — the string has two, and one was passed before.
                    if store.labelledCount > ScreenTimeUsageMonitoring.maximumApplicationEvents {
                        Text(L10n.tr("screentime.restricted.too_many",
                                     AppCatalogue.maximumBlockedApplications,
                                     ScreenTimeUsageMonitoring.maximumApplicationEvents))
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
        // Both sheets yield to the lock: a sheet already up keeps the root's lock cover from
        // presenting (the rule every presentation on the Home stack follows).
        .onChange(of: telemetry.isLocked) { locked in
            guard locked else { return }
            isPickerPresented = false
            labelling = nil
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
        .sheet(item: $labelling) { row in
            ScreenTimeAppLabelSheet(row: row, takenElsewhere: store.bundleIdsLabelledElsewhere(than: row.token)) { choice in
                switch choice {
                case .catalogue(let entry): store.label(row.token, as: entry)
                case .custom(let name): store.labelCustom(row.token, name: name)
                case .clear: store.removeLabel(for: row.token)
                }
            }
        }
        .onAppear {
            authorization.refreshStatus()
            // The last probe at once; the fresh one after the push has settled (it is ~35 round
            // trips to LaunchServices on the main thread, run in chunks — see
            // `refreshInstalledEntries`).
            installed = ScreenTimeEnforcementCoordinator.shared.cachedInstalledEntries()
            if startsLinkQueue, !didStartLinkQueue, authorization.status == .granted {
                didStartLinkQueue = true
                linking = linkQueue.first
            }
        }
        .task {
            // Cancelled when the screen goes away before the delay: no probe during the pop.
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            installed = await ScreenTimeEnforcementCoordinator.shared.refreshInstalledEntries()
        }
    }

    // MARK: - Link mode

    /// After one app is linked, the next one the web is waiting for is asked about at once, so a
    /// parent at pairing taps through the whole queue without returning to the list each time. From
    /// Home's nudge the queue is every pending app, the detected ones included.
    private func advanceLinking(after done: AppCatalogueEntry) {
        let queue = startsLinkQueue ? linkQueue : pendingGroups.web
        linking = queue.first { $0.bundleId != done.bundleId }
    }

    /// The nudge's queue: what the web is waiting for first, then what the probe found, minus what
    /// was skipped in this visit. Pure over `pendingGroups`, so its order is pinned by a test.
    private var linkQueue: [AppCatalogueEntry] {
        Self.linkQueue(pending: pendingGroups, skipped: skippedInQueue)
    }

    static func linkQueue(
        pending: (web: [AppCatalogueEntry], installed: [AppCatalogueEntry]),
        skipped: Set<String>
    ) -> [AppCatalogueEntry] {
        (pending.web + pending.installed).filter { !skipped.contains($0.bundleId) }
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
                        message = nil
                        if startsLinkQueue {
                            skippedInQueue.insert(entry.bundleId)
                            linking = linkQueue.first { $0.bundleId != entry.bundleId }
                        } else {
                            linking = nil
                        }
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

    /// One picked app. Outside link mode ANY row opens "which app is this?" (name it, rename it,
    /// or remove the name). In link mode an unlinked row IS the answer to "which one is <App>?".
    private func appRow(_ row: ScreenTimeRestrictedAppsStore.Row) -> some View {
        let isAnswer = linking != nil && !row.isLabelled
        return Button {
            AppHaptics.selection()
            if let target = linking, !row.isLabelled {
                store.label(row.token, as: target)
                message = nil
                advanceLinking(after: target)
            } else if linking == nil {
                labelling = row
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
                    } else {
                        Text(L10n.tr("screentime.restricted.name_cta"))
                            .font(AppTypography.bodyStrong(13))
                            .foregroundStyle(AppColors.glyphPurple)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
            }
            .opacity(linking != nil && row.isLabelled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(linking != nil && row.isLabelled)
    }
}

/// "Which app is this?" — the catalogue, installed apps first, plus a free-text name.
struct ScreenTimeAppLabelSheet: View {
    enum Choice {
        case catalogue(AppCatalogueEntry)
        case custom(String)
        case clear
    }

    let row: ScreenTimeRestrictedAppsStore.Row
    /// Bundle ids already given to another icon — shown, not forbidden: choosing one moves it.
    let takenElsewhere: Set<String>
    let onChoose: (Choice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var customName = ""
    /// The `canOpenURL` probe (~50 synchronous XPC calls) runs once per sheet, never per keystroke.
    @State private var installed: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label(row.token)
                            .labelStyle(.titleAndIcon)
                            .font(AppTypography.bodyStrong(16))
                        Spacer()
                    }
                } header: {
                    Text(L10n.tr("screentime.label.which"))
                }

                Section(L10n.tr("screentime.label.catalogue")) {
                    ForEach(filteredEntries, id: \.bundleId) { entry in
                        Button {
                            onChoose(.catalogue(entry))
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.name)
                                    .foregroundStyle(AppColors.inkPrimary)
                                Spacer()
                                if row.bundleId == AppCatalogue.normalizedBundleId(entry.bundleId) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColors.glyphPurple)
                                } else if takenElsewhere.contains(AppCatalogue.normalizedBundleId(entry.bundleId)) {
                                    Text(L10n.tr("screentime.label.taken"))
                                        .font(AppTypography.caption(12))
                                        .foregroundStyle(AppColors.inkTertiary)
                                }
                            }
                        }
                    }
                }

                Section(L10n.tr("screentime.label.custom")) {
                    TextField(L10n.tr("screentime.label.custom_placeholder"), text: $customName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: customName) { value in
                            if value.count > ScreenTimeRestrictedAppsStore.maximumCustomNameLength {
                                customName = String(value.prefix(ScreenTimeRestrictedAppsStore.maximumCustomNameLength))
                            }
                        }
                    Button(L10n.tr("common.save")) {
                        onChoose(.custom(customName))
                        dismiss()
                    }
                    .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if row.isLabelled {
                    Section {
                        Button(L10n.tr("screentime.label.clear"), role: .destructive) {
                            onChoose(.clear)
                            dismiss()
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: L10n.tr("screentime.label.search"))
            .navigationTitle(L10n.tr("screentime.label.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
        }
        .onAppear {
            if let name = row.name, row.bundleId?.hasPrefix(ScreenTimeRestrictedAppsStore.customBundleIdPrefix) == true {
                customName = name
            }
            installed = Set(ScreenTimeEnforcementCoordinator.shared.cachedInstalledEntries().map(\.bundleId))
        }
        .task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            installed = Set(await ScreenTimeEnforcementCoordinator.shared.refreshInstalledEntries().map(\.bundleId))
        }
    }

    /// Installed (probe-detected) apps first, then the rest of the catalogue, both alphabetical.
    private var filteredEntries: [AppCatalogueEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppCatalogue.all
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { lhs, rhs in
                let l = installed.contains(lhs.bundleId), r = installed.contains(rhs.bundleId)
                if l != r { return l }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

// MARK: - Home: the one-time pick that lets screen time count at all

/// The Home card that asks for the one-tap "All Apps & Categories" pick, shown only while the phone
/// has none.
///
/// WHY IT EXISTS. iOS measures nothing without a `FamilyActivityPicker` selection — no token, no
/// threshold, no minute (Apple's wall). Until build 26 the pick lived only behind Settings ›
/// restricted apps, so a phone paired without opening it measured nothing, uploaded nothing, and
/// the parent's web read "Bugungi ekran 0 daqiqa" (Ibrohim, 2026-09-23). The pick's category tokens
/// are what the device-total rung measures (`ScreenTimeUsageTotalCategoryStore`), so this card stays
/// until the stored selection HAS categories — which is exactly when the whole phone is counted.
///
/// WHY HOME AS WELL AS ONBOARDING. Since build 28 onboarding asks for the pick itself, right after
/// the Screen Time grant (`BolajonPermissionStep.Kind.appSelection`) — the unpair wipe removes the
/// selection, so every re-pair needs it again. This card stays as the backstop: a phone that is
/// already paired never sees onboarding again, a child can leave the pick for "Keyinroq" after a
/// round Apple's picker came back empty from, and Screen Time granted later from Settings has no
/// onboarding step to meet. And not a checklist row: the checklist drives the header chip's
/// "permissions off" count, and a missing pick is not a missing permission.
///
/// WHAT IT ASKS: one tap, Apple's own picker, one switch, Save. No naming, no typing, no switch of
/// ours (product rule 2026-09-21). The picker's header already says which switch.
struct ScreenTimeSetupCard: View {
    @ObservedObject private var store = ScreenTimeRestrictedAppsStore.shared
    @ObservedObject private var authorization = ScreenTimeAuthorizationManager.shared
    /// Observed only to close the picker when the lock engages: a sheet already up would keep the
    /// root's lock cover from presenting (the rule every Home presentation follows).
    @ObservedObject private var lockState = OilaTelemetryService.shared

    @State private var isPickerPresented = false
    @State private var draft = FamilyActivitySelection()
    /// The picker's answer, applied once the sheet has gone: applying it inside the sheet would
    /// remove this card — and the `.sheet` it hosts — while the sheet is still on screen.
    @State private var pendingSelection: FamilyActivitySelection?
    /// Home is drawing a usage figure right above this card. See `titleKey`.
    private let showsUsageFigure: Bool

    init(showsUsageFigure: Bool = false) {
        self.showsUsageFigure = showsUsageFigure
    }

    /// Pure, so the rule is pinned by a test. Authorization first: without it the picker has
    /// nothing to hand out, and the header chip already tells the child that permission is off.
    /// Below iOS 17.4 nothing is measured whatever is picked (`ScreenTimeUsageMonitoring`).
    static func isNeeded(
        featuresEnabled: Bool,
        supported: Bool,
        authorization: ScreenTimePermissionStatus,
        hasCategoryTokens: Bool
    ) -> Bool {
        featuresEnabled && supported && authorization == .granted && !hasCategoryTokens
    }

    /// The honest title: a phone that already measures some named apps IS counting — only not the
    /// whole phone — and must not be told "not being counted" under a figure on the same screen.
    ///
    /// Nor may a phone with NO labels, when Home is showing a figure anyway. That was Ibrohim's
    /// screenshot after a re-pair (2026-09-25): "Bugungi ekran vaqti 4s 15d" directly above
    /// "Ekran vaqti hisoblanmayapti". Both were true — the figure is the server's sum of what this
    /// phone uploaded before the unpair, and the unpair wipe had removed the pick, so nothing new was
    /// being measured — but side by side they read as a contradiction. With a figure on screen the
    /// card asks for what it needs ("choose apps to keep it updating") instead of denying the number.
    static func titleKey(hasLabelledApps: Bool, showsUsageFigure: Bool = false) -> String {
        if showsUsageFigure { return "home2.screentime_setup.title_resume" }
        return hasLabelledApps ? "home2.screentime_setup.title_partial" : "home2.screentime_setup.title"
    }

    var body: some View {
        if Self.isNeeded(
            featuresEnabled: AppRuntime.screenTimeFeaturesEnabled,
            supported: ScreenTimeUsageMonitoring.isSupported,
            authorization: authorization.status,
            hasCategoryTokens: !store.selection.categoryTokens.isEmpty
        ) {
            InfoCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 46, height: 46)
                            Image(systemName: "hourglass")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(AppColors.ctaPurple)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr(Self.titleKey(hasLabelledApps: store.labelledCount > 0,
                                                       showsUsageFigure: showsUsageFigure)))
                                .font(AppTypography.bodyStrong(14))
                                .foregroundStyle(AppColors.inkPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.tr("home2.screentime_setup.body"))
                                .font(AppTypography.bodyText(13))
                                .foregroundStyle(AppColors.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    BolajonPrimaryButton(title: L10n.tr("screentime.restricted.pick")) {
                        draft = store.selection
                        isPickerPresented = true
                    }
                }
            }
            .onChange(of: lockState.isLocked) { locked in
                if locked { isPickerPresented = false }
            }
            .sheet(isPresented: $isPickerPresented, onDismiss: applyPendingSelection) {
                ScreenTimeAppPickerView(
                    purpose: .restricted,
                    selection: $draft,
                    onDone: { pendingSelection = $0 }
                )
            }
        }
    }

    private func applyPendingSelection() {
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        store.updateSelection(selection)
    }
}

// MARK: - Home: detected apps nobody has linked yet

/// "N ta ilova belgilanmagan — Belgilash": the Home card for catalogue apps this phone KNOWS about —
/// found installed by the probe, or blocked/limited on the web — that no icon is linked to yet.
///
/// WHY (Ibrohim, 2026-09-25): the parent's web listed Telegram, Instagram and Google Chrome by name,
/// yet every minute of theirs sat under one "ios.other" row. iOS measures and blocks an app only once
/// its icon is linked to the name (Apple's tokens are unreadable — see `ScreenTimeRestrictedAppsStore`),
/// and the only door to that was Settings › restricted apps › "Telefonda topilgan ilovalar" ›
/// Belgilash, which nobody finds. This card puts the door on Home and opens the link queue directly
/// (`ScreenTimeRestrictedAppsView(startsLinkQueue:)`): one tap per app on its own icon. No typing, no
/// switch (product rule 2026-09-21), and no probe — Home reads the list the last probe persisted
/// (`ScreenTimeEnforcementCoordinator.installedEntries`).
///
/// Shown only once the pick exists (link mode needs icons to tap) and never beside the setup card
/// (one ask at a time). "Keyinroq" sets the DETECTED apps aside until a new one is found — but not
/// an app the web has blocked: that block does nothing until the app is linked, so hiding it would
/// hide a rule that is silently not working.
struct ScreenTimeLinkNudgeCard: View {
    @ObservedObject private var store = ScreenTimeRestrictedAppsStore.shared
    @ObservedObject private var authorization = ScreenTimeAuthorizationManager.shared
    @ObservedObject private var telemetry = OilaTelemetryService.shared
    @ObservedObject private var coordinator = ScreenTimeEnforcementCoordinator.shared
    @State private var snoozed: Set<String> = ScreenTimeLinkNudgeCard.storedSnooze()
    private let onLink: () -> Void

    init(onLink: @escaping () -> Void) {
        self.onLink = onLink
    }

    /// Pure, so the rule is pinned by a test. Authorization and the pick first: without them link
    /// mode has nothing to tap. The setup card outranks this one — the pick comes before the names.
    static func isEligible(
        featuresEnabled: Bool,
        authorization: ScreenTimePermissionStatus,
        hasPickedApps: Bool,
        setupCardNeeded: Bool
    ) -> Bool {
        featuresEnabled && authorization == .granted && hasPickedApps && !setupCardNeeded
    }

    /// The number on the card, or nil for no card. The web's apps always count and are never set
    /// aside; the detected ones hide while every one of them was set aside with "Keyinroq".
    static func visibleCount(pendingWeb: [String], pendingInstalled: [String], snoozed: Set<String>) -> Int? {
        if !pendingWeb.isEmpty { return pendingWeb.count + pendingInstalled.count }
        guard !pendingInstalled.isEmpty, !Set(pendingInstalled).isSubset(of: snoozed) else { return nil }
        return pendingInstalled.count
    }

    var body: some View {
        let pending = store.pendingTargetGroups(
            lockedPackages: telemetry.lockedPackages,
            limitedPackages: telemetry.appLimits.map(\.packageName),
            installed: coordinator.installedEntries
        )
        let web = pending.web.map(\.bundleId)
        let installed = pending.installed.map(\.bundleId)
        let eligible = Self.isEligible(
            featuresEnabled: AppRuntime.screenTimeFeaturesEnabled,
            authorization: authorization.status,
            hasPickedApps: !store.rows.isEmpty,
            setupCardNeeded: ScreenTimeSetupCard.isNeeded(
                featuresEnabled: AppRuntime.screenTimeFeaturesEnabled,
                supported: ScreenTimeUsageMonitoring.isSupported,
                authorization: authorization.status,
                hasCategoryTokens: !store.selection.categoryTokens.isEmpty
            )
        )
        if eligible, let count = Self.visibleCount(pendingWeb: web, pendingInstalled: installed, snoozed: snoozed) {
            InfoCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 46, height: 46)
                            Image(systemName: "link")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(AppColors.ctaPurple)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("screentime.nudge.title", count))
                                .font(AppTypography.bodyStrong(14))
                                .foregroundStyle(AppColors.inkPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.tr("screentime.nudge.body"))
                                .font(AppTypography.bodyText(13))
                                .foregroundStyle(AppColors.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    BolajonPrimaryButton(title: L10n.tr("screentime.restricted.guided_cta"), action: onLink)
                    if web.isEmpty {
                        GhostButton(title: L10n.tr("perm2.later")) {
                            snooze(installed)
                        }
                    }
                }
            }
        }
    }

    private func snooze(_ bundleIds: [String]) {
        snoozed.formUnion(bundleIds)
        UserDefaults.standard.set(snoozed.sorted(), forKey: ScreenTimeEnforcementCoordinator.linkNudgeSnoozedKey)
    }

    private static func storedSnooze() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ScreenTimeEnforcementCoordinator.linkNudgeSnoozedKey) ?? [])
    }
}
