import SwiftUI

struct TemplatesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [String] = SMSTemplatesStore.load()
    @State private var draftText: String = ""
    @State private var editingIndex: Int?
    @State private var showEditor = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(30, max(16, proxy.size.width * 0.06))
            let editorWidth = min(420, max(280, proxy.size.width - (sidePadding * 2)))
            let editorHeight = min(190, max(150, proxy.size.height * 0.22))

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("templates.title"),
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: {
                            Button {
                                AppHaptics.tap()
                                editingIndex = nil
                                draftText = ""
                                showEditor = true
                                isEditorFocused = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(AppColors.black)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("templates.add"))
                        }
                    )

                    ChildPurpleSurface {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(templates.indices, id: \.self) { index in
                                    templateRow(text: templates[index], index: index)
                                }
                            }
                            .padding(.horizontal, sidePadding)
                            .padding(.top, 30)
                            .padding(.bottom, max(20, proxy.safeAreaInsets.bottom + 8))
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }

                ChildWatermarkOverlay()

                if showEditor {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            AppHaptics.tap()
                            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                showEditor = false
                            } else {
                                saveTemplate()
                            }
                        }

                    VStack {
                        editorCard(width: editorWidth, height: editorHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, proxy.safeAreaInsets.bottom * 0.4)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: showEditor) { isPresented in
            if isPresented {
                DispatchQueue.main.async {
                    isEditorFocused = true
                }
            } else {
                isEditorFocused = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) {
                    saveTemplate()
                    isEditorFocused = false
                }
            }
        }
    }

    private func templateRow(text: String, index: Int) -> some View {
        HStack {
            Text(text)
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(AppColors.black)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer()

            Button {
                AppHaptics.selection()
                editingIndex = index
                draftText = text
                showEditor = true
                isEditorFocused = true
            } label: {
                VStack(spacing: 2) {
                    Circle().fill(AppColors.black).frame(width: 4, height: 4)
                    Circle().fill(AppColors.black).frame(width: 4, height: 4)
                    Circle().fill(AppColors.black).frame(width: 4, height: 4)
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("templates.edit_action"))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func editorCard(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 14) {
            Text(editingIndex == nil ? L10n.tr("templates.create") : L10n.tr("templates.edit"))
                .font(AppTypography.unbounded(20, weight: .semibold))
                .foregroundStyle(AppColors.black)

            TextField(L10n.tr("templates.input_placeholder"), text: $draftText)
                .font(AppTypography.unbounded(16, weight: .medium))
                .padding(.horizontal, 15)
                .frame(height: 60)
                .focused($isEditorFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit {
                    saveTemplate()
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppColors.textSecondary, lineWidth: 3)
                }
        }
        .padding(.horizontal, 20)
        .frame(width: width, height: height)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func saveTemplate() {
        let value = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        if let editingIndex {
            templates[editingIndex] = value
        } else {
            templates.append(value)
        }

        SMSTemplatesStore.save(templates)
        AppHaptics.success()
        showEditor = false
    }
}
