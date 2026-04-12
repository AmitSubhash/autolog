import Foundation

enum LaunchAgentControl {
    private static let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ContextD/launch-agent", isDirectory: true)
    private static let gracefulQuitURL = stateDirectory.appendingPathComponent("user-quit")

    static func markGracefulQuitRequest() {
        try? FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: gracefulQuitURL.path) {
            FileManager.default.createFile(atPath: gracefulQuitURL.path, contents: Data())
        }
    }

    static func clearGracefulQuitRequest() {
        try? FileManager.default.removeItem(at: gracefulQuitURL)
    }
}
