//
//  RunCenterModels.swift
//  osaurus
//
//  Deterministic lifecycle and board projection for durable Osaurus runs.
//  This is intentionally a projection over the existing Chat/Agent system,
//  not a second execution engine or transcript store.
//

import Foundation

/// Append-only lifecycle and relationship facts for one durable run.
public enum RunCenterEventKind: String, Codable, CaseIterable, Sendable {
    case created
    case queued
    case started
    case progress
    case waitingForInput = "waiting_for_input"
    case resumed
    case approvalRequested = "approval_requested"
    case approvalResolved = "approval_resolved"
    case reviewRequested = "review_requested"
    case reviewResolved = "review_resolved"
    case evidenceAttached = "evidence_attached"
    case childLinked = "child_linked"
    case retryLinked = "retry_linked"
    case completed
    case failed
    case cancelled
    case interrupted

    fileprivate var activeState: RunCenterExecutionState? {
        switch self {
        case .created:
            return .created
        case .queued:
            return .queued
        case .started, .resumed:
            return .running
        case .waitingForInput, .approvalRequested:
            return .waitingForInput
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .interrupted:
            return .interrupted
        case .progress, .approvalResolved, .reviewRequested, .reviewResolved,
            .evidenceAttached, .childLinked, .retryLinked:
            return nil
        }
    }
}

/// A sequenced run event. Sequence numbers are assigned by the durable store,
/// monotonically per run, and are the replay ordering authority.
public struct RunCenterEvent: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let runId: UUID
    public let sequence: Int
    public let kind: RunCenterEventKind
    public let occurredAt: Date
    public let message: String?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        runId: UUID,
        sequence: Int,
        kind: RunCenterEventKind,
        occurredAt: Date = Date(),
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.runId = runId
        self.sequence = sequence
        self.kind = kind
        self.occurredAt = occurredAt
        self.message = message
        self.metadata = metadata
    }
}

public enum RunCenterExecutionState: String, Codable, CaseIterable, Sendable {
    case created
    case queued
    case running
    case waitingForInput = "waiting_for_input"
    case inReview = "in_review"
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .created, .queued, .running, .waitingForInput, .inReview:
            return false
        }
    }
}

public enum RunCenterEvidenceState: String, Codable, CaseIterable, Sendable {
    case notRequired = "not_required"
    case unproven
    case partial
    case blocked
    case failed
    case proven
}

/// The authoritative proof contract is separate from observed outcomes so an
/// absent/corrupt contract can never be mistaken for "no proof required."
public enum RunCenterProofContract: Codable, Sendable, Equatable {
    case none
    case required(Set<String>)
    case unavailable(String)
}

/// Board lanes are derived from lifecycle and evidence. They are never stored
/// directly, which prevents stale or manually-painted success state.
public enum RunCenterLane: String, Codable, CaseIterable, Sendable {
    case working
    case needsYou = "needs_you"
    case inReview = "in_review"
    case proven
    case done
    case failed
}

public struct RunCenterSnapshot: Codable, Sendable, Equatable {
    public let runId: UUID
    public let executionState: RunCenterExecutionState
    public let approvalPending: Bool
    public let reviewPending: Bool
    public let evidenceState: RunCenterEvidenceState
    public let lane: RunCenterLane
    public let lastEventAt: Date?

    public init(
        runId: UUID,
        executionState: RunCenterExecutionState,
        approvalPending: Bool,
        reviewPending: Bool,
        evidenceState: RunCenterEvidenceState,
        lane: RunCenterLane,
        lastEventAt: Date?
    ) {
        self.runId = runId
        self.executionState = executionState
        self.approvalPending = approvalPending
        self.reviewPending = reviewPending
        self.evidenceState = evidenceState
        self.lane = lane
        self.lastEventAt = lastEventAt
    }
}

