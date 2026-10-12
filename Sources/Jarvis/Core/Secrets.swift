import Foundation
import Security

/// API keys live in `~/Library/Application Support/Jarvis/secrets/`, one file per key, readable only by you (0600 in a 0700 folder).
///
/// Not the Keychain: Jarvis is signed with a local certificate that has no Apple Team ID, so macOS files its Keychain
/// items under the build's cdhash and asks for the login password again after every rebuild (and on every read when
/// the item was added with the `security` CLI). Never in the code, never in settings.json, never in the logs.
enum Secrets {
    static let fishKey = "fish-audio-api-key"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static var dir: URL { AppPaths.root.appendingPathComponent("secrets", isDirectory: true) }
    private static func file(_ account: String) -> URL { dir.appendingPathComponent(account) }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[account] { return hit }
        let v = (try? String(contentsOf: file(account), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (v?.isEmpty ?? true) ? nil : v
        cache[account] = .some(value)
        return value
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        cache[account] = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let f = file(account)
            if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
            try Data(value.utf8).write(to: f)
            return true
        } catch {
            AppLog.write("secrets write \(account) failed: \(error.localizedDescription)")
            return false
        }
    }

    static func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = nil
        try? FileManager.default.removeItem(at: file(account))
    }

    /// One-time moves at launch: a `fish-key.import` file dropped in the data folder, then a key still sitting in the
    /// Keychain from older builds (read without UI, so no password prompt; left alone if macOS would ask).
    static func migrate() {
        for (file, account) in [("fish-key.import", fishKey)] {
            let drop = AppPaths.root.appendingPathComponent(file)
            guard let raw = try? String(contentsOf: drop, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: drop)
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { AppLog.write("secrets: \(account) imported from file, stored=\(set(key, for: account))") }
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "ai.martes.jarvis",
                                kSecAttrAccount as String: fishKey,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return }
        if get(fishKey) == nil { set(key, for: fishKey) }
        var del = q; del.removeValue(forKey: kSecReturnData as String); del.removeValue(forKey: kSecMatchLimit as String)
        AppLog.write("secrets: fish key moved out of the Keychain, delete=\(SecItemDelete(del as CFDictionary))")
    }
}
