import Foundation

/// Simple file-based storage for the API key.
/// Stored at ~/Library/Application Support/AutoLog/api_key.
/// No Keychain, no password prompts.
enum KeychainHelper {
    private static let logger = DualLogger(category: "APIKeyStore")

    private static var storageDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ContextD", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        storageDir.appendingPathComponent(key)
    }

    static func save(key: String, value: String) throws {
        let dir = storageDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        try value.write(to: url, atomically: true, encoding: .utf8)
        // Restrict to owner-only read/write
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        logger.debug("Saved key '\(key)' to file")
    }

    static func read(key: String) -> String? {
        let url = fileURL(for: key)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func delete(key: String) {
        let url = fileURL(for: key)
        try? FileManager.default.removeItem(at: url)
        logger.debug("Deleted key '\(key)'")
    }

    static func exists(key: String) -> Bool {
        read(key: key) != nil
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value"
        case .saveFailed(let status):
            return "Save failed with status: \(status)"
        }
    }
}
