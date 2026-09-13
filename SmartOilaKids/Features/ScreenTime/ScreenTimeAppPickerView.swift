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

    @Environment(\.dismiss) private var dismiss
    @State private var draft = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $draft)
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
                        .disabled(purpose == .alwaysAllowed && draft.applicationTokens.isEmpty)
                    }
                }
        }
        .onAppear { draft = selection }
    }

    private var title: String {
        switch purpose {
        case .restricted: return L10n.tr("screentime.picker.restricted.title")
        case .alwaysAllowed: return L10n.tr("screentime.picker.allowed.title")
        }
    }

    @ViewBuilder
    private var explanation: some View {
        Text(purpose == .alwaysAllowed
             ? L10n.tr("screentime.picker.allowed.hint")
             : L10n.tr("screentime.picker.restricted.hint"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
    }
}
