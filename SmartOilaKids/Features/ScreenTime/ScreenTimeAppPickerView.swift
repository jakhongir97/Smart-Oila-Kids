import FamilyControls
import SwiftUI

/// The app picker. Without this, nothing in the Screen Time module can ever do anything.
///
/// THE REASON THIS EXISTS. `FamilyActivityPicker` appeared nowhere in the tree, so
/// `DeviceAppLockSelectionStore`'s selection was permanently empty, `applySelectiveShield` always
/// received zero tokens, and every per-app limit had no app to apply to. Roughly five thousand
/// lines of lock/limit/usage code were reachable only through a selection that could never be made.
///
/// WHY THE SELECTION HAS TO HAPPEN HERE, ON THE CHILD'S PHONE. Apple mints `ApplicationToken`s only
/// through this picker, only on the authorized device, and they are opaque and non-transferable —
/// there is no bundle-id → token API and a token means nothing off the device that created it. So a
/// parent cannot choose "block Instagram" from the web dashboard or from their own phone, the way
/// they can on Android where a package name is just a string. The rules (schedules, budgets, on/off)
/// travel from the parent through the backend; only the app SELECTION is pinned here.
///
/// The intended flow is that the parent does this once while holding the child's phone during
/// pairing.
struct ScreenTimeAppPickerView: View {
    enum Purpose {
        /// Apps the parent wants blocked or limited.
        case restricted
        /// Apps that stay reachable while a global shield is up. See ScreenTimeAlwaysAllowedStore —
        /// without this set a global lock covers Phone, Messages and this app itself.
        case alwaysAllowed
    }

    let purpose: Purpose
    @Binding var selection: FamilyActivitySelection
    var onDone: (FamilyActivitySelection) -> Void
    /// The guided step: the picker was opened to link ONE named app. The title and hint say which,
    /// and Save stays disabled until exactly one new app is ticked — so an ambiguous tick cannot
    /// be saved in the first place.
    var guidedName: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var draft = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            // The header is the only text Apple lets us put INSIDE the picker. For the restricted
            // set it tells the parent the one switch that yields every app's token at once.
            FamilyActivityPicker(headerText: headerText, footerText: nil, selection: $draft)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) { explanation }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("common.cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("common.save")) {
                            selection = draft
                            onDone(draft)
                            dismiss()
                        }
                        // An EMPTY always-allowed set is not a valid configuration — it excepts
                        // nothing, which is the state that put Phone behind the shield. Saving one
                        // is blocked rather than accepted-and-ignored, so the parent finds out here
                        // instead of when their child cannot call them.
                        .disabled(!Self.saveAllowed(draft: draft, previous: selection, purpose: purpose, guided: guidedName != nil))
                    }
                }
        }
        .onAppear { draft = Self.draft(from: selection, purpose: purpose) }
    }

    /// The picker draft. For the restricted set `includeEntireCategory` is ON: a parent who flips
    /// the big "All Apps & Categories" switch, or ticks a whole category, then gets every app in it
    /// as an APPLICATION token — which is the only kind that can be labelled, blocked one by one
    /// and measured. Without it the same taps yield category tokens only, and the label list is
    /// empty (measured 2026-09-16: `selection apps=0 categories=13`). The flag is `let` on
    /// `FamilyActivitySelection`, so a stored selection is re-created around its tokens.
    static func draft(from selection: FamilyActivitySelection, purpose: Purpose) -> FamilyActivitySelection {
        guard purpose == .restricted, !selection.includeEntireCategory else { return selection }
        var expanded = FamilyActivitySelection(includeEntireCategory: true)
        expanded.applicationTokens = selection.applicationTokens
        expanded.categoryTokens = selection.categoryTokens
        expanded.webDomainTokens = selection.webDomainTokens
        return expanded
    }

    /// Whether the Save button is live. An EMPTY always-allowed set is refused (it excepts nothing,
    /// which is the state that put Phone behind the shield). A guided pick is refused unless exactly
    /// ONE app was added: zero means nothing to link, two means the app cannot tell which is which.
    static func saveAllowed(
        draft: FamilyActivitySelection,
        previous: FamilyActivitySelection,
        purpose: Purpose,
        guided: Bool
    ) -> Bool {
        if purpose == .alwaysAllowed, draft.applicationTokens.isEmpty { return false }
        if guided { return draft.applicationTokens.subtracting(previous.applicationTokens).count == 1 }
        return true
    }

    private var title: String {
        if let guidedName { return L10n.tr("screentime.picker.guided.title", guidedName) }
        switch purpose {
        case .restricted: return L10n.tr("screentime.picker.restricted.title")
        case .alwaysAllowed: return L10n.tr("screentime.picker.allowed.title")
        }
    }

    private var headerText: String? {
        if guidedName != nil { return nil }
        return purpose == .restricted ? L10n.tr("screentime.picker.restricted.header") : nil
    }

    private var hint: String {
        if let guidedName { return L10n.tr("screentime.picker.guided.hint", guidedName) }
        return purpose == .alwaysAllowed
            ? L10n.tr("screentime.picker.allowed.hint")
            : L10n.tr("screentime.picker.restricted.hint")
    }

    @ViewBuilder
    private var explanation: some View {
        Text(hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
    }
}
