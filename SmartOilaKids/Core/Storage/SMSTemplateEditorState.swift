import Combine
import Foundation

@MainActor
final class SMSTemplateEditorState: ObservableObject {
    @Published var draftText: String = ""
    @Published var editingIndex: Int?
    @Published var selectedTemplateIndex: Int?
    @Published var showEditor = false
    @Published var showActionsDialog = false
    @Published var showDeleteAlert = false

    var isDraftEmpty: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginCreate() {
        editingIndex = nil
        draftText = ""
        selectedTemplateIndex = nil
        showEditor = true
    }

    func resetEditor() {
        showEditor = false
        editingIndex = nil
        draftText = ""
        selectedTemplateIndex = nil
    }

    func selectTemplate(at index: Int) {
        selectedTemplateIndex = index
        showActionsDialog = true
    }

    func beginEditingSelectedTemplate(from templates: [String]) {
        guard let selectedTemplateIndex,
              templates.indices.contains(selectedTemplateIndex) else {
            return
        }

        editingIndex = selectedTemplateIndex
        draftText = templates[selectedTemplateIndex]
        showEditor = true
    }

    @discardableResult
    func save(using repository: SMSTemplatesRepository) -> Bool {
        guard repository.upsert(draftText, at: editingIndex) else { return false }
        resetEditor()
        return true
    }

    @discardableResult
    func deleteSelectedTemplate(using repository: SMSTemplatesRepository) -> Bool {
        guard let selectedTemplateIndex,
              repository.templates.indices.contains(selectedTemplateIndex) else {
            return false
        }

        guard repository.delete(at: selectedTemplateIndex) else { return false }
        self.selectedTemplateIndex = nil
        editingIndex = nil
        draftText = ""
        return true
    }
}
