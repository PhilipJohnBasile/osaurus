//
//  DispatchRunIdentityTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

private enum RejectedAdmission: Error {
    case expected
}

private final class RejectingRunLifecycleRecorder:
    RunLifecycleRecording, @unchecked Sendable
{
    private let lock = NSLock()
    private let rejectsAdmission: Bool
    private let rejectsTerminal: Bool
    private var storedAdmissions: [RunLifecycleAdmission] = []
    private var storedAppends = 0
    private var storedTerminals: [RunLifecycleTerminalReceipt] = []

    init(
        rejectsAdmission: Bool = true,
        rejectsTerminal: Bool = false
    ) {
        self.rejectsAdmission = rejectsAdmission
        self.rejectsTerminal = rejectsTerminal
    }

    var admissions: [RunLifecycleAdmission] {
        lock.withLock { storedAdmissions }
    }

    var appendCount: Int {
        lock.withLock { storedAppends }
    }

    var terminals: [RunLifecycleTerminalReceipt] {
        lock.withLock { storedTerminals }
    }

    func admit(
        _ admission: RunLifecycleAdmission
    ) throws -> RunLifecycleAdmissionReceipt {
        lock.withLock { storedAdmissions.append(admission) }
        if rejectsAdmission {
            throw RejectedAdmission.expected
        }
        return RunLifecycleAdmissionReceipt(
            runId: admission.runId,
            rootRunId: admission.rootRunId ?? admission.runId
        )
    }

    func append(
        runId _: UUID,
        kind _: RunCenterEventKind,
        occurredAt _: Date,
        message _: String?,
        metadata _: [String: String]
    ) throws {
        lock.withLock { storedAppends += 1 }
    }

    func end(_ receipt: RunLifecycleTerminalReceipt) throws {
        if rejectsTerminal {
            throw RejectedAdmission.expected
        }
        lock.withLock { storedTerminals.append(receipt) }
    }
}

@Suite("Dispatch durable run identity", .serialized)
@MainActor
struct DispatchRunIdentityTests {
    @Test func executionIdentityIsDistinctFromReattachableContextIdentity() {
        let runId = UUID()
        let contextId = UUID()
        let request = DispatchRequest(
            runId: runId,
            id: contextId,
            prompt: "Continue the conversation",
            externalSessionKey: "stable-conversation"
        )

        #expect(request.runId == runId)
        #expect(request.id == contextId)
        #expect(request.runId != request.id)
    }

    @Test func childProvenanceRoundTripsWithoutBecomingIdentity() {
        let parentRunId = UUID()
        let rootRunId = UUID()
        let parentSessionId = UUID()
        let request = DispatchRequest(
            prompt: "Delegated child",
            source: .delegation,
            parentRunId: parentRunId,
            rootRunId: rootRunId,
            parentSessionId: parentSessionId,
            parentToolCallId: "call-42",
            stableJobId: "batch-job-42"
        )
        let handle = DispatchHandle(id: request.id, runId: request.runId, request: request)

        #expect(handle.runId == request.runId)
        #expect(request.parentRunId == parentRunId)
        #expect(request.rootRunId == rootRunId)
        #expect(request.parentSessionId == parentSessionId)
        #expect(request.parentToolCallId == "call-42")
        #expect(request.stableJobId == "batch-job-42")
        #expect(request.runId != parentRunId)
        #expect(request.runId != rootRunId)
    }

    @Test func onlyTrueDelegationFailsClosedWhenDurableAdmissionIsRejected() {
        #expect(BackgroundTaskManager.requiresDurableAdmission(for: .delegation))
        for source in SessionSource.allCases where source != .delegation {
            #expect(!BackgroundTaskManager.requiresDurableAdmission(for: source))
        }
    }

    @Test func delegationRequiresCompleteImmutableProvenance() {
        let valid = DispatchRequest(
            prompt: "Delegated child",
            agentId: UUID(),
            source: .delegation,
            parentRunId: UUID(),
            rootRunId: UUID(),
            parentSessionId: UUID(),
            parentToolCallId: "call-42"
        )
        #expect(BackgroundTaskManager.isDispatchRequestValid(valid))

        let missingParent = DispatchRequest(
            prompt: valid.prompt,
            agentId: valid.agentId,
            source: .delegation,
            rootRunId: valid.rootRunId,
            parentSessionId: valid.parentSessionId,
            parentToolCallId: valid.parentToolCallId
        )
        let missingRoot = DispatchRequest(
            prompt: valid.prompt,
            agentId: valid.agentId,
            source: .delegation,
            parentRunId: valid.parentRunId,
            parentSessionId: valid.parentSessionId,
            parentToolCallId: valid.parentToolCallId
        )
        let missingSession = DispatchRequest(
            prompt: valid.prompt,
            agentId: valid.agentId,
            source: .delegation,
            parentRunId: valid.parentRunId,
            rootRunId: valid.rootRunId,
            parentToolCallId: valid.parentToolCallId
        )
        let blankToolCall = DispatchRequest(
            prompt: valid.prompt,
            agentId: valid.agentId,
            source: .delegation,
            parentRunId: valid.parentRunId,
            rootRunId: valid.rootRunId,
            parentSessionId: valid.parentSessionId,
            parentToolCallId: "  \n"
        )

        for malformed in [missingParent, missingRoot, missingSession, blankToolCall] {
            #expect(!BackgroundTaskManager.isDispatchRequestValid(malformed))
        }
    }

    @Test func rejectedDelegationAdmissionNeverRegistersOrStarts() async throws {
        try await ChatHistoryTestStorage.run {
            let recorder = RejectingRunLifecycleRecorder()
            let manager = BackgroundTaskManager.makeForTesting(
                runLifecycleRecorder: recorder
            )
            let request = DispatchRequest(
                prompt: "Delegated child",
                agentId: UUID(),
                showToast: false,
                source: .delegation,
                parentRunId: UUID(),
                rootRunId: UUID(),
                parentSessionId: UUID(),
                parentToolCallId: "spawn-agent-call",
                stableJobId: "sk-test-secret"
            )

            let handle = await manager.dispatchChat(request)

            #expect(handle == nil)
            #expect(recorder.admissions.count == 1)
            #expect(recorder.admissions.first?.runId == request.runId)
            #expect(
                recorder.admissions.first?.triggerPayload?.contains(
                    #""stable_job_id":"<redacted>""#
                ) == true
            )
            #expect(
                recorder.admissions.first?.triggerPayload?.contains("sk-test-secret")
                    == false
            )
            #expect(recorder.appendCount == 0)
            #expect(recorder.terminals.isEmpty)
            #expect(manager.backgroundTasks.isEmpty)
        }
    }

    @Test func delegatedTerminalFailureCannotReportCompleted() {
        let recorder = RejectingRunLifecycleRecorder(
            rejectsAdmission: false,
            rejectsTerminal: true
        )
        let manager = BackgroundTaskManager.makeForTesting(
            runLifecycleRecorder: recorder
        )
        let context = ExecutionContext(agentId: Agent.defaultId)
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "Delegated child",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            source: .delegation,
            showToast: false
        )
        let runId = UUID()
        state.agentRunId = runId
        manager.registerTaskForTesting(state)
        defer { manager.finalizeTask(state.id) }

        manager.markCompletedForTesting(
            state,
            success: true,
            summary: "child work settled"
        )

        guard case .failed(let summary) = state.status else {
            Issue.record("Expected the delegated terminal write failure to win")
            return
        }
        #expect(summary.contains("durable terminal state"))
        #expect(state.agentRunId == runId)
        #expect(recorder.terminals.isEmpty)
    }
}
