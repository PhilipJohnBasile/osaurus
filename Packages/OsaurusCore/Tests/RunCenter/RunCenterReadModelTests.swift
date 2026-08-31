//
//  RunCenterReadModelTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Run Center read model")
struct RunCenterReadModelTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func boardUsesReducerLanesAndSurfacesCorruptionSeparately() throws {
        let working = makeRun(status: .running, offset: 1)
        let needsYou = makeRun(status: .waitingForInput, offset: 2)
        let inReview = makeRun(status: .success, offset: 3)
        let done = makeRun(status: .success, offset: 4)
        let failed = makeRun(status: .error, offset: 5)
        let corrupt = makeRun(status: .running, offset: 6)

        let facts = RunCenterBoardFacts(
            runs: [corrupt, failed, done, inReview, needsYou, working],
            eventsByRunId: [
                working.id: [event(working, 1, .started)],
                needsYou.id: [
                    event(needsYou, 1, .started),
                    event(needsYou, 2, .approvalRequested, message: "Approve deploy"),
                ],
                inReview.id: [
                    event(inReview, 1, .started),
                    event(inReview, 2, .reviewRequested),
                    event(inReview, 3, .completed),
                ],
                done.id: [
                    event(done, 1, .started),
                    event(
                        done,
                        2,
                        .progress,
                        metadata: ["aggregate_status": "partial_failure"]
                    ),
                    event(done, 3, .completed),
                ],
                failed.id: [
                    event(failed, 1, .started),
                    event(failed, 2, .failed),
                ],
                corrupt.id: [
                    event(corrupt, 1, .started),
                    event(corrupt, 3, .progress),
                ],
            ]
        )

        let board = RunCenterReadRepository.projectBoard(
            facts,
            refreshedAt: baseDate
        )

