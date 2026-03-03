import Foundation

extension String {
    var digitsOnly: String {
        filter { $0.isNumber }
    }

    var withoutLeadingPlus: String {
        hasPrefix("+") ? String(dropFirst()) : self
    }

    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
