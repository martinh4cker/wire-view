import Foundation

func tr(_ key: String, arguments: [CVarArg] = []) -> String {
    let value = NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
    guard !arguments.isEmpty else { return value }
    return String(format: value, locale: Locale.current, arguments: arguments)
}
