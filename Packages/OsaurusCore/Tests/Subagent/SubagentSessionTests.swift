//
//  SubagentSessionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the shared host (`SubagentSession`) via a scripted
//  kind. This is the deterministic seam the whole subagent family rides on:
//  resolve → permission → handoff → run → normalize → cleanup, with no
//  tokens burned. Exercises the success path, the unified recursion guard,
//  permission refusal, reject-before-evict, the optional handoff middleware,
//  and feed lifecycle.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Scripted kind

/// A fully scripted `SubagentKind` so the host's control flow runs without a
/// model. Each step is overridable; defaults form a happy path.
private final class ScriptedKind: SubagentKind, @unchecked Sendable {
    let capability: SubagentCapability
    let delegatesDurableLifecycle: Bool
    /// Test-local handoff opt-in (drives `makeHandoff()`); no longer a
    /// `SubagentKind` requirement.
    let needsHandoff: Bool

    var resolve: @Sendable (SubagentScope) async throws -> ResolvedModel
    var decide: @Sendable (SubagentScope, ResolvedModel) async -> SubagentDecision
    var body: @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws -> SubagentResult

    init(
        id: String = "scripted",
        needsHandoff: Bool = false,
        delegatesDurableLifecycle: Bool = false,
        resolve: @escaping @Sendable (SubagentScope) async throws -> ResolvedModel = { _ in
            ResolvedModel(name: "scripted-model", id: "scripted-model", isLocal: true)
        },
        decide: @escaping @Sendable (SubagentScope, ResolvedModel) async -> SubagentDecision = {
            _,
            _ in .allow
        },
        body:
            @escaping @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws ->
            SubagentResult = {
                _,
                _,
                feed,
                _ in
                feed.emitPhase("running")
                return SubagentResult(payload: ["kind": "scripted", "summary": "done"], summary: "done")
            }
    ) {
        self.capability = SubagentCapability(id: id, toolNames: [id], gate: .sandboxExec)
        self.needsHandoff = needsHandoff
        self.delegatesDurableLifecycle = delegatesDurableLifecycle
        self.resolve = resolve
        self.decide = decide
        self.body = body
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel { try await resolve(scope) }
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        await decide(scope, resolved)
    }
    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        try await body(scope, resolved, feed, interrupt)
    }
}

/// Records whether `around` wrapped the run.
private final class RecordingHandoff: SubagentHandoff, @unchecked Sendable {
    var wrapped = false
    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        wrapped = true
        return try await body()
    }
}

// MARK: - Helpers

private func decode(_ envelope: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] ?? [:]
}

private final class RecordingSubagentRunLifecycleRecorder:
    RunLifecycleRecording, @unchecked Sendable
{
    struct RecordedEvent: Sendable, Equatable {
        let runId: UUID
        let kind: RunCenterEventKind
    }

    private enum ExpectedAdmissionError: Error {
        case rejected
    }

    private enum ExpectedTerminalError: Error {
        case rejected
    }

    private let lock = NSLock()
    private let rejectsAdmission: Bool
    private let rejectsTerminal: Bool
    private let interruptOnAdmission: InterruptToken?
    private var storedAdmissions: [RunLifecycleAdmission] = []
    private var storedEvents: [RecordedEvent] = []
    private var storedTerminals: [RunLifecycleTerminalReceipt] = []

    init(
        rejectsAdmission: Bool = false,
        rejectsTerminal: Bool = false,
        interruptOnAdmission: InterruptToken? = nil
    ) {
        self.rejectsAdmission = rejectsAdmission
        self.rejectsTerminal = rejectsTerminal
        self.interruptOnAdmission = interruptOnAdmission
    }

    var admissions: [RunLifecycleAdmission] {
        lock.withLock { storedAdmissions }
    }

    var terminals: [RunLifecycleTerminalReceipt] {
        lock.withLock { storedTerminals }
    }

    var events: [RecordedEvent] {
        lock.withLock { storedEvents }
    }

    func admit(
        _ admission: RunLifecycleAdmission
    ) throws -> RunLifecycleAdmissionReceipt {
        lock.withLock { storedAdmissions.append(admission) }
        interruptOnAdmission?.interrupt()
        if rejectsAdmission {
            throw ExpectedAdmissionError.rejected
        }
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
        lock.withLock {
            storedEvents.append(RecordedEvent(runId: runId, kind: kind))
        }
    }

    func end(_ receipt: RunLifecycleTerminalReceipt) throws {
        if rejectsTerminal {
            throw ExpectedTerminalError.rejected
        }
        lock.withLock { storedTerminals.append(receipt) }
    }
}

