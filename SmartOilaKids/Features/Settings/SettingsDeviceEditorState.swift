import Combine
import Foundation

struct SettingsDeviceEditorState {
    var isPresented = false
    var device: ConnectedDevice?
    var name: String = ""

    mutating func beginEditing(_ device: ConnectedDevice) {
        self.device = device
        self.name = device.name
        self.isPresented = true
    }

    mutating func clearSelection() {
        device = nil
    }

    mutating func close() {
        isPresented = false
        device = nil
        name = ""
    }
}

extension Notification.Name {
    static let smsTemplatesDidChange = Notification.Name("smsTemplatesDidChange")
}

enum SMSTemplatesStore {
    private static let storageKey = "SMS_TEMPLATES"

    static func load(userDefaults: UserDefaults) -> [String] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return defaultTemplates()
        }

        let normalized = decoded.compactMap(normalizedTemplate)
        return normalized.isEmpty ? defaultTemplates() : normalized
    }

    static func save(_ templates: [String], userDefaults: UserDefaults) {
        let normalized = templates.compactMap(normalizedTemplate)
        guard !normalized.isEmpty,
              let data = try? JSONEncoder().encode(normalized) else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }

        userDefaults.set(data, forKey: storageKey)
    }

    static func normalizedTemplate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func upsert(_ template: String, at index: Int?, in templates: [String]) -> [String] {
        guard let normalized = normalizedTemplate(template) else {
            return templates
        }

        var updated = templates
        if let index {
            guard updated.indices.contains(index) else {
                return templates
            }
            updated[index] = normalized
        } else {
            updated.append(normalized)
        }
        return updated
    }

    static func delete(at index: Int, in templates: [String]) -> [String] {
        guard templates.indices.contains(index) else {
            return templates
        }

        var updated = templates
        updated.remove(at: index)
        return updated
    }

    private static func defaultTemplates() -> [String] {
        [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ]
    }
}

@MainActor
final class SMSTemplatesRepository: ObservableObject {
    @Published private(set) var templates: [String]

    init(
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        self.templates = SMSTemplatesStore.load(userDefaults: userDefaults)
        observer = notificationCenter.addObserver(
            forName: .smsTemplatesDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    @discardableResult
    func upsert(_ template: String, at index: Int?) -> Bool {
        let updated = SMSTemplatesStore.upsert(template, at: index, in: templates)
        guard updated != templates else {
            return false
        }

        templates = updated
        SMSTemplatesStore.save(updated, userDefaults: userDefaults)
        notificationCenter.post(name: .smsTemplatesDidChange, object: nil)
        return true
    }

    @discardableResult
    func delete(at index: Int) -> Bool {
        let updated = SMSTemplatesStore.delete(at: index, in: templates)
        guard updated != templates else {
            return false
        }

        templates = updated
        SMSTemplatesStore.save(updated, userDefaults: userDefaults)
        notificationCenter.post(name: .smsTemplatesDidChange, object: nil)
        return true
    }

    func refresh() {
        templates = SMSTemplatesStore.load(userDefaults: userDefaults)
    }

    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
}

@MainActor
final class SMSTemplateEditorState: ObservableObject {
    @Published var showEditor = false
    @Published var showActionsDialog = false
    @Published var showDeleteAlert = false
    @Published var selectedTemplateIndex: Int?
    @Published var editingIndex: Int?
    @Published var draftText = ""

    var isDraftEmpty: Bool {
        SMSTemplatesStore.normalizedTemplate(draftText) == nil
    }

    func beginCreate() {
        showEditor = true
        showActionsDialog = false
        showDeleteAlert = false
        selectedTemplateIndex = nil
        editingIndex = nil
        draftText = ""
    }

    func selectTemplate(at index: Int) {
        guard index >= 0 else {
            selectedTemplateIndex = nil
            showActionsDialog = false
            showDeleteAlert = false
            return
        }

        selectedTemplateIndex = index
        showActionsDialog = true
        showDeleteAlert = false
    }

    func beginEditingSelectedTemplate(from templates: [String]) {
        guard let selectedTemplateIndex,
              templates.indices.contains(selectedTemplateIndex) else {
            editingIndex = nil
            draftText = ""
            return
        }

        editingIndex = selectedTemplateIndex
        draftText = templates[selectedTemplateIndex]
        showEditor = true
        showActionsDialog = false
        showDeleteAlert = false
    }

    @discardableResult
    func save(using repository: SMSTemplatesRepository) -> Bool {
        let didSave = repository.upsert(draftText, at: editingIndex)
        guard didSave else {
            return false
        }

        resetEditor()
        return true
    }

    @discardableResult
    func deleteSelectedTemplate(using repository: SMSTemplatesRepository) -> Bool {
        guard let selectedIndex = selectedTemplateIndex else {
            return false
        }

        let didDelete = repository.delete(at: selectedIndex)
        guard didDelete else {
            return false
        }

        selectedTemplateIndex = nil
        editingIndex = nil
        draftText = ""
        showActionsDialog = false
        showDeleteAlert = false
        showEditor = false
        return true
    }

    func resetEditor() {
        showEditor = false
        showActionsDialog = false
        showDeleteAlert = false
        selectedTemplateIndex = nil
        editingIndex = nil
        draftText = ""
    }
}
