import SwiftUI

struct ChatTemplatesSheet: View {
    let onClose: () -> Void
    let onSendTemplate: (String) async -> Bool

    @StateObject private var templatesRepository = SMSTemplatesRepository()
    @StateObject private var editorState = SMSTemplateEditorState()
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatTemplatesSheetHeader(
                onAdd: {
                    AppHaptics.tap()
                    beginCreateTemplate()
                },
                onClose: {
                    AppHaptics.tap()
                    onClose()
                }
            )

            if editorState.showEditor {
                ChatTemplatesEditorSection(
                    draftText: $editorState.draftText,
                    isEditing: editorState.editingIndex != nil,
                    isDraftEmpty: editorState.isDraftEmpty,
                    focus: $isEditorFocused,
                    onSave: saveTemplate,
                    onCancel: {
                        AppHaptics.tap()
                        resetEditor()
                    }
                )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            if templatesRepository.templates.isEmpty {
                Text(L10n.tr("chat.template_empty"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(templatesRepository.templates.enumerated()), id: \.offset) { index, template in
                            ChatTemplateRowView(
                                template: template,
                                onSend: {
                                    Task {
                                        let sent = await onSendTemplate(template)
                                        if sent {
                                            onClose()
                                        }
                                    }
                                },
                                onMore: {
                                    AppHaptics.selection()
                                    editorState.selectTemplate(at: index)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            reloadTemplates()
        }
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

    private func reloadTemplates() {
        templatesRepository.refresh()
    }

    private func beginCreateTemplate() {
        editorState.beginCreate()
    }

    private func resetEditor() {
        editorState.resetEditor()
    }

    private func saveTemplate() {
        guard editorState.save(using: templatesRepository) else { return }
        AppHaptics.success()
    }

    private func beginEditingSelectedTemplate() {
        editorState.beginEditingSelectedTemplate(from: templatesRepository.templates)
    }

    private func deleteSelectedTemplate() {
        guard editorState.deleteSelectedTemplate(using: templatesRepository) else { return }
        AppHaptics.success()
    }
}