private final class RunBindingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRunId: UUID?
    private var storedRootRunId: UUID?

    func capture() {
        lock.withLock {
            storedRunId = ChatExecutionContext.currentRunId
            storedRootRunId = ChatExecutionContext.currentRootRunId
        }
    }

    var value: (runId: UUID?, rootRunId: UUID?) {
        lock.withLock { (storedRunId, storedRootRunId) }
    }
}

private final class UncertainTerminalRunLifecycleRecorder:
    RunLifecycleRecording, @unchecked Sendable
{
    private enum UncertainWrite: Error {
        case acknowledgementLost
    }

    private let lock = NSLock()
    private var storedTerminalAttempts: [RunLifecycleTerminalReceipt] = []

    var terminalAttempts: [RunLifecycleTerminalReceipt] {
        lock.withLock { storedTerminalAttempts }
    }

    func admit(
        _ admission: RunLifecycleAdmission
    ) throws -> RunLifecycleAdmissionReceipt {
        RunLifecycleAdmissionReceipt(
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
    ) throws {}

    func end(_ receipt: RunLifecycleTerminalReceipt) throws {
        let attempt = lock.withLock { () -> Int in
            storedTerminalAttempts.append(receipt)
            return storedTerminalAttempts.count
        }
        if attempt == 1 {
            throw UncertainWrite.acknowledgementLost
        }
    }
}

// MARK: - Tests

@Suite("SubagentSession host")
struct SubagentSessionTests {

    @Test("subagent scope carries explicit Thinking on, off, and unset")
    func subagentScopeCarriesParentThinkingChoice() async {
        await ChatExecutionContext.$currentEnableThinking.withValue(true) {
            #expect(SubagentScope.current().enableThinking == true)
        }
        await ChatExecutionContext.$currentEnableThinking.withValue(false) {
            #expect(SubagentScope.current().enableThinking == false)
        }
        await ChatExecutionContext.$currentEnableThinking.withValue(nil) {
            #expect(SubagentScope.current().enableThinking == nil)
        }
    }

    @Test("batch child feed identity does not replace its transcript launch provenance")
    func batchChildRetainsParentToolCallIdentity() {
        let parentRunId = UUID()
        let rootRunId = UUID()
        let parentScope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "spawn-batch-call",
            agentId: UUID(),
            parentRunId: parentRunId,
            rootRunId: rootRunId
        )
        let first = SpawnBatchTool.childScope(parentScope: parentScope, jobID: "job-3")
        let second = SpawnBatchTool.childScope(parentScope: parentScope, jobID: "job-4")

        #expect(first.runId != second.runId)
        #expect(first.sessionId == parentScope.sessionId)
        #expect(first.parentRunId == parentScope.runId)
        #expect(first.rootRunId == rootRunId)
        #expect(first.toolCallId == "spawn-batch-call:job-3")
        #expect(first.parentToolCallId == "spawn-batch-call")
        #expect(first.stableJobId == "job-3")
    }

    @Test("happy path returns a success envelope carrying the kind payload")
    func happyPath() async {
        let kind = ScriptedKind()
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(ToolEnvelope.isSuccess(envelope))
        let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        #expect(payload?["kind"] as? String == "scripted")
        #expect(payload?["summary"] as? String == "done")
    }

    @Test("in-memory child uses one durable identity and immutable launch provenance")
    func durableChildIdentityAndProvenance() async throws {
        let childRunId = UUID()
        let parentRunId = UUID()
        let rootRunId = UUID()
        let parentSessionId = UUID()
        let recorder = RecordingSubagentRunLifecycleRecorder()
        let binding = RunBindingBox()
        let scope = SubagentScope(
            sessionId: parentSessionId.uuidString,
            toolCallId: "spawn-call-7",
            agentId: UUID(),
            runId: childRunId,
            parentRunId: parentRunId,
            rootRunId: rootRunId
        )
        let kind = ScriptedKind(
            resolve: { _ in
                ResolvedModel(name: "remote-child", id: "remote-child-id", isLocal: false)
            },
            body: { _, _, _, _ in
                binding.capture()
                return SubagentResult(payload: ["summary": "done"])
            }
        )

        let preparation = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected the scripted child to prepare")
            return
        }
        let envelope = await SubagentSession.runPrepared(
            prepared,
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isSuccess(envelope))
        let admission = try #require(recorder.admissions.first)
        #expect(recorder.admissions.count == 1)
        #expect(admission.runId == childRunId)
        #expect(admission.parentRunId == parentRunId)
        #expect(admission.rootRunId == rootRunId)
        #expect(admission.sessionId == parentSessionId)
        #expect(admission.modelId == "remote-child-id")
        let trigger = try #require(admission.triggerPayload)
        #expect(trigger.contains(#""parent_tool_call_id":"spawn-call-7""#))
        #expect(trigger.contains(#""parent_session_id":"\#(parentSessionId.uuidString)""#))
        #expect(binding.value.runId == childRunId)
        #expect(binding.value.rootRunId == rootRunId)
        let payload = try #require(
            ToolEnvelope.successPayload(envelope) as? [String: Any]
        )
        #expect(payload["run_id"] as? String == childRunId.uuidString)
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.runId == childRunId)
        #expect(recorder.terminals.first?.status == .success)
    }

    @Test("child cancellation terminalizes only after the owned run unwinds")
    func durableChildCancellation() async {
        let recorder = RecordingSubagentRunLifecycleRecorder()
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "spawn-cancel",
            agentId: UUID()
        )
        let kind = ScriptedKind(
            resolve: { _ in
                ResolvedModel(name: "remote-child", isLocal: false)
            },
            body: { _, _, _, _ in throw CancellationError() }
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the scripted child to prepare")
            return
        }

        let envelope = await SubagentSession.runPrepared(
            prepared,
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(recorder.admissions.count == 1)
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.runId == scope.runId)
        #expect(recorder.terminals.first?.status == .cancelled)
    }

    @Test("delegated child transfers durable lifecycle to its dispatcher")
    func delegatedChildDoesNotWriteCompetingLifecycle() async {
        let recorder = RecordingSubagentRunLifecycleRecorder()
        let kind = ScriptedKind(delegatesDurableLifecycle: true)
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: SubagentScope(
                sessionId: UUID().uuidString,
                toolCallId: "spawn-agent",
                agentId: UUID(),
                parentRunId: UUID(),
                rootRunId: UUID()
            )
        ) else {
            Issue.record("Expected the delegated child to prepare")
            return
        }

        let envelope = await SubagentSession.runPrepared(
            prepared,
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(recorder.admissions.isEmpty)
        #expect(recorder.terminals.isEmpty)
    }

    @Test("held ordinary child is queued before launch and started exactly once")
    func heldOrdinaryChildLaunchesThroughItsLifecycleOwner() async throws {
        let recorder = RecordingSubagentRunLifecycleRecorder()
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "held-child",
            agentId: UUID(),
            parentRunId: UUID(),
            rootRunId: UUID(),
            stableJobId: "stable-child"
        )
        let kind = ScriptedKind()
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the ordinary child to prepare")
            return
        }
        let held = try #require(
            SubagentSession.holdDurableChild(
                prepared,
                recorder: recorder
            )
        )

        #expect(recorder.admissions.count == 1)
        #expect(recorder.admissions.first?.runId == scope.runId)
        #expect(recorder.admissions.first?.startsImmediately == false)
        #expect(recorder.events.isEmpty)

        let envelope = await SubagentSession.runPrepared(
            prepared,
            skipAdmission: true,
            handoffOverride: PassthroughHandoff(),
            runLifecycleRecorder: recorder,
            heldDurableChild: held
        )

        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(decode(envelope)["run_id"] as? String == scope.runId.uuidString)
        #expect(
            recorder.events
                == [.init(runId: scope.runId, kind: .started)]
        )
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.runId == scope.runId)
        #expect(recorder.terminals.first?.status == .success)
    }

    @Test("held ordinary child can settle without a false start")
    func heldOrdinaryChildSettlesBeforeExecution() async throws {
        let recorder = RecordingSubagentRunLifecycleRecorder()
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "held-child-cancelled",
            agentId: UUID(),
            parentRunId: UUID(),
            rootRunId: UUID(),
            stableJobId: "stable-cancelled"
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            ScriptedKind(),
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the ordinary child to prepare")
            return
        }
        let held = try #require(
            SubagentSession.holdDurableChild(
                prepared,
                recorder: recorder
            )
        )
        let cancelled = ToolEnvelope.failure(
            kind: .userDenied,
            message: "Batch stopped before this child launched.",
            tool: "scripted",
            retryable: false,
            metadata: ["cancelled": true]
        )

        let envelope = SubagentSession.settleDurableChild(
            held,
            status: .cancelled,
            envelope: cancelled,
            tool: "scripted"
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(decode(envelope)["run_id"] as? String == scope.runId.uuidString)
        #expect(recorder.events.isEmpty)
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.status == .cancelled)
    }

    @Test("uncertain terminal retry reuses the exact first receipt")
    func heldChildTerminalRetryIsReceiptIdempotent() async throws {
        let recorder = UncertainTerminalRunLifecycleRecorder()
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "held-child-uncertain-terminal",
            agentId: UUID(),
            parentRunId: UUID(),
            rootRunId: UUID()
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            ScriptedKind(),
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the ordinary child to prepare")
            return
        }
        let held = try #require(
            SubagentSession.holdDurableChild(
                prepared,
                recorder: recorder
            )
        )
        let failure = ToolEnvelope.failure(
            kind: .executionError,
            message: "scheduler refused",
            tool: "scripted",
            retryable: false
        )

        let first = SubagentSession.settleDurableChild(
            held,
            status: .error,
            error: "first terminal intent",
            envelope: failure,
            tool: "scripted"
        )
        let second = SubagentSession.settleDurableChild(
            held,
            status: .cancelled,
            envelope: failure,
            tool: "scripted"
        )

        #expect(decode(first)["terminal_write_failed"] == nil)
        #expect(decode(second)["terminal_write_failed"] == nil)
        let attempts = recorder.terminalAttempts
        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
        #expect(attempts[0].status == .error)
        #expect(attempts[0].error == "first terminal intent")
    }

    @Test("ordinary child fails closed when durable admission is rejected")
    func rejectedDurableChildNeverExecutes() async {
        let recorder = RecordingSubagentRunLifecycleRecorder(rejectsAdmission: true)
        let bodyRan = RunBindingBox()
        let kind = ScriptedKind(
            body: { _, _, _, _ in
                bodyRan.capture()
                return SubagentResult(payload: ["summary": "unexpected"])
            }
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: SubagentScope(
                sessionId: UUID().uuidString,
                toolCallId: "child-call",
                agentId: UUID()
            )
        ) else {
            Issue.record("Expected the ordinary child to prepare")
            return
        }

        let envelope = await SubagentSession.runPrepared(
            prepared,
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(recorder.admissions.count == 1)
        #expect(recorder.terminals.isEmpty)
        #expect(bodyRan.value.runId == nil)
    }

    @Test("ordinary child surfaces a durable terminal write failure")
    func rejectedDurableChildTerminalCannotReportSuccess() async {
        let recorder = RecordingSubagentRunLifecycleRecorder(
            rejectsTerminal: true
        )
        let bodyRan = RunBindingBox()
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "child-terminal-refusal",
            agentId: UUID()
        )
        let kind = ScriptedKind(
            body: { _, _, _, _ in
                bodyRan.capture()
                return SubagentResult(payload: ["summary": "work settled"])
            }
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the ordinary child to prepare")
            return
        }

        let envelope = await SubagentSession.runPrepared(
            prepared,
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(decode(envelope)["run_id"] as? String == scope.runId.uuidString)
        #expect(decode(envelope)["terminal_write_failed"] as? Bool == true)
        #expect(recorder.admissions.count == 1)
        #expect(recorder.terminals.isEmpty)
        #expect(bodyRan.value.runId == scope.runId)
    }

    @Test("stop during durable admission settles without starting the child")
    func stopDuringDurableAdmissionNeverExecutes() async {
        let interrupt = InterruptToken()
        let recorder = RecordingSubagentRunLifecycleRecorder(
            interruptOnAdmission: interrupt
        )
        let bodyRan = RunBindingBox()
        let kind = ScriptedKind(
            resolve: { _ in
                ResolvedModel(name: "remote-child", isLocal: false)
            },
            body: { _, _, _, _ in
                bodyRan.capture()
                return SubagentResult(payload: ["summary": "unexpected"])
            }
        )
        let scope = SubagentScope(
            sessionId: UUID().uuidString,
            toolCallId: "stop-during-admission",
            agentId: UUID()
        )
        guard case .ready(let prepared) = await SubagentSession.prepare(
            kind,
            tool: "scripted",
            scope: scope
        ) else {
            Issue.record("Expected the child to prepare")
            return
        }
        let feed = SubagentFeed(
            toolCallId: scope.toolCallId,
            kindId: kind.capability.id,
            title: kind.feedTitle,
            agentId: scope.agentId,
            parentSessionId: scope.sessionId
        )

        let envelope = await SubagentSession.runPrepared(
            prepared,
            presentation: SubagentRunPresentation(
                feed: feed,
                interrupt: interrupt,
                registerWithUI: false
            ),
            runLifecycleRecorder: recorder
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(recorder.admissions.count == 1)
        #expect(recorder.terminals.count == 1)
        #expect(recorder.terminals.first?.runId == scope.runId)
        #expect(recorder.terminals.first?.status == .cancelled)
        #expect(bodyRan.value.runId == nil)
    }

    @Test("the unified recursion guard refuses a nested subagent of any kind")
    func recursionGuard() async {
        // Inside the running kind, a second SubagentSession.run must be refused.
        let inner = ScriptedKind(id: "inner")
        let nestedEnvelopeBox = NestedBox()
        let outer = ScriptedKind(
            id: "outer",
            body: { _, _, _, _ in
                let nested = await SubagentSession.run(inner, tool: "inner")
                nestedEnvelopeBox.value = nested
                return SubagentResult(payload: ["kind": "outer", "summary": "ok"])
            }
        )
        let envelope = await SubagentSession.run(outer, tool: "outer")
        #expect(ToolEnvelope.isSuccess(envelope))
        let nested = nestedEnvelopeBox.value ?? ""
        #expect(ToolEnvelope.isError(nested))
        #expect(decode(nested)["kind"] as? String == "rejected")
        #expect(ToolEnvelope.failureMessage(nested).contains("running subagent"))
    }

    @Test("admitted delegated failures preserve kind and durable run identity")
    func admittedDelegatedFailureCorrelation() {
        let runId = UUID()
        let envelope = SubagentSession.envelope(
            for: DurableSubagentError(
                runId: runId,
                underlying: .userDenied("delegated child stopped")
            ),
            tool: "spawn_batch"
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(decode(envelope)["kind"] as? String == "user_denied")
        #expect(decode(envelope)["run_id"] as? String == runId.uuidString)
    }

    @Test("policy denial maps to a rejected envelope")
    func policyDenied() async {
        let kind = ScriptedKind(decide: { _, _ in .denied("nope") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(ToolEnvelope.isError(envelope))
        #expect(decode(envelope)["kind"] as? String == "rejected")
    }

    @Test("user refusal maps to a user_denied envelope")
    func userDenied() async {
        let kind = ScriptedKind(decide: { _, _ in .userDenied("declined") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(decode(envelope)["kind"] as? String == "user_denied")
    }

    @Test("cancellation without an explicit user interrupt remains an execution error")
    func taskCancellationIsNotReportedAsUserStop() async {
        let kind = ScriptedKind(
            body: { _, _, _, _ in
                throw CancellationError()
            }
        )
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(decode(envelope)["kind"] as? String == "execution_error")
    }

    @Test("a thrown SubagentError maps to its canonical failure kind (reject-before-evict)")
    func resolveFailureBeforeRun() async {
        let kind = ScriptedKind(resolve: { _ in throw SubagentError.unavailable("no model") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(decode(envelope)["kind"] as? String == "unavailable")
    }

    @Test("the handoff middleware wraps the run for needsHandoff kinds")
    func handoffWraps() async {
        let kind = ScriptedKind(needsHandoff: true)
        let handoff = RecordingHandoff()
        _ = await SubagentSession.run(kind, tool: "scripted", handoff: handoff)
        #expect(handoff.wrapped)
    }

    @Test("the live feed is registered during the run and dropped after")
    func feedLifecycle() async {
        let observedBox = NestedBox()
        let kind = ScriptedKind(
            body: { scope, _, feed, _ in
                // The feed must be discoverable by tool-call id while running.
                let live = SubagentFeedRegistry.shared.feed(for: scope.toolCallId)
                observedBox.value = (live != nil) ? "live" : "missing"
                feed.emitProgress("step", fraction: 0.5)
                return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
            })
        _ = await SubagentSession.run(kind, tool: "scripted")
        #expect(observedBox.value == "live")
    }

    @Test("residency phase timings derive from the feed timeline (handoff legs only)")
    func residencyPhaseTimingDerivation() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func event(
            _ title: String,
            at offset: TimeInterval,
            kind: SubagentActivityEvent.Kind = .phase
        ) -> SubagentActivityEvent {
            SubagentActivityEvent(
                timestamp: t0.addingTimeInterval(offset),
                kind: kind,
                title: title
            )
        }
        let events = [
            event("waiting_for_chat_idle", at: 0),
            event("unloading_chat_models", at: 1.5),
            event("running", at: 4.5),
            event("generating", at: 5.0, kind: .progress),
            event("restoring_chat_models", at: 20.0),
        ]
        let timings = SubagentSession.residencyPhaseTimings(
            events: events,
            endedAt: t0.addingTimeInterval(28.0)
        )
        #expect(
            timings.map(\.phase) == [
                "waiting_for_chat_idle", "unloading_chat_models", "restoring_chat_models",
            ]
        )
        #expect(abs(timings[0].seconds - 1.5) < 0.001)
        #expect(abs(timings[1].seconds - 3.0) < 0.001)
        // The final restore leg runs until the run's end timestamp.
        #expect(abs(timings[2].seconds - 8.0) < 0.001)
        // Kind-specific phases ("running") and progress rows are not timed.
        #expect(!timings.contains { $0.phase == "running" })
    }

    @Test("a handoff-wrapped run reports residency phases in its payload")
    func residencyPayloadFromScriptedHandoff() async {
        let kind = ScriptedKind(needsHandoff: true)
        // A handoff that emits the real phase titles around the body.
        let handoff = PhaseEmittingHandoff()
        let envelope = await SubagentSession.run(kind, tool: "scripted", handoff: handoff)
        #expect(ToolEnvelope.isSuccess(envelope))
        let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        let residency = payload?["residency"] as? [String: Any]
        let phases = residency?["phases"] as? [String: Any]
        #expect(phases?.keys.contains("waiting_for_chat_idle") == true)
        #expect(phases?.keys.contains("unloading_chat_models") == true)
        #expect(phases?.keys.contains("restoring_chat_models") == true)
        let order = residency?["phase_order"] as? [String]
        // A parallel test (or a real concurrent caller) may legitimately hold
        // the process-wide local admission slot first. That telemetry belongs
        // before the handoff phases; it must not make this handoff-order check
        // depend on whether another local run happened to overlap.
        if let waitingIndex = order?.firstIndex(of: "waiting for local GPU") {
            #expect(waitingIndex == 0)
        }
        let handoffOrder = order?.filter {
            $0 == "waiting_for_chat_idle"
                || $0 == "unloading_chat_models"
                || $0 == "restoring_chat_models"
        }
        #expect(
            handoffOrder == [
                "waiting_for_chat_idle", "unloading_chat_models", "restoring_chat_models",
            ]
        )
    }
}

/// Handoff that emits the production phase titles around the body, so the
/// session's payload derivation sees a realistic timeline without ModelRuntime.
private struct PhaseEmittingHandoff: SubagentHandoff {
    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        feed.emitPhase("waiting_for_chat_idle", detail: nil)
        feed.emitPhase("unloading_chat_models", detail: "local-a")
        let result = try await body()
        feed.emitPhase("restoring_chat_models", detail: "local-a")
        return result
    }
}

/// Tiny reference box so escaping `@Sendable` closures can hand a value back.
private final class NestedBox: @unchecked Sendable {
    var value: String?
}
