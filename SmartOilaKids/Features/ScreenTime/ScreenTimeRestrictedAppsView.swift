import FamilyControls
import ManagedSettings
import SwiftUI

/// The one-time setup that makes per-app blocking and per-app screen time possible on an iPhone.
///
/// Step 1 — pick apps in Apple's `FamilyActivityPicker` (the only source of `ApplicationToken`s).
/// Step 2 — for each picked icon, tap which app it is. `Label(token)` draws the real icon and name
/// for the parent; the app itself cannot read either (see `ScreenTimeRestrictedAppsStore`), so the
/// parent's tap is what joins the icon to the bundle id the server blocks and counts by.
///
/// Rows without a label are shown, not hidden: they are the apps a parent asked about that iOS
/// will not yet act on, and the count is the honest state of the feature.
struct ScreenTimeRestrictedAppsView: View {
    @ObservedObject private var store = ScreenTimeRestrictedAppsStore.shared
    @ObservedObject private var authorization = ScreenTimeAuthorizationManager.shared

    @State private var isPickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    /// The row whose label sheet is open.
    @State private var labelling: ScreenTimeRestrictedAppsStore.Row?

    var body: some View {
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

                BolajonPrimaryButton(
                    title: L10n.tr(store.rows.isEmpty ? "screentime.restricted.pick" : "screentime.restricted.pick_again"),
                    disabled: authorization.status != .granted
                ) {
                    draftSelection = store.selection
                    isPickerPresented = true
                }

                if store.hasOnlyCategories {
                    InfoCard {
                        Text(L10n.tr("screentime.restricted.only_categories"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.sosCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !store.rows.isEmpty {
                    Text(L10n.tr("screentime.restricted.label_hint"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)

                    // Lazy: `Label(token)` is drawn out-of-process, and a parent who flipped the
                    // "All Apps" switch has dozens of rows.
                    LazyVStack(spacing: 10) {
                        ForEach(store.rows) { row in
                            appRow(row)
                        }
                    }

                    summary

                    if !ScreenTimeUsageMonitoring.isSupported {
                        Text(L10n.tr("screentime.restricted.usage_unsupported"))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                    if store.rows.count > ScreenTimeUsageMonitoring.maximumEvents {
                        Text(L10n.tr("screentime.restricted.too_many", ScreenTimeUsageMonitoring.maximumEvents))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.sosCoral)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            ScreenTimeAppPickerView(
                purpose: .restricted,
                selection: $draftSelection,
                onDone: { selection in store.updateSelection(selection) }
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
        .onAppear { authorization.refreshStatus() }
    }

    private func appRow(_ row: ScreenTimeRestrictedAppsStore.Row) -> some View {
        Button {
            AppHaptics.selection()
            labelling = row
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
                    Text(row.name ?? L10n.tr("screentime.restricted.unlabelled"))
                        .font(AppTypography.bodyStrong(13))
                        .foregroundStyle(row.isLabelled ? AppColors.pillGreenInk : AppColors.sosCoral)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var summary: some View {
        Text(L10n.tr("screentime.restricted.summary", store.labelledCount, store.unlabelledCount))
            .font(AppTypography.bodyText(13))
            .foregroundStyle(store.unlabelledCount == 0 ? AppColors.inkSecondary : AppColors.sosCoral)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
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
            installed = Set(InstalledAppProbe.installedEntries(canOpen: ScreenTimeEnforcementCoordinator.shared.canOpenScheme).map(\.bundleId))
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
