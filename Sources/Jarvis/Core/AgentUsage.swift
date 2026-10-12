import Foundation

struct AgentUsageWindow: Equatable, Sendable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct AgentUsageSnapshot: Equatable, Sendable {
    var windows: [AgentUsageWindow]
    var fetchedAt: Date = Date()
    var message: String? = nil
    func isCurrent(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) < 600 && !windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
    }
}

enum AgentUsageParser {
    static func codex(_ data: Data) -> AgentUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let groups = root["rateLimitsByLimitId"] as? [String: [String: Any]]
        let buckets: [(String, [String: Any])]
        if let groups, !groups.isEmpty { buckets = groups.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        else if let legacy = root["rateLimits"] as? [String: Any] { buckets = [(legacy["limitId"] as? String ?? "codex", legacy)] }
        else { return nil }
        var windows: [AgentUsageWindow] = []
        for (id, bucket) in buckets {
            for key in ["primary", "secondary"] {
                guard let raw = bucket[key] as? [String: Any], let used = number(raw["usedPercent"]), used >= 0 else { continue }
                let minutes = number(raw["windowDurationMins"])
                let duration = minutes.map { $0 >= 1440 ? "\(Int($0 / 1440))g" : $0 >= 60 ? "\(Int($0 / 60))h" : "\(Int($0))min" } ?? "Quota"
                let prefix = id == "codex" ? "" : (bucket["limitName"] as? String ?? id) + " · "
                windows.append(AgentUsageWindow(label: prefix + duration, usedPercent: used, resetsAt: number(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))))
            }
        }
        return AgentUsageSnapshot(windows: windows, message: windows.isEmpty ? "Quote non disponibili per questo accesso" : nil)
    }

    static func claude(_ data: Data) -> AgentUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [AgentUsageWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7g"), ("seven_day_sonnet", "Sonnet · 7g"), ("seven_day_opus", "Opus · 7g")] {
            guard let raw = root[key] as? [String: Any], let used = number(raw["utilization"]), used >= 0 else { continue }
            let reset = (raw["resets_at"] as? String).flatMap { value in
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions.insert(.withFractionalSeconds)
                return formatter.date(from: value)
            }
            windows.append(AgentUsageWindow(label: label, usedPercent: used, resetsAt: reset))
        }
        guard !windows.isEmpty || root.keys.contains("five_hour") || root.keys.contains("seven_day") else { return nil }
        return AgentUsageSnapshot(windows: windows, message: windows.isEmpty ? "Quote non pubblicate per questo accesso" : nil)
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}
