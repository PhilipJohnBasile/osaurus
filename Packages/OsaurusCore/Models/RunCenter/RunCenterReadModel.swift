//
//  RunCenterReadModel.swift
//  osaurus
//
//  Read-only projection and enrichment for the native Run Center. Durable
//  lifecycle facts remain owned by SchedulerDatabase; conversation, trace,
//  tool, and artifact data remain in their existing authoritative stores.
//

import Foundation

public enum RunCenterAttentionKind: String, Sendable, Equatable {
    case clarification
    case approval
    case readyToResume = "ready_to_resume"
}

public struct RunCenterAttention: Sendable, Equatable {
    public let kind: RunCenterAttentionKind
    public let requestedAt: Date
    public let message: String?
}

public struct RunCenterBoardCard: Identifiable, Sendable, Equatable {
    public var id: UUID { run.id }

    public let run: AgentRunRecord
    public let snapshot: RunCenterSnapshot
    public let attention: RunCenterAttention?
    public let linkedChildCount: Int
    public let hasPartialAggregate: Bool
}

public struct RunCenterProjectionIssue: Identifiable, Sendable, Equatable {
    public var id: UUID { run.id }

    public let run: AgentRunRecord
    public let message: String
}

public struct RunCenterBoardReadModel: Sendable, Equatable {
    public let cards: [RunCenterBoardCard]
    public let unavailableCards: [RunCenterProjectionIssue]
    public let refreshedAt: Date

    public var needsYou: [RunCenterBoardCard] {
        cards.filter { $0.snapshot.lane == .needsYou }
    }

    public func cards(in lane: RunCenterLane) -> [RunCenterBoardCard] {
        cards.filter { $0.snapshot.lane == lane }
    }
}

public struct RunCenterVisibleTurn: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let role: String
    public let content: String
    public let occurredAt: Date?
}

public struct RunCenterConversationSummary: Sendable, Equatable {
    public let sessionId: UUID
    public let title: String
    public let turns: [RunCenterVisibleTurn]

    /// ChatSessionData has no per-turn run id. These visible turns are useful
    /// conversation context, but are never counted as selected-run evidence.
    public let isWholeConversationContext: Bool
}

public struct RunCenterTraceSummary: Sendable, Equatable {
    public let status: String
    public let startedAt: Date
    public let endedAt: Date
    public let turnCount: Int
    public let toolCallCount: Int
    public let toolNames: [String]
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let costUSD: Double?
}

public enum RunCenterTraceAvailability: Sendable, Equatable {
    case available(RunCenterTraceSummary)
    case missing
    case corrupt
    case identityMismatch
}

public enum RunTraceReadResult: Sendable, Equatable {
    case available(RunTrace)
    case missing
    case corrupt
    case identityMismatch
}

public struct RunCenterDisplayEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let runId: UUID
    public let sequence: Int
    public let kind: RunCenterEventKind
    public let occurredAt: Date
    public let message: String?
    public let metadata: [String: String]
}

public struct RunCenterRunEventStream: Identifiable, Sendable, Equatable {
    public var id: UUID { runId }

    public let runId: UUID
    public let events: [RunCenterDisplayEvent]
}

public struct RunCenterDetailReadModel: Sendable, Equatable {
    public let card: RunCenterBoardCard
    public let tree: [AgentRunRecord]
    /// Streams stay grouped by run and ordered by durable per-run sequence.
    /// There is no authoritative global ordering across sibling runs.
    public let eventStreams: [RunCenterRunEventStream]
    public let conversation: RunCenterConversationSummary?
    public let conversationUnavailableReason: String?
    public let trace: RunCenterTraceAvailability

    /// Phase 2 has no durable run-to-proof binding. This is intentionally an
    /// explicit gap rather than an inference from the in-memory registry.
    public let proofAvailability: String
    public let runtimeSettingsAvailability: String
    public let testAndEvalAvailability: String
    public let artifactAvailability: String
}

public enum RunCenterReadError: Error, LocalizedError, Equatable {
    case runNotFound(UUID)
    case projectionFailed(UUID, String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runId):
            return String(
                format: L("Run %@ was not found."),
                runId.uuidString
            )
        case .projectionFailed(let runId, let message):
            return String(
                format: L("Run %@ could not be projected: %@"),
                runId.uuidString,
                message
            )
        }
    }
}

