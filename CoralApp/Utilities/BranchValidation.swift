import Foundation

enum BranchValidation {
    /// Validates a git branch name. Returns nil if valid, or an error message string if invalid.
    /// Empty names return nil (treated as "not yet entered").
    static func validate(_ name: String) -> String? {
        if name.isEmpty { return nil }
        if name.contains(" ") { return "Cannot contain spaces" }
        if name.contains("..") { return "Cannot contain '..'" }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "Cannot start or end with '/'" }
        if name.hasPrefix(".") || name.hasSuffix(".") { return "Cannot start or end with '.'" }
        if name.hasSuffix(".lock") { return "Cannot end with '.lock'" }
        let forbidden: [Character] = ["~", "^", ":", "?", "*", "[", "\\"]
        for char in forbidden {
            if name.contains(char) { return "Cannot contain '\(char)'" }
        }
        if name.contains("@{") { return "Cannot contain '@{'" }
        return nil
    }
}