        #expect(board.cards(in: .working).map(\.id) == [working.id])
        #expect(board.cards(in: .needsYou).map(\.id) == [needsYou.id])
        #expect(board.cards(in: .inReview).map(\.id) == [done.id, inReview.id])
        #expect(board.cards(in: .proven).isEmpty)
        #expect(board.cards(in: .done).isEmpty)
        #expect(board.cards(in: .failed).map(\.id) == [failed.id])
        #expect(board.needsYou.first?.attention?.kind == .approval)
        #expect(board.cards(in: .inReview).first?.hasPartialAggregate == true)
        #expect(board.unavailableCards.map(\.id) == [corrupt.id])
    }

    @Test func detailUsesCanonicalVisibleConversationAndAllowlistedEvents() throws {
        let run = makeRun(status: .success, offset: 1, sessionId: UUID())
        let events = [
            event(run, 1, .started),
            event(
                run,
                2,
                .progress,
                message: "tool settled",
                metadata: [
                    "phase": "tool",
                    "authorization": "Bearer secret",
                ]
            ),
            event(run, 3, .completed),
        ]
        let tool = ToolCall(
            id: "call-1",
            type: "function",
            function: ToolCallFunction(name: "read_file", arguments: "{\"path\":\"secret\"}")
        )
        let artifact = SharedArtifact(
            contextId: run.sessionId!.uuidString,
            contextType: .chat,
            filename: "report.md",
            mimeType: "text/markdown",
            fileSize: 42,
            hostPath: "/private/report.md",
            isFinalResult: true
        )
        let session = ChatSessionData(
            id: run.sessionId!,
            title: "Canonical conversation",
            turns: [
                ChatTurnData(role: .user, content: "Inspect the project"),
                ChatTurnData(
                    role: .assistant,
                    content: "Inspection complete",
                    sharedArtifacts: [artifact],
                    toolCalls: [tool],
                    toolCallDurations: ["call-1": 1.25],
                    thinking: "hidden reasoning"
                ),
                ChatTurnData(role: .tool, content: "private tool result"),
            ]
        )
        let trace = RunTrace(
            runId: run.id,
            agentId: run.agentId,
            sessionId: run.sessionId!.uuidString,
            triggerSource: "chat",
            status: "success",
            startedAt: run.startedAt,
            endedAt: run.updatedAt,
            tokensIn: 10,
            tokensOut: 20,
            costUSD: nil,
            errorMessage: nil,
            turns: []
        )
        let facts = RunCenterDetailFacts(
            run: run,
            tree: [run],
            eventsByRunId: [run.id: events]
        )
        let repository = RunCenterReadRepository(
            loadBoardFacts: { RunCenterBoardFacts(runs: [run], eventsByRunId: [run.id: events]) },
            loadDetailFacts: { id in id == run.id ? facts : nil },
            loadConversation: { id in id == session.id ? session : nil },
            loadTrace: { agentId, runId in
                agentId == run.agentId && runId == run.id ? .available(trace) : .missing
            }
        )

        let detail = try repository.detail(runId: run.id)

        #expect(
            detail.conversation?.turns.map(\.content) == [
                "Inspect the project", "Inspection complete",
            ]
        )
        #expect(detail.conversation?.turns.contains { $0.content.contains("hidden") } == false)
        #expect(detail.conversation?.turns.contains { $0.content.contains("private") } == false)
        #expect(detail.conversation?.isWholeConversationContext == true)
        #expect(detail.eventStreams[0].events[1].metadata == ["phase": "tool"])
        if case .available(let traceSummary) = detail.trace {
            #expect(traceSummary.tokensOut == 20)
        } else {
            Issue.record("expected a trace summary")
        }
        #expect(detail.proofAvailability.contains("No durable proof contract"))
    }

    @Test func needsYouDistinguishesClarificationApprovalAndReadyToResume() {
        let clarification = makeRun(status: .waitingForInput, offset: 1)
        let approval = makeRun(status: .waitingForInput, offset: 2)
        let ready = makeRun(status: .waitingForInput, offset: 3)
        let facts = RunCenterBoardFacts(
            runs: [clarification, approval, ready],
            eventsByRunId: [
                clarification.id: [
                    event(clarification, 1, .started),
                    event(clarification, 2, .waitingForInput),
                ],
                approval.id: [
                    event(approval, 1, .started),
                    event(approval, 2, .approvalRequested),
                ],
                ready.id: [
                    event(ready, 1, .started),
                    event(ready, 2, .approvalRequested),
                    event(ready, 3, .approvalResolved),
                ],
            ]
        )

        let board = RunCenterReadRepository.projectBoard(
            facts,
            refreshedAt: baseDate
        )
        let attentionByRun = Dictionary(
            uniqueKeysWithValues: board.needsYou.compactMap { card in
                card.attention.map { (card.id, $0.kind) }
            }
        )

        #expect(attentionByRun[clarification.id] == .clarification)
        #expect(attentionByRun[approval.id] == .approval)
        #expect(attentionByRun[ready.id] == .readyToResume)
    }

    private func makeRun(
        status: AgentRunStatus,
        offset: TimeInterval,
        sessionId: UUID? = nil
    ) -> AgentRunRecord {
        let startedAt = baseDate.addingTimeInterval(offset)
        return AgentRunRecord(
            id: UUID(),
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Run \(Int(offset))",
            startedAt: startedAt,
            endedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : nil,
            status: status,
            sessionId: sessionId,
            rootRunId: nil,
            title: "Run \(Int(offset))",
            updatedAt: startedAt.addingTimeInterval(1),
            eventBaselineState: .created
        )
    }

    private func event(
        _ run: AgentRunRecord,
        _ sequence: Int,
        _ kind: RunCenterEventKind,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) -> RunCenterEvent {
        RunCenterEvent(
            runId: run.id,
            sequence: sequence,
            kind: kind,
            occurredAt: run.startedAt.addingTimeInterval(TimeInterval(sequence)),
            message: message,
            metadata: metadata
        )
    }
}
