//
//  RunLifecycleRecorder.swift
//  osaurus
//
//  Narrow persistence boundary between execution owners and the Run Center
//  ledger. Runtime managers own lifecycle decisions; the recorder only makes
//  those already-decided facts durable.
//

import Foundation

public struct RunLifecycleAdmission: Sendable, Equatable {
    public let runId: UUID
    public let agentId: UUID
    public let triggerKind: AgentRunTriggerKind
    public let triggerPayload: String?
    public let instructions: String
    public let admittedAt: Date
    public let startsImmediately: Bool
    public let sessionId: UUID?
    public let projectId: UUID?
    public let parentRunId: UUID?
    public let rootRunId: UUID?
    public let title: String?
    public let modelId: String?

    public init(
        runId: UUID,
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        triggerPayload: String? = nil,
        instructions: String,
        admittedAt: Date = Date(),
        startsImmediately: Bool,
        sessionId: UUID? = nil,
        projectId: UUID? = nil,
        parentRunId: UUID? = nil,
        rootRunId: UUID? = nil,
        title: String? = nil,
        modelId: String? = nil
    ) {
        self.runId = runId
        self.agentId = agentId
        self.triggerKind = triggerKind
        self.triggerPayload = triggerPayload
        self.instructions = instructions
        self.admittedAt = admittedAt
        self.startsImmediately = startsImmediately
        self.sessionId = sessionId
        self.projectId = projectId
        self.parentRunId = parentRunId
        self.rootRunId = rootRunId
        self.title = title
        self.modelId = modelId
    }
}

/// Identity confirmed by the durable ledger after it validates lineage.
/// A child may omit `rootRunId` at the dispatch boundary; the ledger resolves
/// that value from its parent and returns the canonical root to the runtime.
public struct RunLifecycleAdmissionReceipt: Sendable, Equatable {
    public let runId: UUID
    public let rootRunId: UUID

    public init(runId: UUID, rootRunId: UUID) {
        self.runId = runId
        self.rootRunId = rootRunId
    }
}

public struct RunLifecycleTerminalReceipt: Sendable, Equatable {
    public let runId: UUID
    public let status: AgentRunStatus
    public let endedAt: Date
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let costUSD: Double?
    public let error: String?

    public init(
        runId: UUID,
        status: AgentRunStatus,
        endedAt: Date = Date(),
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil,
        error: String? = nil
    ) {
        self.runId = runId
        self.status = status
        self.endedAt = endedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
        self.error = error
    }
}

/// Ordered write-only sink used by the execution owner. Implementations must
/// preserve call order and fail closed on invalid durable transitions.
public protocol RunLifecycleRecording: Sendable {
    @discardableResult
    func admit(_ admission: RunLifecycleAdmission) throws -> RunLifecycleAdmissionReceipt
    func append(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt: Date,
        message: String?,
        metadata: [String: String]
    ) throws
    func end(_ receipt: RunLifecycleTerminalReceipt) throws
}

public final class SchedulerRunLifecycleRecorder: RunLifecycleRecording, @unchecked Sendable {
    public static let shared = SchedulerRunLifecycleRecorder()

    private let database: SchedulerDatabase
    private let processPreparationLock = NSLock()
    private var isPreparedForCurrentProcess = false

    init(database: SchedulerDatabase = .shared) {
        self.database = database
    }

    /// Serialize launch recovery with the first admission. App launch does
    /// this proactively, but watcher/schedule/server startup is concurrent;
    /// if one of those paths wins the race, its admission performs recovery
    /// first. The one-time flag prevents a later launch callback from
    /// interrupting work owned by the new process.
    @discardableResult
    public func recoverOrphanedRunsAfterLaunch() throws -> [UUID] {
        processPreparationLock.lock()
        defer { processPreparationLock.unlock() }
        guard !isPreparedForCurrentProcess else { return [] }

        if !database.isOpen {
            try database.open()
        }
        let recovered = try database.recoverOrphanedRunsAfterLaunch()
        isPreparedForCurrentProcess = true
        return recovered
    }

    @discardableResult
    public func admit(
        _ admission: RunLifecycleAdmission
    ) throws -> RunLifecycleAdmissionReceipt {
        _ = try recoverOrphanedRunsAfterLaunch()
        let rootRunId = try database.recordRunAdmission(admission)
        return RunLifecycleAdmissionReceipt(runId: admission.runId, rootRunId: rootRunId)
    }

    public func append(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt: Date,
        message: String?,
        metadata: [String: String]
    ) throws {
        _ = try database.appendRunEvent(
            runId: runId,
            kind: kind,
            occurredAt: occurredAt,
            message: message,
            metadata: metadata
        )
    }

    public func end(_ receipt: RunLifecycleTerminalReceipt) throws {
        try database.recordRunEnd(
            runId: receipt.runId,
            status: receipt.status,
            endedAt: receipt.endedAt,
            tokensIn: receipt.tokensIn,
            tokensOut: receipt.tokensOut,
            costUSD: receipt.costUSD,
            error: receipt.error
        )
    }
}

/// Test managers and visibility-only mirrors use a sink that deliberately has
/// no durable side effects. Production dispatch always injects the scheduler
/// recorder above.
final class DiscardingRunLifecycleRecorder: RunLifecycleRecording, @unchecked Sendable {
    static let shared = DiscardingRunLifecycleRecorder()

    private init() {}

    @discardableResult
    func admit(_ admission: RunLifecycleAdmission) throws -> RunLifecycleAdmissionReceipt {
        RunLifecycleAdmissionReceipt(
            runId: admission.runId,
            rootRunId: admission.rootRunId ?? admission.runId
        )
    }

    func append(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt: Date,
        message: String?,
        metadata: [String: String]
    ) throws {}

    func end(_ receipt: RunLifecycleTerminalReceipt) throws {}
}