public enum RunCenterProjectionError: Error, LocalizedError, Equatable {
    case eventForDifferentRun(expected: UUID, actual: UUID)
    case invalidSequence(Int)
    case duplicateSequence(Int)
    case missingSequence(expected: Int, actual: Int)
    case terminalOutcomeMismatch(
        materialized: AgentRunStatus,
        event: RunCenterEventKind,
        sequence: Int
    )
    case invalidTransition(
        from: RunCenterExecutionState,
        to: RunCenterExecutionState,
        sequence: Int
    )

    public var errorDescription: String? {
        switch self {
        case .eventForDifferentRun(let expected, let actual):
            return "Run event belongs to \(actual), expected \(expected)."
        case .invalidSequence(let sequence):
            return "Run event sequence must be positive; received \(sequence)."
        case .duplicateSequence(let sequence):
            return "Run event sequence \(sequence) appears more than once."
        case .missingSequence(let expected, let actual):
            return "Run event sequence \(expected) is missing; next sequence is \(actual)."
        case .terminalOutcomeMismatch(let materialized, let event, let sequence):
            return "Materialized outcome \(materialized.rawValue) conflicts with "
                + "event \(event.rawValue) at sequence \(sequence)."
        case .invalidTransition(let from, let to, let sequence):
            return "Run state \(from.rawValue) cannot transition to \(to.rawValue) at sequence \(sequence)."
        }
    }
}

public enum RunCenterProjector {
    /// Replay events into one lifecycle/evidence snapshot. Events may arrive
    /// out of array order; their durable sequence is authoritative.
    public static func project(
        runId: UUID,
        legacyStatus: AgentRunStatus? = nil,
        baselineState: RunCenterExecutionState? = nil,
        events: [RunCenterEvent],
        proofContract: RunCenterProofContract,
        evidenceOutcomes: [String: EvidenceReportStatus] = [:]
    ) throws -> RunCenterSnapshot {
        let ordered = events.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        var seenSequences = Set<Int>()
        if let legacyStatus, legacyStatus.isTerminal {
            for event in ordered where event.kind.activeState?.isTerminal == true {
                guard terminalEvent(event.kind, matches: legacyStatus) else {
                    throw RunCenterProjectionError.terminalOutcomeMismatch(
                        materialized: legacyStatus,
                        event: event.kind,
                        sequence: event.sequence
                    )
                }
            }
        }
        // New ledgers begin with a creation/queue/start fact and replay from
        // `created`. A migrated row may first receive a terminal, evidence,
        // review, or link fact, so those streams retain the legacy row state
        // as their baseline instead of inventing a synthetic lifecycle.
        let beginsFreshLifecycle: Bool
        switch ordered.first?.kind {
        case .created, .queued, .started:
            beginsFreshLifecycle = true
        case .none, .progress, .waitingForInput, .resumed, .approvalRequested,
            .approvalResolved, .reviewRequested, .reviewResolved, .evidenceAttached,
            .childLinked, .retryLinked, .completed, .failed, .cancelled, .interrupted:
            beginsFreshLifecycle = false
        }
        let legacyState = legacyExecutionState(legacyStatus)
        let closesMigratedRunningRow = ordered.contains { event in
            switch (legacyStatus, event.kind) {
            case (.success?, .completed),
                (.error?, .failed),
                (.clamped?, .failed),
                (.cancelled?, .cancelled),
                (.interrupted?, .interrupted):
                return true
            default:
                return false
            }
        }
        let containsMigratedRunningTransition = ordered.contains { event in
            switch event.kind {
            case .progress, .waitingForInput, .approvalRequested:
                return true
            case .created, .queued, .started, .resumed, .approvalResolved,
                .reviewRequested, .reviewResolved, .evidenceAttached, .childLinked,
                .retryLinked, .completed, .failed, .cancelled, .interrupted:
                return false
            }
        }
        var state: RunCenterExecutionState
        if let baselineState {
            state = baselineState
        } else if beginsFreshLifecycle {
            state = .created
        } else if closesMigratedRunningRow
            || (legacyStatus == .running && containsMigratedRunningTransition)
        {
            // V1 stored only the materialized row. When its first V2 event is
            // a running-only transition, or its stream contains the matching
            // terminal receipt, the pre-event state was running.
            state = .running
        } else {
            state = legacyState ?? .created
        }
        var expectedSequence = 1
        var approvalPending = false
        var reviewPending = false

        for event in ordered {
            guard event.runId == runId else {
                throw RunCenterProjectionError.eventForDifferentRun(
                    expected: runId,
                    actual: event.runId
                )
            }
            guard event.sequence > 0 else {
                throw RunCenterProjectionError.invalidSequence(event.sequence)
            }
            guard seenSequences.insert(event.sequence).inserted else {
                throw RunCenterProjectionError.duplicateSequence(event.sequence)
            }
            guard event.sequence == expectedSequence else {
                throw RunCenterProjectionError.missingSequence(
                    expected: expectedSequence,
                    actual: event.sequence
                )
            }
            expectedSequence += 1
            let next = try applying(
                event.kind,
                to: state,
                approvalPending: approvalPending,
                reviewPending: reviewPending,
                sequence: event.sequence
            )
            state = next.executionState
            approvalPending = next.approvalPending
            reviewPending = next.reviewPending
        }

        let evidenceState = classifyEvidence(
            contract: proofContract,
            outcomes: evidenceOutcomes
        )
        return RunCenterSnapshot(
            runId: runId,
            executionState: state,
            approvalPending: approvalPending,
            reviewPending: reviewPending,
            evidenceState: evidenceState,
            lane: lane(
                execution: state,
                reviewPending: reviewPending,
                evidence: evidenceState
            ),
            lastEventAt: ordered.last?.occurredAt
        )
    }

