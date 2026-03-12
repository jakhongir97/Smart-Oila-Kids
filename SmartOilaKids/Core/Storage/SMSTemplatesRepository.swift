import Combine
import Foundation

extension Notification.Name {
    static let smsTemplatesDidChange = Notification.Name("smsTemplatesDidChange")
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

        notificationCenter.addObserver(
            self,
            selector: #selector(handleTemplatesDidChange),
            name: .smsTemplatesDidChange,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func refresh() {
        templates = SMSTemplatesStore.load(userDefaults: userDefaults)
    }

    @discardableResult
    func upsert(_ text: String, at index: Int?) -> Bool {
        let updated = SMSTemplatesStore.upsert(text, at: index, in: templates)
        guard updated != templates else { return false }
        templates = updated
        persist()
        return true
    }

    @discardableResult
    func delete(at index: Int) -> Bool {
        let updated = SMSTemplatesStore.delete(at: index, in: templates)
        guard updated != templates else { return false }
        templates = updated
        persist()
        return true
    }

    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter

    private func persist() {
        SMSTemplatesStore.save(templates, userDefaults: userDefaults)
        notificationCenter.post(name: .smsTemplatesDidChange, object: nil)
    }

    @objc
    private func handleTemplatesDidChange() {
        let latest = SMSTemplatesStore.load(userDefaults: userDefaults)
        guard latest != templates else { return }
        templates = latest
    }
}
