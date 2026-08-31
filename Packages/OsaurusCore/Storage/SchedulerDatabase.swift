//
//  SchedulerDatabase.swift
//  osaurus
//
//  Cross-agent scheduler state for the Agent DB + Self-Scheduling feature.
//  Owns three tables (`agent_next_run`, `agent_runs`, `agent_pause`) per
//  spec §4.2. One file at `~/.osaurus/scheduler.sqlite`, not per-agent —
//  the scheduler tick reads across all agents every second and the
//  Activity dashboard is naturally cross-agent. Encrypted via the same
//  vendored SQLCipher + `StorageKeyManager` setup the rest of the
//  Osaurus stack uses, so prompts / instructions / error messages in
//  this file are protected at rest.
//
//  Foreign keys to `agents(id)` are not declared because agents live in
//  JSON files. The dispatcher does an "orphan" check on read and
//  `deleteAllForAgent` cleans up when the user deletes an agent.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum SchedulerDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case runNotFound(UUID)
    case runAlreadyEnded(UUID, AgentRunStatus)
    case invalidRunTransition(UUID, String)
    case invalidRunRelationship(UUID, String)
    case agentDeletionBlocked(UUID)
    case corruptRun(String)
    case corruptRunEvent(UUID, String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open scheduler database: \(m)"
        case .failedToExecute(let m): return "Failed to execute scheduler query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare scheduler statement: \(m)"
        case .migrationFailed(let m): return "Scheduler migration failed: \(m)"
        case .runNotFound(let id): return "Run \(id.uuidString) was not found"
        case .runAlreadyEnded(let id, let status):
            return "Run \(id.uuidString) already ended with status \(status.rawValue)"
        case .invalidRunTransition(let id, let message):
            return "Invalid transition for run \(id.uuidString): \(message)"
        case .invalidRunRelationship(let id, let message):
            return "Invalid relationship for run \(id.uuidString): \(message)"
        case .agentDeletionBlocked(let id):
            return "Agent \(id.uuidString) owns runs that are parents or roots of another agent's runs"
        case .corruptRun(let message):
            return "Corrupt run row: \(message)"
        case .corruptRunEvent(let id, let message):
            return "Corrupt event stream for run \(id.uuidString): \(message)"
        case .notOpen: return "Scheduler database is not open"
        }
    }
}

// MARK: - Domain types

/// Lower priority means the scheduler dispatcher may shed this run when
/// host concurrency limits are saturated.
public enum NextRunPriority: String, Codable, Sendable, CaseIterable {
    case normal
    case low
}

/// How the dispatcher should handle a scheduled run whose `scheduled_at`
/// already drifted past `now + staleThreshold` (spec §9.2).
public enum NextRunOnMiss: String, Codable, Sendable, CaseIterable {
    /// Drop the run silently; log it in `agent_runs` as `cancelled`.
    case skip
    /// Run immediately with the original instruction, even if late.
    case runOnce = "run_once"
    /// Run N times, once per missed interval. Rare; for ledger-type agents.
    case runCatchup = "run_catchup"
}

/// Who wrote the row into `agent_next_run`. The agent sees this on wake
/// so it can react to user edits (spec §9.5).
public enum NextRunScheduledBy: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case system
}

/// The kind of event that woke the agent. Maps from `DispatchRequest.source`
/// at run-start in `BackgroundTaskManager.dispatchChat`.
public enum AgentRunTriggerKind: String, Codable, Sendable, CaseIterable {
    /// Self-scheduled wake via `schedule_next_run` (the new next-run slot).
    case schedule
    /// User-authored recurring schedule from `ScheduleManager` (existing system).
    case recurringSchedule = "recurring_schedule"
    /// File-system watcher from `WatcherManager` (existing system).
    case watcher
    /// User-initiated chat from the UI.
    case user
}

/// Durable lifecycle status of an `agent_runs` row. Only `success` and
/// `error` count against `daily_run_cap` (spec §16 Q3). The non-terminal
/// additions support Run Center projection without changing the existing
/// scheduler accounting contract.
public enum AgentRunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForInput = "waiting_for_input"
    case review
    case success
    case error
    case cancelled
    case clamped
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .success, .error, .cancelled, .clamped, .interrupted:
            return true
        case .queued, .running, .waitingForInput, .review:
            return false
        }
    }
}

/// One row in `agent_next_run`. The "next run" slot is a single row per
/// agent; writers (agent / user / system) overwrite each other,
/// last-write-wins (spec §9.5).
public struct NextRunEntry: Codable, Sendable, Equatable {
    public var agentId: UUID
    public var scheduledAt: Date
    public var instructions: String
    /// Names of saved views the dispatcher should prefetch before the
    /// inference loop begins. Stored as JSON.
    public var contextViews: [String]
    public var priority: NextRunPriority
    public var onMiss: NextRunOnMiss
    public var scheduledBy: NextRunScheduledBy
    public var scheduledAtWall: Date

    public init(
        agentId: UUID,
        scheduledAt: Date,
        instructions: String,
        contextViews: [String] = [],
        priority: NextRunPriority = .normal,
        onMiss: NextRunOnMiss = .skip,
        scheduledBy: NextRunScheduledBy,
        scheduledAtWall: Date = Date()
    ) {
        self.agentId = agentId
        self.scheduledAt = scheduledAt
        self.instructions = instructions
        self.contextViews = contextViews
        self.priority = priority
        self.onMiss = onMiss
        self.scheduledBy = scheduledBy
        self.scheduledAtWall = scheduledAtWall
    }
}