    public static func classifyEvidence(
        contract: RunCenterProofContract,
        outcomes: [String: EvidenceReportStatus]
    ) -> RunCenterEvidenceState {
        let requiredIds: Set<String>
        switch contract {
        case .none:
            return .notRequired
        case .unavailable:
            return .blocked
        case .required(let ids):
            requiredIds = ids
        }

        guard !requiredIds.isEmpty,
            requiredIds.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            return .unproven
        }
        let statuses = requiredIds.compactMap { outcomes[$0] }

        if statuses.contains(where: { $0 == .failed || $0 == .error }) {
            return .failed
        }
        if statuses.contains(where: { $0 == .blocked || $0 == .unavailable }) {
            return .blocked
        }
        if statuses.contains(.partial) {
            return .partial
        }
        if statuses.count == requiredIds.count,
            statuses.allSatisfy({ $0 == .passed })
        {
            return .proven
        }
        return .unproven
    }

    public static func lane(
        execution: RunCenterExecutionState,
        reviewPending: Bool,
        evidence: RunCenterEvidenceState
    ) -> RunCenterLane {
        switch execution {
        case .created, .queued, .running:
            return .working
        case .waitingForInput:
            return .needsYou
        case .inReview:
            // `.inReview` is retained for legacy row compatibility only.
            // Evidence can never make a non-completed execution Proven.
            return .inReview
        case .completed:
            if reviewPending { return .inReview }
            switch evidence {
            case .notRequired:
                return .done
            case .proven:
                return .proven
            case .unproven, .partial, .blocked, .failed:
                return .inReview
            }
        case .failed, .cancelled, .interrupted:
            return .failed
        }
    }

    /// Lifecycle events are deliberately stricter than a state-only reducer:
    /// `started` and `resumed` both project to running, but only the latter may
    /// leave a waiting state. Terminal states are absorbing; relationship and
    /// evidence events have no active state and are handled before this table.
    private static func isAllowedEvent(
        _ event: RunCenterEventKind,
        from state: RunCenterExecutionState,
        approvalPending: Bool,
        reviewPending: Bool
    ) -> Bool {
        switch event {
        case .created:
            return state == .created
        case .queued:
            return state == .created
        case .started:
            return state == .created || state == .queued
        case .progress:
            return state == .running
        case .resumed:
            return state == .waitingForInput && !approvalPending
        case .waitingForInput:
            return state == .running
        case .approvalRequested:
            return state == .running && !approvalPending
        case .approvalResolved:
            return state == .waitingForInput && approvalPending
        case .reviewRequested:
            return !reviewPending && (state == .running || state == .completed)
        case .reviewResolved:
            // A review may still be explicitly closed after execution fails,
            // is cancelled, or is interrupted.
            return reviewPending
        case .completed:
            return state == .running
        case .failed, .cancelled, .interrupted:
            // `.inReview` is a legacy materialized execution state. It still
            // needs a terminal escape hatch for cancellation, failure, and
            // launch recovery; otherwise a row stranded there can never be
            // closed after its in-memory owner disappears.
            return !state.isTerminal
        case .evidenceAttached:
            return true
        case .childLinked:
            return state == .running || state.isTerminal
        case .retryLinked:
            return state.isTerminal
        }
    }

    /// Apply one already-sequenced event. Durable appends replay the complete
    /// stream through `project`, so gaps, altered facts, and approval/review
    /// inconsistencies fail closed before a new event is written.
    static func applying(
        _ event: RunCenterEventKind,
        to state: RunCenterExecutionState,
        approvalPending: Bool,
        reviewPending: Bool,
        sequence: Int
    ) throws -> (
        executionState: RunCenterExecutionState,
        approvalPending: Bool,
        reviewPending: Bool
    ) {
        guard event != .created || sequence == 1,
            isAllowedEvent(
                event,
                from: state,
                approvalPending: approvalPending,
                reviewPending: reviewPending
            )
        else {
            throw RunCenterProjectionError.invalidTransition(
                from: state,
                to: event.activeState ?? state,
                sequence: sequence
            )
        }
        let nextState = event.activeState ?? state
        let nextApprovalPending: Bool
        switch event {
        case .approvalRequested:
            nextApprovalPending = true
        case .approvalResolved, .resumed, .failed, .cancelled, .interrupted:
            nextApprovalPending = false
        case .created, .queued, .started, .progress, .waitingForInput,
            .reviewRequested, .reviewResolved, .evidenceAttached, .childLinked,
            .retryLinked, .completed:
            nextApprovalPending = approvalPending
        }
        let nextReviewPending: Bool
        switch event {
        case .reviewRequested:
            nextReviewPending = true
        case .reviewResolved:
            nextReviewPending = false
        case .created, .queued, .started, .progress, .waitingForInput, .resumed,
            .approvalRequested, .approvalResolved, .evidenceAttached, .childLinked,
            .retryLinked, .completed, .failed, .cancelled, .interrupted:
            nextReviewPending = reviewPending
        }
        return (nextState, nextApprovalPending, nextReviewPending)
    }

    static func legacyExecutionState(
        _ status: AgentRunStatus?
    ) -> RunCenterExecutionState? {
        switch status {
        case .none:
            return nil
        case .queued:
            return .queued
        case .running:
            return .running
        case .waitingForInput:
            return .waitingForInput
        case .review:
            return .inReview
        case .success:
            return .completed
        case .error, .clamped:
            return .failed
        case .cancelled:
            return .cancelled
        case .interrupted:
            return .interrupted
        }
    }

    private static func terminalEvent(
        _ event: RunCenterEventKind,
        matches status: AgentRunStatus
    ) -> Bool {
        switch (status, event) {
        case (.success, .completed),
            (.error, .failed),
            (.clamped, .failed),
            (.cancelled, .cancelled),
            (.interrupted, .interrupted):
            return true
        case (.queued, _), (.running, _), (.waitingForInput, _), (.review, _),
            (.success, _), (.error, _), (.cancelled, _), (.clamped, _),
            (.interrupted, _):
            return false
        }
    }
}