/// Sendable facade used by the view model. All methods are synchronous by
/// design and must be invoked off the main actor.
public struct RunCenterReadRepository: Sendable {
    private let loadBoardFacts: @Sendable () throws -> RunCenterBoardFacts
    private let loadDetailFacts: @Sendable (UUID) throws -> RunCenterDetailFacts?
    private let loadConversation: @Sendable (UUID) -> ChatSessionData?
    private let loadTrace: @Sendable (UUID, UUID) -> RunTraceReadResult

    public init(
        schedulerDatabase: SchedulerDatabase = .shared,
        chatHistoryDatabase: ChatHistoryDatabase = .shared
    ) {
        loadBoardFacts = {
            try schedulerDatabase.open()
            return try schedulerDatabase.runCenterBoardFacts()
        }
        loadDetailFacts = { runId in
            try schedulerDatabase.open()
            return try schedulerDatabase.runCenterDetailFacts(runId: runId)
        }
        loadConversation = { sessionId in
            if !chatHistoryDatabase.isOpenNonBlocking {
                try? chatHistoryDatabase.open()
            }
            return chatHistoryDatabase.loadSession(id: sessionId)
        }
        loadTrace = { agentId, runId in
            RunTraceReader.read(agentId: agentId, runId: runId)
        }
    }

    init(
        loadBoardFacts: @escaping @Sendable () throws -> RunCenterBoardFacts,
        loadDetailFacts: @escaping @Sendable (UUID) throws -> RunCenterDetailFacts?,
        loadConversation: @escaping @Sendable (UUID) -> ChatSessionData? = { _ in nil },
        loadTrace: @escaping @Sendable (UUID, UUID) -> RunTraceReadResult = { _, _ in .missing }
    ) {
        self.loadBoardFacts = loadBoardFacts
        self.loadDetailFacts = loadDetailFacts
        self.loadConversation = loadConversation
        self.loadTrace = loadTrace
    }

    public func board() throws -> RunCenterBoardReadModel {
        Self.projectBoard(try loadBoardFacts(), refreshedAt: Date())
    }

    public func conversation(sessionId: UUID) -> ChatSessionData? {
        loadConversation(sessionId)
    }

    public func detail(runId: UUID) throws -> RunCenterDetailReadModel {
        guard let facts = try loadDetailFacts(runId) else {
            throw RunCenterReadError.runNotFound(runId)
        }
        let events = facts.eventsByRunId[facts.run.id] ?? []
        let card: RunCenterBoardCard
        do {
            card = try Self.projectCard(run: facts.run, events: events)
        } catch {
            throw RunCenterReadError.projectionFailed(
                facts.run.id,
                error.localizedDescription
            )
        }

        let conversation = facts.run.sessionId.flatMap(loadConversation)
        let traceResult = loadTrace(facts.run.agentId, facts.run.id)
        let traceAvailability: RunCenterTraceAvailability
        switch traceResult {
        case .available(let trace):
            traceAvailability = .available(Self.traceSummary(trace))
        case .missing:
            traceAvailability = .missing
        case .corrupt:
            traceAvailability = .corrupt
        case .identityMismatch:
            traceAvailability = .identityMismatch
        }
        let eventStreams = facts.tree.map { record in
            RunCenterRunEventStream(
                runId: record.id,
                events: (facts.eventsByRunId[record.id] ?? [])
                    .sorted { $0.sequence < $1.sequence }
                    .map(Self.displayEvent)
            )
        }

        return RunCenterDetailReadModel(
            card: card,
            tree: facts.tree,
            eventStreams: eventStreams,
            conversation: conversation.map(Self.conversationSummary),
            conversationUnavailableReason: conversation == nil
                ? L("No canonical conversation is available for this run.")
                : nil,
            trace: traceAvailability,
            proofAvailability:
                L("No durable proof contract or evidence association is captured for this run."),
            runtimeSettingsAvailability:
                L("Resolved generation and cache settings are not durably captured yet."),
            testAndEvalAvailability:
                L("No durable test or evaluation artifacts are associated with this run."),
            artifactAvailability:
                L("Run-specific artifacts are not durably associated with this run.")
        )
    }