/// One row in `agent_runs`. Append-only history; `recordRunStart` writes
/// `status = running` and `recordRunEnd` flips it to a terminal value.
public struct AgentRunRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var agentId: UUID
    public var triggerKind: AgentRunTriggerKind
    public var triggerPayload: String?
    public var instructions: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: AgentRunStatus
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?
    public var error: String?
    /// Canonical conversation row that owns the transcript, when known.
    public var sessionId: UUID?
    /// Optional semantic project grouping for cross-project Run Center views.
    public var projectId: UUID?
    /// Direct parent run for delegation, retry, or recipe-node execution.
    public var parentRunId: UUID?
    /// Root of the run tree. A root run points to itself.
    public var rootRunId: UUID?
    public var title: String?
    /// Resolved model identifier at run admission, when known.
    public var modelId: String?
    /// Latest durable lifecycle/event update. Legacy rows fall back to the
    /// terminal timestamp or start timestamp during migration.
    public var updatedAt: Date
    /// Original state from which this run's V2 event stream must replay.
    /// New runs use `created`; migrated V1 rows retain their pre-event state.
    public var eventBaselineState: RunCenterExecutionState?

    public init(
        id: UUID,
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        triggerPayload: String? = nil,
        instructions: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: AgentRunStatus = .running,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil,
        error: String? = nil,
        sessionId: UUID? = nil,
        projectId: UUID? = nil,
        parentRunId: UUID? = nil,
        rootRunId: UUID? = nil,
        title: String? = nil,
        modelId: String? = nil,
        updatedAt: Date? = nil,
        eventBaselineState: RunCenterExecutionState? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.triggerKind = triggerKind
        self.triggerPayload = triggerPayload
        self.instructions = instructions
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
        self.error = error
        self.sessionId = sessionId
        self.projectId = projectId
        self.parentRunId = parentRunId
        self.rootRunId = rootRunId
        self.title = title
        self.modelId = modelId
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
        self.eventBaselineState = eventBaselineState
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, triggerKind, triggerPayload, instructions, startedAt, endedAt
        case status, tokensIn, tokensOut, costUSD, error, sessionId, projectId
        case parentRunId, rootRunId, title, modelId, updatedAt, eventBaselineState
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let startedAt = try values.decode(Date.self, forKey: .startedAt)
        let endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            agentId: try values.decode(UUID.self, forKey: .agentId),
            triggerKind: try values.decode(AgentRunTriggerKind.self, forKey: .triggerKind),
            triggerPayload: try values.decodeIfPresent(String.self, forKey: .triggerPayload),
            instructions: try values.decode(String.self, forKey: .instructions),
            startedAt: startedAt,
            endedAt: endedAt,
            status: try values.decode(AgentRunStatus.self, forKey: .status),
            tokensIn: try values.decodeIfPresent(Int.self, forKey: .tokensIn),
            tokensOut: try values.decodeIfPresent(Int.self, forKey: .tokensOut),
            costUSD: try values.decodeIfPresent(Double.self, forKey: .costUSD),
            error: try values.decodeIfPresent(String.self, forKey: .error),
            sessionId: try values.decodeIfPresent(UUID.self, forKey: .sessionId),
            projectId: try values.decodeIfPresent(UUID.self, forKey: .projectId),
            parentRunId: try values.decodeIfPresent(UUID.self, forKey: .parentRunId),
            rootRunId: try values.decodeIfPresent(UUID.self, forKey: .rootRunId),
            title: try values.decodeIfPresent(String.self, forKey: .title),
            modelId: try values.decodeIfPresent(String.self, forKey: .modelId),
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt)
                ?? endedAt ?? startedAt,
            eventBaselineState: try values.decodeIfPresent(
                RunCenterExecutionState.self,
                forKey: .eventBaselineState
            )
        )
    }
}

/// Stable keyset cursor for cross-agent Run Center history. Timestamps are
/// stored at second precision, so the run id is required to avoid skipping
/// rows that started in the same second.
public struct RunCenterRunCursor: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var id: UUID

    public init(startedAt: Date, id: UUID) {
        self.startedAt = startedAt
        self.id = id
    }

    public init(after record: AgentRunRecord) {
        self.init(startedAt: record.startedAt, id: record.id)
    }
}

/// One row in `agent_pause`. Transient operational state (not exportable
/// config), so this lives here rather than in `Agent.json`.
public struct AgentPauseRecord: Codable, Sendable, Equatable {
    public var agentId: UUID
    public var pausedUntil: Date
    public var reason: String?

    public init(agentId: UUID, pausedUntil: Date, reason: String? = nil) {
        self.agentId = agentId
        self.pausedUntil = pausedUntil
        self.reason = reason
    }
}

// MARK: - Database

public final class SchedulerDatabase: @unchecked Sendable {
    public static let shared = SchedulerDatabase()

