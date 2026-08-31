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

private final class HeldRunLifecycleRecorder:
    RunLifecycleRecording, @unchecked Sendable
{
    private let lock = NSLock()
    private let rejectsStart: Bool
    private var terminalFailuresRemaining: Int
    private var storedAdmissions: [RunLifecycleAdmission] = []
    private var storedEvents: [(UUID, RunCenterEventKind)] = []
    private var storedTerminalAttempts: [RunLifecycleTerminalReceipt] = []
    private var storedTerminals: [RunLifecycleTerminalReceipt] = []

    init(
        rejectsStart: Bool = false,
        terminalFailures: Int = 0
    ) {
        self.rejectsStart = rejectsStart
        self.terminalFailuresRemaining = terminalFailures
    }

    var admissions: [RunLifecycleAdmission] {
        lock.withLock { storedAdmissions }
    }

    var events: [(UUID, RunCenterEventKind)] {
        lock.withLock { storedEvents }
    }

    var terminalAttempts: [RunLifecycleTerminalReceipt] {
        lock.withLock { storedTerminalAttempts }
    }

    var terminals: [RunLifecycleTerminalReceipt] {
        lock.withLock { storedTerminals }
    }

    func admit(
        _ admission: RunLifecycleAdmission
    ) throws -> RunLifecycleAdmissionReceipt {
        lock.withLock { storedAdmissions.append(admission) }
        return RunLifecycleAdmissionReceipt(
            runId: admission.runId,
            rootRunId: admission.rootRunId ?? admission.runId
        )
    }

    func append(
        runId: UUID,
        kind: RunCenterEventKind,
        occurredAt _: Date,
        message _: String?,
        metadata _: [String: String]
    ) throws {
        if rejectsStart, kind == .started {
            throw RejectedAdmission.expected
        }
        lock.withLock { storedEvents.append((runId, kind)) }
    }

    func end(_ receipt: RunLifecycleTerminalReceipt) throws {
        let shouldFail = lock.withLock { () -> Bool in
            storedTerminalAttempts.append(receipt)
            if terminalFailuresRemaining > 0 {
                terminalFailuresRemaining -= 1
                return true
            }
            storedTerminals.append(receipt)
            return false
        }
        if shouldFail {
            throw RejectedAdmission.expected
        }
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
        let missingAgent = DispatchRequest(
            prompt: valid.prompt,
            source: .delegation,
            parentRunId: valid.parentRunId,
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

        for malformed in [
            missingAgent,
            missingParent,
            missingRoot,
            missingSession,
            blankToolCall,
        ] {
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

    @Test func heldDelegationIsQueuedBeforeRegistrationAndCanCancel() throws {
        let recorder = HeldRunLifecycleRecorder()
        let manager = BackgroundTaskManager.makeForTesting(
            runLifecycleRecorder: recorder
        )
        let request = DispatchRequest(
            prompt: "Held delegated child",
            agentId: UUID(),
            showToast: false,
            source: .delegation,
            parentRunId: UUID(),
            rootRunId: UUID(),
            parentSessionId: UUID(),
            parentToolCallId: "held-delegation",
            stableJobId: "held-job"
        )

        let held = try manager.holdDelegatedChat(
            request,
            modelId: "test-model"
        )

        #expect(recorder.admissions.count == 1)
        #expect(recorder.admissions.first?.runId == request.runId)
        #expect(recorder.admissions.first?.startsImmediately == false)
        #expect(recorder.events.isEmpty)
        #expect(manager.backgroundTasks.isEmpty)

        let cancelled = ToolEnvelope.failure(
            kind: .userDenied,
            message: "Batch stopped before launch.",
            tool: "spawn_batch",
            retryable: false,
            metadata: ["cancelled": true]
        )
        let envelope = BackgroundTaskManager.settleHeldDelegatedRun(
            held,
            status: .cancelled,
            error: nil,
            envelope: cancelled,
            tool: "spawn_batch"
        )

        #expect(held.isTerminal)
        #expect(recorder.events.isEmpty)
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.status == .cancelled)
        #expect(envelope.contains(request.runId.uuidString))
    }

    @Test func heldDelegationDispatchAndStartAreOneShot() throws {
        let recorder = HeldRunLifecycleRecorder()
        let manager = BackgroundTaskManager.makeForTesting(
            runLifecycleRecorder: recorder
        )
        let request = DispatchRequest(
            prompt: "Held delegated child",
            agentId: UUID(),
            showToast: false,
            source: .delegation,
            parentRunId: UUID(),
            rootRunId: UUID(),
            parentSessionId: UUID(),
            parentToolCallId: "held-one-shot"
        )
        let held = try manager.holdDelegatedChat(request, modelId: "test-model")

        #expect(held.claimDispatch())
        #expect(!held.claimDispatch())
        try held.start()
        try held.start()

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.0 == request.runId)
        #expect(recorder.events.first?.1 == .started)
    }

    @Test func heldDelegationStartFailureNeverExecutesTheChat() async throws {
        try await ChatHistoryTestStorage.run {
            let recorder = HeldRunLifecycleRecorder(rejectsStart: true)
            let manager = BackgroundTaskManager.makeForTesting(
                runLifecycleRecorder: recorder
            )
            let request = DispatchRequest(
                prompt: "Held delegated child",
                agentId: UUID(),
                showToast: false,
                source: .delegation,
                parentRunId: UUID(),
                rootRunId: UUID(),
                parentSessionId: UUID(),
                parentToolCallId: "held-start-failure"
            )
            let held = try manager.holdDelegatedChat(
                request,
                modelId: "test-model"
            )

            let handle = try #require(await manager.dispatchHeldChat(held))
            let state = try #require(manager.backgroundTasks[handle.id])

            guard case .failed(let summary) = state.status else {
                Issue.record("Expected the rejected durable start to fail the task")
                return
            }
            #expect(summary.contains("was not executed"))
            #expect(state.chatSession?.isStreaming == false)
            #expect(state.agentRunId == nil)
            #expect(held.isTerminal)
            #expect(recorder.events.isEmpty)
            #expect(recorder.terminals.count == 1)
            #expect(recorder.terminals.first?.status == .error)
            #expect(await manager.dispatchHeldChat(held) == nil)

            manager.finalizeTask(handle.id)
        }
    }

    @Test func heldDelegationRetriesTheExactTerminalReceipt() throws {
        let recorder = HeldRunLifecycleRecorder(terminalFailures: 1)
        let manager = BackgroundTaskManager.makeForTesting(
            runLifecycleRecorder: recorder
        )
        let request = DispatchRequest(
            prompt: "Held delegated child",
            agentId: UUID(),
            showToast: false,
            source: .delegation,
            parentRunId: UUID(),
            rootRunId: UUID(),
            parentSessionId: UUID(),
            parentToolCallId: "held-terminal-retry"
        )
        let held = try manager.holdDelegatedChat(request, modelId: "test-model")
        #expect(held.claimDispatch())
        try held.start()

        let receipt = RunLifecycleTerminalReceipt(
            runId: request.runId,
            status: .success,
            endedAt: Date(timeIntervalSince1970: 1234),
            tokensIn: 12,
            tokensOut: 34
        )
        try held.end(receipt)

        #expect(held.isTerminal)
        #expect(recorder.terminalAttempts == [receipt, receipt])
        #expect(recorder.terminals == [receipt])
    }

    @Test func uncertainSuccessIntentIsNotOverwrittenByReconciliation() throws {
        let recorder = HeldRunLifecycleRecorder(terminalFailures: 2)
        let manager = BackgroundTaskManager.makeForTesting(
            runLifecycleRecorder: recorder
        )
        let request = DispatchRequest(
            prompt: "Held delegated child",
            agentId: UUID(),
            showToast: false,
            source: .delegation,
            parentRunId: UUID(),
            rootRunId: UUID(),
            parentSessionId: UUID(),
            parentToolCallId: "held-terminal-uncertain"
        )
        let held = try manager.holdDelegatedChat(request, modelId: "test-model")
        #expect(held.claimDispatch())
        try held.start()
        do {
            try held.end(
                RunLifecycleTerminalReceipt(
                    runId: request.runId,
                    status: .success
                )
            )
            Issue.record("Expected terminal acknowledgement to remain uncertain")
        } catch {}

        let envelope = BackgroundTaskManager.settleHeldDelegatedRun(
            held,
            status: .error,
            error: "scheduler returned no result",
            envelope: ToolEnvelope.failure(
                kind: .executionError,
                message: "scheduler returned no result",
                tool: "spawn_batch",
                retryable: false
            ),
            tool: "spawn_batch"
        )
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(envelope.utf8))
                as? [String: Any]
        )

        #expect(payload["terminal_write_failed"] as? Bool == true)
        #expect(recorder.terminalAttempts.count == 2)
        #expect(recorder.terminalAttempts.allSatisfy { $0.status == .success })
        #expect(recorder.terminals.isEmpty)
    }
}
