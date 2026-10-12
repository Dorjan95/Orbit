import Foundation

/// §3.8 — plain JSON files in the per-user app-data directory.
enum AppPaths {
    static let root: URL = {
        // Under XCTest or Swift Testing (or JARVIS_DATA_DIR), use an isolated directory so tests can never clobber the user's real projects/sessions/memory.
        // Swift Testing has no XCTestCase class: SwiftPM runs it through swiftpm-testing-helper with --test-bundle-path.
        let env = ProcessInfo.processInfo.environment
        let underTest = NSClassFromString("XCTestCase") != nil || env["XCTestConfigurationFilePath"] != nil
            || CommandLine.arguments.contains("--test-bundle-path") || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
        let override = env["JARVIS_DATA_DIR"] ?? (underTest ? NSTemporaryDirectory() + "JarvisTests-\(ProcessInfo.processInfo.processIdentifier)" : nil)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? base.appendingPathComponent("Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        return dir
    }()
    static var projects: URL { root.appendingPathComponent("projects.json") }
    static var sessions: URL { root.appendingPathComponent("sessions.json") }
    static var settings: URL { root.appendingPathComponent("settings.json") }
    static var memory: URL { root.appendingPathComponent("memory.json") }
    static var conversation: URL { root.appendingPathComponent("conversation.json") }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static func log(for sessionID: String) -> URL { logs.appendingPathComponent("\(sessionID).ndjson") }
}

/// Crash-safe JSON persistence: encode → write temp → atomic rename.
enum JSONStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Append-only diagnostic log (rotated at 1 MB).
enum AppLog {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()
    static func write(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let url = AppPaths.logs.appendingPathComponent("app.log")
        if handle == nil {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url); handle?.seekToEndOfFile()
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle?.write(Data("\(stamp) \(msg)\n".utf8))
    }
}