    private static let schemaVersion = 2

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.scheduler.database")
    private let stmtCache = PreparedStatementCache(capacity: 64)

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // Mirrors the gating in every other `*Database.open()`: parks
        // only while a key rotation is re-encrypting databases so we
        // can't open a half-rekeyed file. No-op fast path otherwise.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            do {
                OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
                try openConnection()
                try runMigrations()
            } catch {
                resetConnectionAfterFailedOpen()
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "scheduler",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. Plaintext.
    public func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            do {
                db = try EncryptedSQLiteOpener.open(
                    path: ":memory:",
                    key: nil,
                    applyPerfPragmas: false
                )
                try executeRaw("PRAGMA foreign_keys = ON")
                try executeRaw("PRAGMA busy_timeout = 5000")
                try runMigrations()
            } catch {
                resetConnectionAfterFailedOpen()
                throw error
            }
        }
    }

    /// Plaintext on-disk database used by migration and multi-handle tests.
    /// Production callers must use `open()` so SQLCipher keying remains in
    /// force.
    func openForTesting(path: String) throws {
        try queue.sync {
            guard db == nil else { return }
            do {
                db = try EncryptedSQLiteOpener.open(
                    path: path,
                    key: nil,
                    applyPerfPragmas: false
                )
                try executeRaw("PRAGMA foreign_keys = ON")
                try executeRaw("PRAGMA busy_timeout = 5000")
                try runMigrations()
            } catch {
                resetConnectionAfterFailedOpen()
                throw error
            }
        }
    }

    func schemaVersionForTesting() throws -> Int {
        try queue.sync {
            guard db != nil else { throw SchedulerDatabaseError.notOpen }
            return try getSchemaVersion()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "scheduler")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    private func openConnection() throws {
        let path = OsaurusPaths.schedulerDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
            try executeRaw("PRAGMA foreign_keys = ON")
            try executeRaw("PRAGMA busy_timeout = 5000")
        } catch let error as EncryptedSQLiteError {
            throw SchedulerDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    /// Called only while `queue` is held and before the handle is registered.
    private func resetConnectionAfterFailedOpen() {
        stmtCache.clear()
        if let connection = db {
            sqlite3_close(connection)
        }
        db = nil
    }

    // MARK: - Schema

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        if current < 1 { try migrateToV1() }
        if current < 2 { try migrateToV2() }
    }

    private func getSchemaVersion() throws -> Int {
        var v = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                v = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return v
    }

    private func setSchemaVersion(_ v: Int) throws {
        try executeRaw("PRAGMA user_version = \(v)")
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_next_run (
                    agent_id          TEXT PRIMARY KEY,
                    scheduled_at      INTEGER NOT NULL,
                    instructions      TEXT NOT NULL,
                    context_views     TEXT NOT NULL DEFAULT '[]',
                    priority          TEXT NOT NULL DEFAULT 'normal',
                    on_miss           TEXT NOT NULL DEFAULT 'skip',
                    scheduled_by      TEXT NOT NULL,
                    scheduled_at_wall INTEGER NOT NULL
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_next_run_scheduled_at ON agent_next_run(scheduled_at)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_runs (
                    id                TEXT PRIMARY KEY,
                    agent_id          TEXT NOT NULL,
                    trigger_kind      TEXT NOT NULL,
                    trigger_payload   TEXT,
                    instructions      TEXT NOT NULL,
                    started_at        INTEGER NOT NULL,
                    ended_at          INTEGER,
                    status            TEXT NOT NULL,
                    tokens_in         INTEGER,
                    tokens_out        INTEGER,
                    cost_usd          REAL,
                    error             TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_runs_agent_started ON agent_runs(agent_id, started_at DESC)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_runs_started ON agent_runs(started_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_pause (
                    agent_id      TEXT PRIMARY KEY,
                    paused_until  INTEGER NOT NULL,
                    reason        TEXT
                )
            """
        )

        try setSchemaVersion(1)
    }

    /// Extend the existing scheduler audit rows into the durable Run Center
    /// ledger. Additions are optional so every V1 row remains readable, and
    /// the migration is restart-safe if the app was interrupted between an
    /// `ALTER TABLE` and the final `user_version` update.
    private func migrateToV2() throws {
        try executeRaw("BEGIN IMMEDIATE TRANSACTION")
        do {
            try addColumnIfMissing(
                table: "agent_runs", column: "session_id", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "project_id", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "parent_run_id", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "root_run_id", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "title", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "model_id", definition: "TEXT")
            try addColumnIfMissing(
                table: "agent_runs", column: "updated_at", definition: "INTEGER")
            try addColumnIfMissing(
                table: "agent_runs",
                column: "event_baseline_state",
                definition: "TEXT"
            )

            try executeRaw(
                """
                    CREATE TABLE IF NOT EXISTS run_events (
                        id          TEXT PRIMARY KEY,
                        run_id      TEXT NOT NULL,
                        sequence    INTEGER NOT NULL,
                        event_type  TEXT NOT NULL,
                        message     TEXT,
                        metadata    TEXT NOT NULL DEFAULT '{}',
                        occurred_at INTEGER NOT NULL,
                        UNIQUE(run_id, sequence),
                        FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
                    )
                """
            )
            try executeRaw(
                "CREATE INDEX IF NOT EXISTS idx_run_events_run_sequence ON run_events(run_id, sequence)"
            )
            try executeRaw(
                "CREATE INDEX IF NOT EXISTS idx_runs_project_updated ON agent_runs(project_id, updated_at DESC)"
            )
            try executeRaw(
                "CREATE INDEX IF NOT EXISTS idx_runs_root_updated ON agent_runs(root_run_id, updated_at DESC)"
            )
            try executeRaw(
                "UPDATE agent_runs SET updated_at = COALESCE(updated_at, ended_at, started_at)"
            )
            try executeRaw(
                """
                    UPDATE agent_runs
                    SET event_baseline_state = COALESCE(
                        event_baseline_state,
                        CASE status
                            WHEN 'running' THEN 'running'
                            WHEN 'success' THEN 'completed'
                            WHEN 'error' THEN 'failed'
                            WHEN 'cancelled' THEN 'cancelled'
                            WHEN 'clamped' THEN 'failed'
                            ELSE NULL
                        END
                    )
                """
            )
            var missingBaseline = false
            try executeRaw(
                "SELECT 1 FROM agent_runs WHERE event_baseline_state IS NULL LIMIT 1"
            ) { statement in
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    missingBaseline = true
                } else if result != SQLITE_DONE {
                    throw SchedulerDatabaseError.failedToExecute(
                        "event baseline validation failed with SQLite status \(result)"
                    )
                }
            }
            if missingBaseline {
                throw SchedulerDatabaseError.migrationFailed(
                    "could not derive an event baseline for every legacy run"
                )
            }
            try setSchemaVersion(2)
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw error
        }
    }

    private func addColumnIfMissing(
        table: String,
        column: String,
        definition: String
    ) throws {
        var exists = false
        try executeRaw("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                if name == column {
                    exists = true
                    break
                }
            }
        }
        guard !exists else { return }
        try executeRaw("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    // MARK: - agent_next_run

    /// Insert or replace the single next-run slot for `agentId`. Last
    /// write wins (spec §9.5). Returns the entry that was stored.
    @discardableResult
    public func upsertNextRun(_ entry: NextRunEntry) throws -> NextRunEntry {
        let viewsJSON = Self.jsonEncode(entry.contextViews) ?? "[]"
        try prepareAndExecute(
            """
                INSERT INTO agent_next_run
                    (agent_id, scheduled_at, instructions, context_views,
                     priority, on_miss, scheduled_by, scheduled_at_wall)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(agent_id) DO UPDATE SET
                    scheduled_at      = excluded.scheduled_at,
                    instructions      = excluded.instructions,
                    context_views     = excluded.context_views,
                    priority          = excluded.priority,
                    on_miss           = excluded.on_miss,
                    scheduled_by      = excluded.scheduled_by,
                    scheduled_at_wall = excluded.scheduled_at_wall
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: entry.agentId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(entry.scheduledAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: entry.instructions)
                Self.bindText(stmt, index: 4, value: viewsJSON)
                Self.bindText(stmt, index: 5, value: entry.priority.rawValue)
                Self.bindText(stmt, index: 6, value: entry.onMiss.rawValue)
                Self.bindText(stmt, index: 7, value: entry.scheduledBy.rawValue)
                sqlite3_bind_int64(stmt, 8, Int64(entry.scheduledAtWall.timeIntervalSince1970))
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "upsertNextRun: step returned \(step)"
                    )
                }
            }
        )
        return entry
    }

    public func nextRun(for agentId: UUID) throws -> NextRunEntry? {
        var entry: NextRunEntry?
        try prepareAndExecute(
            """
                SELECT scheduled_at, instructions, context_views,
                       priority, on_miss, scheduled_by, scheduled_at_wall
                FROM agent_next_run
                WHERE agent_id = ?1
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entry = Self.readNextRun(stmt: stmt, agentId: agentId)
                }
            }
        )
        return entry
    }

    /// All entries whose `scheduled_at <= now`, ordered by `scheduled_at ASC`.
    /// The scheduler loop calls this on every tick (spec §9.1) with a
    /// bounded `limit` for concurrency.
    public func dueNextRuns(asOf now: Date, limit: Int) throws -> [NextRunEntry] {
        var entries: [NextRunEntry] = []
        try prepareAndExecute(
            """
                SELECT agent_id, scheduled_at, instructions, context_views,
                       priority, on_miss, scheduled_by, scheduled_at_wall
                FROM agent_next_run
                WHERE scheduled_at <= ?1
                ORDER BY scheduled_at ASC
                LIMIT ?2
            """,
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
                sqlite3_bind_int(stmt, 2, Int32(max(limit, 1)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard let id = UUID(uuidString: raw) else { continue }
                    entries.append(Self.readNextRun(stmt: stmt, agentId: id, agentIdColumn: 0))
                }
            }
        )
        return entries
    }

    public func clearNextRun(for agentId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM agent_next_run WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "clearNextRun: step returned \(step)"
                    )
                }
            }
        )
    }

    // MARK: - agent_runs

    /// Insert a `running` row and return its id. Pair with `recordRunEnd`
    /// before the run finishes so the row reaches a terminal state.
    @discardableResult
    public func recordRunStart(
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        triggerPayload: String? = nil,
        instructions: String,
        startedAt: Date = Date(),
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        projectId: UUID? = nil,
        parentRunId: UUID? = nil,
        rootRunId: UUID? = nil,
        title: String? = nil,
        modelId: String? = nil
    ) throws -> UUID {
        try inTransaction(immediate: true) { _ in
            let resolvedRootRunId: UUID
            if let parentRunId {
                guard let parentRoot = try self.runRootTransactionally(runId: parentRunId) else {
                    throw SchedulerDatabaseError.invalidRunRelationship(
                        id,
                        "parent run \(parentRunId.uuidString) does not exist"
                    )
                }
                if let rootRunId, rootRunId != parentRoot {
                    throw SchedulerDatabaseError.invalidRunRelationship(
                        id,
                        "root \(rootRunId.uuidString) does not match parent root \(parentRoot.uuidString)"
                    )
                }
                resolvedRootRunId = parentRoot
            } else {
                if let rootRunId, rootRunId != id {
                    throw SchedulerDatabaseError.invalidRunRelationship(
                        id,
                        "a root run without a parent must point to itself"
                    )
                }
                resolvedRootRunId = id
            }

            try self.transactionalStep(
                """
                    INSERT INTO agent_runs
                        (id, agent_id, trigger_kind, trigger_payload, instructions,
                         started_at, status, session_id, project_id, parent_run_id,
                         root_run_id, title, model_id, updated_at, event_baseline_state)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: id.uuidString)
                Self.bindText(stmt, index: 2, value: agentId.uuidString)
                Self.bindText(stmt, index: 3, value: triggerKind.rawValue)
                Self.bindText(stmt, index: 4, value: triggerPayload)
                Self.bindText(stmt, index: 5, value: instructions)
                sqlite3_bind_int64(stmt, 6, Int64(startedAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 7, value: AgentRunStatus.running.rawValue)
                Self.bindText(stmt, index: 8, value: sessionId?.uuidString)
                Self.bindText(stmt, index: 9, value: projectId?.uuidString)
                Self.bindText(stmt, index: 10, value: parentRunId?.uuidString)
                Self.bindText(stmt, index: 11, value: resolvedRootRunId.uuidString)
                Self.bindText(stmt, index: 12, value: title)
                Self.bindText(stmt, index: 13, value: modelId)
                sqlite3_bind_int64(stmt, 14, Int64(startedAt.timeIntervalSince1970))
                Self.bindText(
                    stmt,
                    index: 15,
                    value: RunCenterExecutionState.created.rawValue
                )
            }
            _ = try self.appendRunEventTransactionally(
                runId: id,
                kind: .started,
                occurredAt: startedAt,
                message: title,
                metadata: [:],
                baselineState: .created
            )
        }
        return id
    }

    public func recordRunEnd(
        runId: UUID,
        status: AgentRunStatus,
        endedAt: Date = Date(),
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil,
        error: String? = nil
    ) throws {
        let eventKind: RunCenterEventKind
        switch status {
        case .success:
            eventKind = .completed
        case .error, .clamped:
            eventKind = .failed
        case .cancelled:
            eventKind = .cancelled
        case .interrupted:
            eventKind = .interrupted
        case .queued, .running, .waitingForInput, .review:
            throw SchedulerDatabaseError.failedToExecute(
                "recordRunEnd requires a terminal status; received \(status.rawValue)"
            )
        }

        try inTransaction(immediate: true) { _ in
            guard let current = try self.runLifecycleTransactionally(runId: runId) else {
                throw SchedulerDatabaseError.runNotFound(runId)
            }
            if current.endedAt != nil || current.status.isTerminal {
                if current.matchesTerminalReceipt(
                    status: status,
                    endedAt: endedAt,
                    tokensIn: tokensIn,
                    tokensOut: tokensOut,
                    costUSD: costUSD,
                    error: error
                ) {
                    return
                }
                throw SchedulerDatabaseError.runAlreadyEnded(runId, current.status)
            }

            _ = try self.appendRunEventTransactionally(
                runId: runId,
                kind: eventKind,
                occurredAt: endedAt,
                message: error,
                metadata: [:],
                legacyStatus: current.status,
                baselineState: current.eventBaselineState
            )
            try self.transactionalStep(
                """
                    UPDATE agent_runs SET
                        ended_at   = ?2,
                        status     = ?3,
                        tokens_in  = ?4,
                        tokens_out = ?5,
                        cost_usd   = ?6,
                        error      = ?7,
                        updated_at = CASE
                            WHEN updated_at IS NULL OR updated_at < ?2 THEN ?2
                            ELSE updated_at
                        END
                    WHERE id = ?1 AND ended_at IS NULL
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: runId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(endedAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: status.rawValue)
                Self.bindOptionalInt(stmt, index: 4, value: tokensIn)
                Self.bindOptionalInt(stmt, index: 5, value: tokensOut)
                Self.bindOptionalDouble(stmt, index: 6, value: costUSD)
                Self.bindText(stmt, index: 7, value: error)
            }
            guard sqlite3_changes(self.db) == 1 else {
                throw SchedulerDatabaseError.runAlreadyEnded(runId, current.status)
            }
        }
    }

    /// Append an immutable run event with the next per-run sequence number.
    /// Metadata is redacted before persistence; callers must put full tool
    /// arguments and transcripts in their existing protected stores instead.
    @discardableResult
    public func appendRunEvent(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt: Date = Date(),
        message: String? = nil,
        metadata: [String: String] = [:]
    ) throws -> RunCenterEvent {
        switch kind {
        case .completed, .failed, .cancelled, .interrupted:
            throw SchedulerDatabaseError.invalidRunTransition(
                runId,
                "terminal events must be recorded through recordRunEnd"
            )
        case .created, .queued, .started, .progress, .waitingForInput, .resumed,
            .approvalRequested, .approvalResolved, .reviewRequested, .reviewResolved,
            .evidenceAttached, .childLinked, .retryLinked:
            break
        }

        return try inTransaction(immediate: true) { _ in
            guard let current = try self.runLifecycleTransactionally(runId: runId) else {
                throw SchedulerDatabaseError.runNotFound(runId)
            }
            let event = try self.appendRunEventTransactionally(
                runId: runId,
                kind: kind,
                occurredAt: occurredAt,
                message: message,
                metadata: metadata,
                legacyStatus: current.status,
                baselineState: current.eventBaselineState
            )

            let materialized = Self.materializedStatus(for: kind)
            try self.transactionalStep(
                """
                    UPDATE agent_runs SET
                        status = COALESCE(?3, status),
                        updated_at = CASE
                            WHEN updated_at IS NULL OR updated_at < ?2 THEN ?2
                            ELSE updated_at
                        END
                    WHERE id = ?1
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: runId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(occurredAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: materialized?.rawValue)
            }
            return event
        }
    }

    public func events(runId: UUID) throws -> [RunCenterEvent] {
        var events: [RunCenterEvent] = []
        try prepareAndExecute(
            """
                SELECT id, sequence, event_type, message, metadata, occurred_at
                FROM run_events
                WHERE run_id = ?1
                ORDER BY sequence ASC
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: runId.uuidString)
            },
            process: { stmt in
                var expectedSequence = 1
                while true {
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        throw SchedulerDatabaseError.corruptRunEvent(
                            runId,
                            "read failed with SQLite status \(result)"
                        )
                    }
                    let event = try Self.readRunEvent(stmt, runId: runId)
                    guard event.sequence == expectedSequence else {
                        throw SchedulerDatabaseError.corruptRunEvent(
                            runId,
                            "expected sequence \(expectedSequence), found \(event.sequence)"
                        )
                    }
                    expectedSequence += 1
                    events.append(event)
                }
            }
        )
        return events
    }

    /// Reverse-chrono runs for one agent, optionally bounded above by
    /// `before`. The Activity tab consumes this.
    public func runs(
        agentId: UUID,
        limit: Int = 100,
        before: RunCenterRunCursor? = nil
    ) throws -> [AgentRunRecord] {
        var sql =
            """
                SELECT id, agent_id, trigger_kind, trigger_payload, instructions,
                       started_at, ended_at, status, tokens_in, tokens_out,
                       cost_usd, error, session_id, project_id, parent_run_id,
                       root_run_id, title, model_id, updated_at, event_baseline_state
                FROM agent_runs
                WHERE agent_id = ?1
            """
        if before != nil {
            sql += " AND (started_at < ?2 OR (started_at = ?2 AND id < ?3))"
        }
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?\(before == nil ? 2 : 4)"

        var records: [AgentRunRecord] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                var idx: Int32 = 2
                if let before {
                    sqlite3_bind_int64(
                        stmt,
                        idx,
                        Int64(before.startedAt.timeIntervalSince1970)
                    )
                    idx += 1
                    Self.bindText(stmt, index: Int(idx), value: before.id.uuidString)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(max(limit, 1)))
            },
            process: { stmt in
                while true {
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        throw SchedulerDatabaseError.failedToExecute(
                            "run history read failed with SQLite status \(result)"
                        )
                    }
                    records.append(try Self.readRun(stmt))
                }
            }
        )
        return records
    }

    /// Reverse-chronological cross-agent history for the Run Center board.
    public func allRuns(
        limit: Int = 200,
        before: RunCenterRunCursor? = nil
    ) throws -> [AgentRunRecord] {
        var sql =
            """
                SELECT id, agent_id, trigger_kind, trigger_payload, instructions,
                       started_at, ended_at, status, tokens_in, tokens_out,
                       cost_usd, error, session_id, project_id, parent_run_id,
                       root_run_id, title, model_id, updated_at, event_baseline_state
                FROM agent_runs
            """
        if before != nil {
            sql += " WHERE started_at < ?1 OR (started_at = ?1 AND id < ?2)"
        }
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?\(before == nil ? 1 : 3)"

        var records: [AgentRunRecord] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                var index: Int32 = 1
                if let before {
                    sqlite3_bind_int64(
                        stmt,
                        index,
                        Int64(before.startedAt.timeIntervalSince1970)
                    )
                    index += 1
                    Self.bindText(stmt, index: Int(index), value: before.id.uuidString)
                    index += 1
                }
                sqlite3_bind_int(stmt, index, Int32(max(limit, 1)))
            },
            process: { stmt in
                while true {
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        throw SchedulerDatabaseError.failedToExecute(
                            "cross-agent run history read failed with SQLite status \(result)"
                        )
                    }
                    records.append(try Self.readRun(stmt))
                }
            }
        )
        return records
    }

    /// Count of runs in the rolling window ending `now` that we should
    /// charge against `daily_run_cap`. Per spec §16 Q3, only `success`
    /// and `error` runs count; clamped/cancelled scheduling attempts
    /// don't burn budget.
    public func successfulOrErroredRunCount(
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        in window: TimeInterval,
        asOf now: Date = Date()
    ) throws -> Int {
        let since = now.addingTimeInterval(-window)
        var count = 0
        try prepareAndExecute(
            """
                SELECT COUNT(*) FROM agent_runs
                WHERE agent_id = ?1
                  AND trigger_kind = ?2
                  AND status IN ('success', 'error')
                  AND started_at >= ?3
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                Self.bindText(stmt, index: 2, value: triggerKind.rawValue)
                sqlite3_bind_int64(stmt, 3, Int64(since.timeIntervalSince1970))
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    // MARK: - agent_pause

    public func pause(agentId: UUID, until: Date, reason: String? = nil) throws {
        try prepareAndExecute(
            """
                INSERT INTO agent_pause (agent_id, paused_until, reason)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(agent_id) DO UPDATE SET
                    paused_until = excluded.paused_until,
                    reason       = excluded.reason
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: reason)
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "pause: step returned \(step)"
                    )
                }
            }
        )
    }

    public func unpause(agentId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM agent_pause WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "unpause: step returned \(step)"
                    )
                }
            }
        )
    }

    public func pauseInfo(for agentId: UUID) throws -> AgentPauseRecord? {
        var record: AgentPauseRecord?
        try prepareAndExecute(
            "SELECT paused_until, reason FROM agent_pause WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let until = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
                    let reason = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    record = AgentPauseRecord(
                        agentId: agentId,
                        pausedUntil: until,
                        reason: reason
                    )
                }
            }
        )
        return record
    }

    // MARK: - Cleanup

    /// Called when an agent is deleted (`AgentStore.delete`). Removes
    /// every row across the three tables.
    public func deleteAllForAgent(_ agentId: UUID) throws {
        try inTransaction(immediate: true) { _ in
            if try self.hasCrossAgentRunLinksTransactionally(agentId: agentId) {
                throw SchedulerDatabaseError.agentDeletionBlocked(agentId)
            }
            try self.transactionalStep(
                "DELETE FROM agent_next_run WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
            try self.transactionalStep(
                """
                    DELETE FROM run_events
                    WHERE run_id IN (SELECT id FROM agent_runs WHERE agent_id = ?1)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
            try self.transactionalStep(
                "DELETE FROM agent_runs WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
            try self.transactionalStep(
                "DELETE FROM agent_pause WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
        }
    }

    /// Must be called from inside `inTransaction` while `queue` is held.
    private func hasCrossAgentRunLinksTransactionally(agentId: UUID) throws -> Bool {
        var statement: OpaquePointer?
        let sql =
            """
                SELECT 1
                FROM agent_runs AS survivor
                WHERE survivor.agent_id <> ?1
                  AND (
                    survivor.parent_run_id IN (
                        SELECT id FROM agent_runs WHERE agent_id = ?1
                    )
                    OR survivor.root_run_id IN (
                        SELECT id FROM agent_runs WHERE agent_id = ?1
                    )
                  )
                LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, index: 1, value: agentId.uuidString)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SchedulerDatabaseError.failedToExecute(
            "agent relationship read failed with SQLite status \(result)"
        )
    }

    // MARK: - Row decoders

    /// `agentId` is passed in explicitly because the row may have been
    /// read with `agent_id` as either the first or a later column.
    private static func readNextRun(
        stmt: OpaquePointer,
        agentId: UUID,
        agentIdColumn: Int? = nil
    ) -> NextRunEntry {
        // Column layout shifts based on whether agent_id is selected.
        let base = agentIdColumn == nil ? 0 : 1
        let scheduledAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, Int32(base + 0))))
        let instructions = sqlite3_column_text(stmt, Int32(base + 1)).map { String(cString: $0) } ?? ""
        let viewsJSON = sqlite3_column_text(stmt, Int32(base + 2)).map { String(cString: $0) } ?? "[]"
        let priority = sqlite3_column_text(stmt, Int32(base + 3)).map { String(cString: $0) } ?? "normal"
        let onMiss = sqlite3_column_text(stmt, Int32(base + 4)).map { String(cString: $0) } ?? "skip"
        let scheduledBy = sqlite3_column_text(stmt, Int32(base + 5)).map { String(cString: $0) } ?? "system"
        let wall = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, Int32(base + 6))))

        let views = Self.jsonDecode([String].self, from: viewsJSON) ?? []
        return NextRunEntry(
            agentId: agentId,
            scheduledAt: scheduledAt,
            instructions: instructions,
            contextViews: views,
            priority: NextRunPriority(rawValue: priority) ?? .normal,
            onMiss: NextRunOnMiss(rawValue: onMiss) ?? .skip,
            scheduledBy: NextRunScheduledBy(rawValue: scheduledBy) ?? .system,
            scheduledAtWall: wall
        )
    }

    /// Shared column layout for `runs(agentId:)` and `allRuns()`.
    private static func readRun(_ stmt: OpaquePointer) throws -> AgentRunRecord {
        let idStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        guard let runId = UUID(uuidString: idStr) else {
            throw SchedulerDatabaseError.corruptRun("invalid run id \(idStr)")
        }
        let agentIdStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        guard let agentId = UUID(uuidString: agentIdStr) else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has invalid agent id \(agentIdStr)"
            )
        }
        let kindRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        guard let triggerKind = AgentRunTriggerKind(rawValue: kindRaw) else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has unsupported trigger \(kindRaw)"
            )
        }
        let payload = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let instructions = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
        let endedAt: Date? =
            sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
        guard sqlite3_column_type(stmt, 7) != SQLITE_NULL,
            let statusText = sqlite3_column_text(stmt, 7)
        else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has a null status"
            )
        }
        let statusRaw = String(cString: statusText)
        guard let status = AgentRunStatus(rawValue: statusRaw) else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has unsupported status \(statusRaw)"
            )
        }
        let tokensIn: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
        let tokensOut: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        let cost: Double? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10)
        let error = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        let sessionId = try readOptionalUUID(stmt, column: 12, runId: runId, field: "session_id")
        let projectId = try readOptionalUUID(stmt, column: 13, runId: runId, field: "project_id")
        let parentRunId = try readOptionalUUID(
            stmt,
            column: 14,
            runId: runId,
            field: "parent_run_id"
        )
        let rootRunId = try readOptionalUUID(
            stmt,
            column: 15,
            runId: runId,
            field: "root_run_id"
        )
        let title = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
        let modelId = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
        let updatedAt: Date =
            sqlite3_column_type(stmt, 18) == SQLITE_NULL
            ? (endedAt ?? startedAt)
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 18)))
        let baselineRaw = sqlite3_column_text(stmt, 19).map { String(cString: $0) } ?? ""
        guard let eventBaselineState = RunCenterExecutionState(rawValue: baselineRaw) else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has invalid event baseline \(baselineRaw)"
            )
        }

        return AgentRunRecord(
            id: runId,
            agentId: agentId,
            triggerKind: triggerKind,
            triggerPayload: payload,
            instructions: instructions,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUSD: cost,
            error: error,
            sessionId: sessionId,
            projectId: projectId,
            parentRunId: parentRunId,
            rootRunId: rootRunId,
            title: title,
            modelId: modelId,
            updatedAt: updatedAt,
            eventBaselineState: eventBaselineState
        )
    }

    private static func readRunEvent(
        _ stmt: OpaquePointer,
        runId: UUID
    ) throws -> RunCenterEvent {
        let idString = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        guard let id = UUID(uuidString: idString) else {
            throw SchedulerDatabaseError.corruptRunEvent(runId, "invalid event id \(idString)")
        }
        let sequence = Int(sqlite3_column_int64(stmt, 1))
        let kindString = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        guard let kind = RunCenterEventKind(rawValue: kindString) else {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                "unsupported event type \(kindString) at sequence \(sequence)"
            )
        }
        let message = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let metadataJSON = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "{}"
        guard let metadata = jsonDecode([String: String].self, from: metadataJSON) else {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                "invalid metadata at sequence \(sequence)"
            )
        }
        let occurredAt = Date(
            timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5))
        )
        return RunCenterEvent(
            id: id,
            runId: runId,
            sequence: sequence,
            kind: kind,
            occurredAt: occurredAt,
            message: message,
            metadata: metadata
        )
    }

    private struct RunLifecycleRow {
        let status: AgentRunStatus
        let eventBaselineState: RunCenterExecutionState
        let endedAt: Date?
        let tokensIn: Int?
        let tokensOut: Int?
        let costUSD: Double?
        let error: String?

        func matchesTerminalReceipt(
            status: AgentRunStatus,
            endedAt: Date,
            tokensIn: Int?,
            tokensOut: Int?,
            costUSD: Double?,
            error: String?
        ) -> Bool {
            self.status == status
                && self.endedAt.map { Int64($0.timeIntervalSince1970) }
                    == Int64(endedAt.timeIntervalSince1970)
                && self.tokensIn == tokensIn
                && self.tokensOut == tokensOut
                && self.costUSD == costUSD
                && self.error == error
        }
    }

    /// Must be called from inside `inTransaction` while `queue` is held.
    private func runLifecycleTransactionally(runId: UUID) throws -> RunLifecycleRow? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                    SELECT status, ended_at, tokens_in, tokens_out, cost_usd, error,
                           event_baseline_state
                    FROM agent_runs
                    WHERE id = ?1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement
        else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, index: 1, value: runId.uuidString)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw SchedulerDatabaseError.failedToExecute(
                "run lifecycle read failed with SQLite status \(result)"
            )
        }
        let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        guard let status = AgentRunStatus(rawValue: raw) else {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                "unsupported materialized status \(raw)"
            )
        }
        let endedAt = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
        let tokensIn = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 2))
        let tokensOut = sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 3))
        let costUSD = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 4)
        let error = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        let baselineRaw = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
        guard let eventBaselineState = RunCenterExecutionState(rawValue: baselineRaw) else {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                "invalid event baseline \(baselineRaw)"
            )
        }
        return RunLifecycleRow(
            status: status,
            eventBaselineState: eventBaselineState,
            endedAt: endedAt,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUSD: costUSD,
            error: error
        )
    }

    /// Must be called from inside `inTransaction` while `queue` is held.
    private func runRootTransactionally(runId: UUID) throws -> UUID? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT COALESCE(root_run_id, id) FROM agent_runs WHERE id = ?1",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement
        else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, index: 1, value: runId.uuidString)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw SchedulerDatabaseError.failedToExecute(
                "run root read failed with SQLite status \(result)"
            )
        }
        let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        guard let root = UUID(uuidString: raw) else {
            throw SchedulerDatabaseError.corruptRunEvent(runId, "invalid root run id \(raw)")
        }
        if root != runId,
            try runLifecycleTransactionally(runId: root) == nil
        {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) references missing root \(root.uuidString)"
            )
        }
        return root
    }

    private static func materializedStatus(
        for kind: RunCenterEventKind
    ) -> AgentRunStatus? {
        switch kind {
        case .queued:
            return .queued
        case .started, .resumed:
            return .running
        case .waitingForInput, .approvalRequested:
            return .waitingForInput
        case .created, .progress, .approvalResolved, .reviewRequested, .reviewResolved,
            .evidenceAttached, .childLinked, .retryLinked, .completed, .failed, .cancelled,
            .interrupted:
            return nil
        }
    }

    private static func readOptionalUUID(
        _ stmt: OpaquePointer,
        column: Int32,
        runId: UUID,
        field: String
    ) throws -> UUID? {
        guard let value = sqlite3_column_text(stmt, column).map({ String(cString: $0) }) else {
            return nil
        }
        guard let id = UUID(uuidString: value) else {
            throw SchedulerDatabaseError.corruptRun(
                "run \(runId.uuidString) has invalid \(field) \(value)"
            )
        }
        return id
    }

    /// Must be called from inside `inTransaction` while `queue` is held.
    private func appendRunEventTransactionally(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt: Date,
        message: String?,
        metadata: [String: String],
        legacyStatus: AgentRunStatus? = nil,
        baselineState: RunCenterExecutionState
    ) throws -> RunCenterEvent {
        let existingEvents = try runEventsTransactionally(runId: runId)
        let sequence = existingEvents.count + 1
        let safeMessage = message.map {
            EvidenceReportMetadataRedactor.redactedValue(forKey: "message", value: $0)
        }

        let event = RunCenterEvent(
            runId: runId,
            sequence: sequence,
            kind: kind,
            occurredAt: occurredAt,
            message: safeMessage,
            metadata: EvidenceReportMetadataRedactor.redact(metadata)
        )
        let currentSnapshot: RunCenterSnapshot
        do {
            currentSnapshot = try RunCenterProjector.project(
                runId: runId,
                legacyStatus: legacyStatus,
                baselineState: baselineState,
                events: existingEvents,
                proofContract: .none
            )
        } catch {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                error.localizedDescription
            )
        }
        if let materializedState = RunCenterProjector.legacyExecutionState(legacyStatus),
            materializedState != currentSnapshot.executionState
        {
            throw SchedulerDatabaseError.corruptRunEvent(
                runId,
                "materialized state \(materializedState.rawValue) does not match "
                    + "event state \(currentSnapshot.executionState.rawValue)"
            )
        }
        do {
            _ = try RunCenterProjector.applying(
                kind,
                to: currentSnapshot.executionState,
                approvalPending: currentSnapshot.approvalPending,
                reviewPending: currentSnapshot.reviewPending,
                sequence: sequence
            )
        } catch {
            throw SchedulerDatabaseError.invalidRunTransition(
                runId,
                error.localizedDescription
            )
        }
        let metadataJSON = Self.jsonEncode(event.metadata) ?? "{}"
        try transactionalStep(
            """
                INSERT INTO run_events
                    (id, run_id, sequence, event_type, message, metadata, occurred_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: event.id.uuidString)
            Self.bindText(stmt, index: 2, value: event.runId.uuidString)
            sqlite3_bind_int64(stmt, 3, Int64(event.sequence))
            Self.bindText(stmt, index: 4, value: event.kind.rawValue)
            Self.bindText(stmt, index: 5, value: event.message)
            Self.bindText(stmt, index: 6, value: metadataJSON)
            sqlite3_bind_int64(stmt, 7, Int64(event.occurredAt.timeIntervalSince1970))
        }
        return event
    }

    /// Must be called from inside `inTransaction` while `queue` is held.
    private func runEventsTransactionally(runId: UUID) throws -> [RunCenterEvent] {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                    SELECT id, sequence, event_type, message, metadata, occurred_at
                    FROM run_events
                    WHERE run_id = ?1
                    ORDER BY sequence ASC
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement
        else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, index: 1, value: runId.uuidString)

        var events: [RunCenterEvent] = []
        var expectedSequence = 1
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SchedulerDatabaseError.corruptRunEvent(
                    runId,
                    "read failed with SQLite status \(result)"
                )
            }
            let event = try Self.readRunEvent(statement, runId: runId)
            guard event.sequence == expectedSequence else {
                throw SchedulerDatabaseError.corruptRunEvent(
                    runId,
                    "expected sequence \(expectedSequence), found \(event.sequence)"
                )
            }
            events.append(event)
            expectedSequence += 1
        }
        return events
    }

    // MARK: - SQLite helpers (mirrors ChatHistoryDatabase)

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, Int32(index), value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func bindOptionalInt(_ stmt: OpaquePointer, index: Int, value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, Int32(index), Int64(value))
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer, index: Int, value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, Int32(index), value)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func jsonEncode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private static func jsonDecode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw SchedulerDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw SchedulerDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw SchedulerDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        try handler(s)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw SchedulerDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(s) }
            bind(s)
            try process(s)
        }
    }

    private func inTransaction<T>(
        immediate: Bool = false,
        _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try queue.sync {
            guard let connection = db else { throw SchedulerDatabaseError.notOpen }
            let begin = immediate ? "BEGIN IMMEDIATE TRANSACTION" : "BEGIN TRANSACTION"
            try executeRaw(begin)
            do {
                let result = try operation(connection)
                try executeRaw("COMMIT")
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw SchedulerDatabaseError.failedToExecute(
                "transactionalStep: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }
}
