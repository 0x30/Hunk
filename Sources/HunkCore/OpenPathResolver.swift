import Foundation

/// Normalizes paths received from command-line and external open requests.
public enum OpenPathResolver {
    public static func resolve(
        _ path: String,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard !path.isEmpty else { return nil }

        let expanded: String
        if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }

        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : currentDirectory.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }
}