    static func projectBoard(
        _ facts: RunCenterBoardFacts,
        refreshedAt: Date
    ) -> RunCenterBoardReadModel {
        var cards: [RunCenterBoardCard] = []
        var issues: [RunCenterProjectionIssue] = []
        for run in facts.runs {
            do {
                cards.append(
                    try projectCard(
                        run: run,
                        events: facts.eventsByRunId[run.id] ?? []
                    )
                )
            } catch {
                issues.append(
                    RunCenterProjectionIssue(
                        run: run,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return RunCenterBoardReadModel(
            cards: cards,
            unavailableCards: issues,
            refreshedAt: refreshedAt
        )
    }

    private static func projectCard(
        run: AgentRunRecord,
        events: [RunCenterEvent]
    ) throws -> RunCenterBoardCard {
        let snapshot = try RunCenterProjector.project(
            runId: run.id,
            legacyStatus: run.status,
            baselineState: run.eventBaselineState,
            events: events,
            proofContract: .unavailable(L("Proof contract not recorded"))
        )
        return RunCenterBoardCard(
            run: run,
            snapshot: snapshot,
            attention: attention(snapshot: snapshot, events: events),
            linkedChildCount: events.filter { $0.kind == .childLinked }.count,
            hasPartialAggregate: events.contains {
                $0.metadata["aggregate_status"] == "partial_failure"
            }
        )
    }

    private static func attention(
        snapshot: RunCenterSnapshot,
        events: [RunCenterEvent]
    ) -> RunCenterAttention? {
        guard snapshot.lane == .needsYou else { return nil }
        if snapshot.approvalPending,
            let request = events.last(where: { $0.kind == .approvalRequested })
        {
            return RunCenterAttention(
                kind: .approval,
                requestedAt: request.occurredAt,
                message: request.message
            )
        }
        if let resolved = events.last(where: { $0.kind == .approvalResolved }),
            events.last?.sequence == resolved.sequence
        {
            return RunCenterAttention(
                kind: .readyToResume,
                requestedAt: resolved.occurredAt,
                message: resolved.message
            )
        }
        let request = events.last(where: { $0.kind == .waitingForInput })
        return RunCenterAttention(
            kind: .clarification,
            requestedAt: request?.occurredAt ?? snapshot.lastEventAt ?? Date.distantPast,
            message: request?.message
        )
    }

    private static let visibleMetadataKeys: Set<String> = [
        "aggregate_status", "cancelled", "child_run_id", "failed", "kind",
        "phase", "retry_run_id", "source", "stable_job_id", "succeeded",
        "tool_name",
    ]

    private static func displayEvent(_ event: RunCenterEvent) -> RunCenterDisplayEvent {
        RunCenterDisplayEvent(
            id: event.id,
            runId: event.runId,
            sequence: event.sequence,
            kind: event.kind,
            occurredAt: event.occurredAt,
            message: event.message,
            metadata: event.metadata.filter { visibleMetadataKeys.contains($0.key) }
        )
    }

    private static func conversationSummary(
        _ session: ChatSessionData
    ) -> RunCenterConversationSummary {
        let visibleTurns = session.turns.compactMap { turn -> RunCenterVisibleTurn? in
            guard turn.role == .user || turn.role == .assistant else { return nil }
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return RunCenterVisibleTurn(
                id: turn.id,
                role: turn.role.rawValue,
                content: content,
                occurredAt: turn.createdAt
            )
        }
        return RunCenterConversationSummary(
            sessionId: session.id,
            title: session.title,
            turns: visibleTurns,
            isWholeConversationContext: true
        )
    }

    private static func traceSummary(_ trace: RunTrace) -> RunCenterTraceSummary {
        RunCenterTraceSummary(
            status: trace.status,
            startedAt: trace.startedAt,
            endedAt: trace.endedAt,
            turnCount: trace.turns.count,
            toolCallCount: trace.turns.reduce(0) { $0 + ($1.toolCalls?.count ?? 0) },
            toolNames: trace.turns.flatMap { turn in
                (turn.toolCalls ?? []).map(\.name)
            },
            tokensIn: trace.tokensIn,
            tokensOut: trace.tokensOut,
            costUSD: trace.costUSD
        )
    }
}

public enum RunTraceReader {
    public static func read(agentId: UUID, runId: UUID) -> RunTraceReadResult {
        let url = OsaurusPaths.agentRunTraceFile(agentId: agentId, runId: runId)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let trace = try? decoder.decode(RunTrace.self, from: data) else {
            return .corrupt
        }
        guard trace.agentId == agentId, trace.runId == runId else {
            return .identityMismatch
        }
        return .available(trace)
    }
}
