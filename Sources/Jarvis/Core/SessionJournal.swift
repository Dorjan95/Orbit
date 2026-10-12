import Foundation

enum TurnState: String, Codable, Sendable {
    case queued, dispatched, completed, failed, blocked, cancelled, interrupted
}

enum BackendTurnOutcome: String, Codable, Hashable, Sendable {
    case completed, blocked, failed, cancelled, interrupted
}

/// A request keeps its identity and execution settings from acceptance to completion.
struct SessionTurn: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var task: String
    var configuration: AgentExecutionConfiguration
    var guidance: String?
    var state: TurnState = .queued
    var createdAt: Date = Date()
    var dispatchedAt: Date?
    var cancellationRequestedAt: Date?
    var finishedAt: Date?
    var exitCode: Int32?
    var backendOutcome: BackendTurnOutcome?
    var workflowStage: WorkflowStage? = nil
    var resultText: String? = nil
    /// Nil in old workflows means the original attempt (zero).
    var workflowAttempt: Int? = nil
    var workflowNodeID: String? = nil
    var repairSourceTurnID: UUID? = nil
}

enum SessionEventKind: String, Codable, Sendable {
    case migrated, accepted, dispatched, processStarted, backendIdentified, blocked, result, finished, cancelled, recovered, updated
    case approvalRequested, approvalDecided, approvalExpired
    case steeringRequested, planApproved, planRejected
}

/// Each lifecycle event includes a projection, so recovery does not depend on a
/// possibly stale sessions.json. Raw streaming output remains in the CLI log.
struct SessionJournalEvent: Codable, Sendable {
    var version: Int = 1
    var sequence: Int
    var at: Date = Date()
    var kind: SessionEventKind
    var turnID: UUID?
    var session: Session
}

enum SessionJournalError: LocalizedError {
    case corrupt(Int), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .corrupt(let line): "Registro delle sessioni non valido alla riga \(line)."
        case .unavailable(let detail): "Impossibile salvare le sessioni: \(detail)"
        }
    }
}

/// Main-actor-owned append-only journal. Flush before launching an external
/// process; a dispatched request is never automatically retried after a crash.
final class SessionJournal {
    let url: URL
    private(set) var sequence = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) { self.url = url }

    /// Import the whole legacy snapshot atomically. A crash halfway through a
    /// per-session import must not make the remaining legacy sessions disappear.
    func bootstrap(_ sessions: [Session]) throws {
        guard !sessions.isEmpty else { return }
        guard sequence == 0 else { throw SessionJournalError.unavailable("Registro già inizializzato.") }
        var data = Data()
        for (index, session) in sessions.enumerated() {
            data.append(try encoder.encode(SessionJournalEvent(sequence: index + 1, kind: .migrated, session: session)))
            data.append(10)
        }
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        sequence = sessions.count
    }

    func replay() throws -> [SessionJournalEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let completeEnd = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
        let complete = data.prefix(completeEnd)
        var events: [SessionJournalEvent] = []
        for (index, line) in complete.split(separator: 10, omittingEmptySubsequences: false).dropLast().enumerated() {
            guard let event = try? decoder.decode(SessionJournalEvent.self, from: Data(line)),
                  event.version == 1, event.sequence == events.count + 1 else {
                throw SessionJournalError.corrupt(index + 1)
            }
            events.append(event)
        }
        // Only an unsealed tail may be discarded. Corrupt complete records block writes.
        if completeEnd < data.count {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(completeEnd))
            try handle.synchronize()
        }
        sequence = events.last?.sequence ?? 0
        return events
    }

    func append(_ session: Session, kind: SessionEventKind, turnID: UUID? = nil) throws {
        let event = SessionJournalEvent(sequence: sequence + 1, kind: kind, turnID: turnID, session: session)
        var data = try encoder.encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            sequence += 1
        } catch {
            // Keep subsequent writes from following a partial record.
            try? handle.truncate(atOffset: offset)
            throw error
        }
    }
}
