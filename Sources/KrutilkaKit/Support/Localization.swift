import Foundation

/// Looks a string up in Localizable.strings. English text is the key, so a missing translation
/// still reads fine.
func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// `tr` with `String(format:)` arguments, e.g. `trf("%d files", 3)`.
func trf(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}

/// "1 file" / "3 files" with Russian plural forms handled by hand (no .stringsdict needed).
func filesCount(_ n: Int) -> String {
    let lang = Bundle.main.preferredLocalizations.first ?? "en"
    if lang.hasPrefix("ru") {
        let m10 = n % 10, m100 = n % 100
        let word: String
        if m10 == 1 && m100 != 11 { word = "файл" }
        else if (2...4).contains(m10) && !(12...14).contains(m100) { word = "файла" }
        else { word = "файлов" }
        return "\(n) \(word)"
    }
    return n == 1 ? "1 file" : "\(n) files"
}

/// Opt-in trace for gesture debugging: `defaults write com.vldvr.krutilka debugLog -bool true`,
/// then read ~/Library/Logs/Krutilka.log.
enum DebugLog {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Krutilka.log")

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(message())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
