//
//  RunCenterProjectionTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Run Center projection")
struct RunCenterProjectionTests {
    private let runId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func replayUsesSequenceAndReachesDoneWithoutProofContract() throws {
        let events = [
            event(sequence: 4, kind: .completed),
            event(sequence: 2, kind: .waitingForInput),
            event(sequence: 1, kind: .started),
            event(sequence: 3, kind: .resumed),
        ]

        let snapshot = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .none
        )

        #expect(snapshot.executionState == .completed)
        #expect(snapshot.evidenceState == .notRequired)
        #expect(snapshot.lane == .done)
        #expect(snapshot.lastEventAt == baseDate.addingTimeInterval(4))
    }

    @Test func requiredEvidenceCannotProjectProvenUntilEveryRowPasses() throws {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .completed),
        ]

        let missing = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .required(["core-tests", "live-proof"]),
            evidenceOutcomes: ["live-proof": .passed]
        )
        let partial = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .required(["core-tests", "live-proof"]),
            evidenceOutcomes: ["core-tests": .passed, "live-proof": .partial]
        )
        let proven = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .required(["core-tests", "live-proof"]),
            evidenceOutcomes: ["core-tests": .passed, "live-proof": .passed]
        )

        #expect(missing.evidenceState == .unproven)
        #expect(missing.lane == .inReview)
        #expect(partial.evidenceState == .partial)
        #expect(partial.lane == .inReview)
        #expect(proven.evidenceState == .proven)
        #expect(proven.lane == .proven)
    }

    @Test func failedEvidenceOutranksPassedRows() throws {
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            legacyStatus: .success,
            events: [],
            proofContract: .required(["focused", "full", "live"]),
            evidenceOutcomes: ["focused": .passed, "full": .failed, "live": .passed]
        )

        #expect(snapshot.executionState == .completed)
        #expect(snapshot.evidenceState == .failed)
        #expect(snapshot.lane == .inReview)
    }

    @Test func legacyRowsProjectWithoutSyntheticEvents() throws {
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            legacyStatus: .cancelled,
            events: [],
            proofContract: .none
        )

        #expect(snapshot.executionState == .cancelled)
        #expect(snapshot.lane == .failed)
        #expect(snapshot.lastEventAt == nil)
    }

    @Test func terminalRunCannotReturnToActiveThroughReview() {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .completed),
            event(sequence: 3, kind: .reviewRequested),
            event(sequence: 4, kind: .resumed),
        ]

        #expect(
            throws: RunCenterProjectionError.invalidTransition(
                from: .completed,
                to: .running,
                sequence: 4
            )
        ) {
            try RunCenterProjector.project(
                runId: runId,
                events: events,
                proofContract: .none
            )
        }
    }

    @Test func terminalOutcomeCannotBeRewritten() {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .failed),
            event(sequence: 3, kind: .completed),
        ]

        #expect(
            throws: RunCenterProjectionError.invalidTransition(
                from: .failed,
                to: .completed,
                sequence: 3
            )
        ) {
            try RunCenterProjector.project(
                runId: runId,
                events: events,
                proofContract: .none
            )
        }
    }

    @Test func evidenceAndRelationshipFactsMayFollowTerminalEvent() throws {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .completed),
            event(sequence: 3, kind: .evidenceAttached),
            event(sequence: 4, kind: .childLinked),
            event(sequence: 5, kind: .retryLinked),
        ]

        let snapshot = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .none
        )
        #expect(snapshot.executionState == .completed)
        #expect(snapshot.lane == .done)
    }

    @Test func nonterminalLifecycleRegressionsFailClosed() {
        let cases: [([RunCenterEventKind], RunCenterExecutionState, RunCenterExecutionState, Int)] = [
            ([.started, .queued], .running, .queued, 2),
            ([.started, .resumed], .running, .running, 2),
            ([.started, .waitingForInput, .started], .waitingForInput, .running, 3),
        ]

        for (kinds, from, to, sequence) in cases {
            let events = kinds.enumerated().map {
                event(sequence: $0.offset + 1, kind: $0.element)
            }
            #expect(
                throws: RunCenterProjectionError.invalidTransition(
                    from: from,
                    to: to,
                    sequence: sequence
                )
            ) {
                try RunCenterProjector.project(
                    runId: runId,
                    events: events,
                    proofContract: .none
                )
            }
        }
    }

    @Test func nonCompletedExecutionCannotBecomeProvenLane() throws {
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            events: [
                event(sequence: 1, kind: .started),
                event(sequence: 2, kind: .reviewRequested),
            ],
            proofContract: .required(["tests"]),
            evidenceOutcomes: ["tests": .passed]
        )

        #expect(snapshot.executionState == .running)
        #expect(snapshot.reviewPending)
        #expect(snapshot.evidenceState == .proven)
        #expect(snapshot.lane == .working)
    }

    @Test func requestedReviewBlocksDoneUntilResolved() throws {
        let pendingEvents = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .reviewRequested),
            event(sequence: 3, kind: .completed),
        ]
        let pending = try RunCenterProjector.project(
            runId: runId,
            events: pendingEvents,
            proofContract: .none
        )
        let resolved = try RunCenterProjector.project(
            runId: runId,
            events: pendingEvents + [event(sequence: 4, kind: .reviewResolved)],
            proofContract: .none
        )

        #expect(pending.reviewPending)
        #expect(pending.lane == .inReview)
        #expect(!resolved.reviewPending)
        #expect(resolved.lane == .done)
    }

    @Test func approvalWaitCannotResumeUntilApprovalIsResolved() throws {
        let bypass = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .approvalRequested),
            event(sequence: 3, kind: .resumed),
        ]
        let clarificationResolution = [
            event(sequence: 1, kind: .started),
            event(sequence: 2, kind: .waitingForInput),
            event(sequence: 3, kind: .approvalResolved),
        ]

        #expect(throws: RunCenterProjectionError.self) {
            try RunCenterProjector.project(
                runId: runId,
                events: bypass,
                proofContract: .none
            )
        }
        #expect(throws: RunCenterProjectionError.self) {
            try RunCenterProjector.project(
                runId: runId,
                events: clarificationResolution,
                proofContract: .none
            )
        }

        let resolved = try RunCenterProjector.project(
            runId: runId,
            events: [
                event(sequence: 1, kind: .started),
                event(sequence: 2, kind: .approvalRequested),
                event(sequence: 3, kind: .approvalResolved),
                event(sequence: 4, kind: .resumed),
            ],
            proofContract: .none
        )
        #expect(resolved.executionState == .running)
        #expect(!resolved.approvalPending)
    }

    @Test func pendingReviewCanBeResolvedAfterTerminalFailure() throws {
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            events: [
                event(sequence: 1, kind: .started),
                event(sequence: 2, kind: .reviewRequested),
                event(sequence: 3, kind: .failed),
                event(sequence: 4, kind: .reviewResolved),
            ],
            proofContract: .none
        )

        #expect(snapshot.executionState == .failed)
        #expect(!snapshot.reviewPending)
        #expect(snapshot.lane == .failed)
    }

    @Test func completionRequiresAStartedExecution() {
        #expect(
            throws: RunCenterProjectionError.invalidTransition(
                from: .created,
                to: .completed,
                sequence: 1
            )
        ) {
            try RunCenterProjector.project(
                runId: runId,
                events: [event(sequence: 1, kind: .completed)],
                proofContract: .none
            )
        }
    }

    @Test func stateNeutralEventsStillValidateTheirLifecyclePhase() {
        let cases: [[RunCenterEventKind]] = [
            [.progress],
            [.started, .approvalResolved],
            [.started, .retryLinked],
            [.started, .completed, .progress],
        ]

        for kinds in cases {
            let events = kinds.enumerated().map {
                event(sequence: $0.offset + 1, kind: $0.element)
            }
            #expect(throws: RunCenterProjectionError.self) {
                try RunCenterProjector.project(
                    runId: runId,
                    events: events,
                    proofContract: .none
                )
            }
        }
    }

    @Test func everyEvidenceStatusHasExplicitClassification() {
        let expected: [EvidenceReportStatus: RunCenterEvidenceState] = [
            .passed: .proven,
            .failed: .failed,
            .partial: .partial,
            .blocked: .blocked,
            .unavailable: .blocked,
            .error: .failed,
            .unknown: .unproven,
        ]

        for status in EvidenceReportStatus.allCases {
            #expect(
                RunCenterProjector.classifyEvidence(
                    contract: .required([status.rawValue]),
                    outcomes: [status.rawValue: status]
                ) == expected[status]
            )
        }
    }

    @Test func invalidOrUnavailableProofContractFailsClosed() {
        let empty = RunCenterProjector.classifyEvidence(
            contract: .required(["\n"]),
            outcomes: ["\n": .passed]
        )
        let unavailable = RunCenterProjector.classifyEvidence(
            contract: .unavailable("receipt database corrupt"),
            outcomes: [:]
        )

        #expect(empty == .unproven)
        #expect(unavailable == .blocked)
    }

    @Test func createdEventIsAcceptedOnlyOnceAtTheBeginning() {
        #expect(throws: RunCenterProjectionError.self) {
            try RunCenterProjector.project(
                runId: runId,
                events: [
                    event(sequence: 1, kind: .created),
                    event(sequence: 2, kind: .created),
                ],
                proofContract: .none
            )
        }
    }

    @Test func migratedTerminalReceiptMustMatchMaterializedStatus() {
        let mismatches: [(AgentRunStatus, RunCenterEventKind)] = [
            (.success, .failed),
            (.error, .completed),
            (.clamped, .completed),
            (.cancelled, .interrupted),
            (.interrupted, .cancelled),
        ]

        for (status, kind) in mismatches {
            for kinds in [[kind], [.progress, kind]] {
                let events = kinds.enumerated().map {
                    event(sequence: $0.offset + 1, kind: $0.element)
                }
                #expect(throws: RunCenterProjectionError.self) {
                    try RunCenterProjector.project(
                        runId: runId,
                        legacyStatus: status,
                        events: events,
                        proofContract: .none
                    )
                }
            }
        }
    }

    @Test func runningOnlyLegacyInferenceRejectsEveryNonRunningStatus() {
        let statuses: [AgentRunStatus] = [
            .queued, .waitingForInput, .review, .success, .error, .cancelled,
            .clamped, .interrupted,
        ]
        let kinds: [RunCenterEventKind] = [
            .progress, .waitingForInput, .approvalRequested,
        ]

        for status in statuses {
            for kind in kinds {
                #expect(throws: RunCenterProjectionError.self) {
                    try RunCenterProjector.project(
                        runId: runId,
                        legacyStatus: status,
                        events: [event(sequence: 1, kind: kind)],
                        proofContract: .none
                    )
                }
            }
        }
    }

    @Test func duplicateSequenceFailsClosed() {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 1, kind: .progress),
        ]

        #expect(throws: RunCenterProjectionError.duplicateSequence(1)) {
            try RunCenterProjector.project(
                runId: runId,
                events: events,
                proofContract: .none
            )
        }
    }

    @Test func missingSequenceFailsClosed() {
        let events = [
            event(sequence: 1, kind: .started),
            event(sequence: 3, kind: .progress),
        ]

        #expect(throws: RunCenterProjectionError.missingSequence(expected: 2, actual: 3)) {
            try RunCenterProjector.project(
                runId: runId,
                events: events,
                proofContract: .none
            )
        }
    }

    private func event(
        sequence: Int,
        kind: RunCenterEventKind
    ) -> RunCenterEvent {
        RunCenterEvent(
            id: UUID(),
            runId: runId,
            sequence: sequence,
            kind: kind,
            occurredAt: baseDate.addingTimeInterval(TimeInterval(sequence))
        )
    }
}
