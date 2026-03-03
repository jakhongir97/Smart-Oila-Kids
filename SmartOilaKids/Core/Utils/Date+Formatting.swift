import Foundation

extension Date {
    func formattedLegacyClientDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: self)
    }
}
