import SwiftUI

struct TemplatesView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var templatesRepository = SMSTemplatesRepository()
    @StateObject private var editorState = SMSTemplateEditorState()
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
                                editorState.beginCreate()
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
                                ForEach(templatesRepository.templates.indices, id: \.self) { index in
                                    templateRow(text: templatesRepository.templates[index], index: index)
                                }
                            }
                            .padding(.horizontal, sidePadding)
                            .padding(.top, 30)
                            .padding(.bottom, max(20, proxy.safeAreaInsets.bottom + 8))
                        }
                        .appInteractiveKeyboardDismiss()
                    }
                }

                ChildWatermarkOverlay()

                if editorState.showEditor {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            AppHaptics.tap()
                            if editorState.isDraftEmpty {
                                editorState.resetEditor()
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
        .onChange(of: editorState.showEditor) { isPresented in
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
        .confirmationDialog(
            L10n.tr("templates.actions_title"),
            isPresented: $editorState.showActionsDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("templates.edit")) {
                beginEditingSelectedTemplate()
            }

            Button(L10n.tr("templates.delete"), role: .destructive) {
                editorState.showDeleteAlert = true
            }

            Button(L10n.tr("common.cancel"), role: .cancel) {
                editorState.selectedTemplateIndex = nil
            }
        }
        .alert(L10n.tr("templates.delete_title"), isPresented: $editorState.showDeleteAlert) {
            Button(L10n.tr("templates.delete"), role: .destructive) {
                deleteSelectedTemplate()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                editorState.selectedTemplateIndex = nil
            }
        } message: {
            Text(L10n.tr("templates.delete_message"))
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
                editorState.selectTemplate(at: index)
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
            Text(editorState.editingIndex == nil ? L10n.tr("templates.create") : L10n.tr("templates.edit"))
                .font(AppTypography.unbounded(20, weight: .semibold))
                .foregroundStyle(AppColors.black)

            TextField(L10n.tr("templates.input_placeholder"), text: $editorState.draftText)
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
        guard editorState.save(using: templatesRepository) else { return }
        AppHaptics.success()
    }

    private func beginEditingSelectedTemplate() {
        editorState.beginEditingSelectedTemplate(from: templatesRepository.templates)
        isEditorFocused = true
    }

    private func deleteSelectedTemplate() {
        guard editorState.deleteSelectedTemplate(using: templatesRepository) else { return }
        AppHaptics.success()
    }
}
