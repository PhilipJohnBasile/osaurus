//
//  SchedulerRunLedgerTests.swift
//  osaurusTests
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite("Scheduler durable run ledger")
struct SchedulerRunLedgerTests {
    @Test func legacyEncodedRunRecordDecodesWithoutNewMetadata() throws {
        let json =
            """
            {
              "id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
              "agentId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
              "triggerKind":"user",
              "instructions":"Legacy",
              "startedAt":100,
              "status":"running"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(AgentRunRecord.self, from: Data(json.utf8))

        #expect(record.sessionId == nil)
        #expect(record.rootRunId == nil)
        #expect(record.updatedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func admissionDurablyCapturesQueuePromotionAndExactIdentity() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        let sessionId = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002")!
        let admittedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try database.recordRunAdmission(
            RunLifecycleAdmission(
                runId: runId,
                agentId: UUID(),
                triggerKind: .recurringSchedule,
                triggerPayload: #"{"source":"schedule"}"#,
                instructions: "Queued work",
                admittedAt: admittedAt,
                startsImmediately: false,
                sessionId: sessionId,
                title: "Queue me"
            )
        )

        var record = try #require(database.allRuns().first { $0.id == runId })
        #expect(record.id == runId)
        #expect(record.sessionId == sessionId)
        #expect(record.rootRunId == runId)
        #expect(record.status == .queued)
        #expect(record.startedAt == admittedAt)
        #expect(try database.events(runId: runId).map(\.kind) == [.created, .queued])

        _ = try database.appendRunEvent(
            runId: runId,
            kind: .started,
            occurredAt: admittedAt.addingTimeInterval(5)
        )
        record = try #require(database.allRuns().first { $0.id == runId })
        #expect(record.status == .running)

        try database.recordRunEnd(
            runId: runId,
            status: .success,
            endedAt: admittedAt.addingTimeInterval(10)
        )
        #expect(
            try database.events(runId: runId).map(\.kind)
                == [.created, .queued, .started, .completed]
        )
    }

    @Test func queuedAdmissionCanCancelWithoutEverStarting() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = UUID()
        try database.recordRunAdmission(
            RunLifecycleAdmission(
                runId: runId,
                agentId: UUID(),
                triggerKind: .watcher,
                instructions: "Cancel before promotion",
                startsImmediately: false
            )
        )
        try database.recordRunEnd(runId: runId, status: .cancelled)

        let record = try #require(database.allRuns().first { $0.id == runId })
        #expect(record.status == .cancelled)
        #expect(
            try database.events(runId: runId).map(\.kind)
                == [.created, .queued, .cancelled]
        )
    }

    @Test func launchRecoveryAtomicallyInterruptsEveryOrphanAndIsIdempotent() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let queuedRunId = UUID()
        let runningRunId = UUID()
        let waitingRunId = UUID()
        let completedRunId = UUID()
        try database.recordRunAdmission(
            RunLifecycleAdmission(
                runId: queuedRunId,
                agentId: agentId,
                triggerKind: .watcher,
                instructions: "Queued before restart",
                startsImmediately: false
            )
        )
        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Running before restart",
            id: runningRunId
        )
        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Waiting before restart",
            id: waitingRunId
        )
        _ = try database.appendRunEvent(runId: waitingRunId, kind: .waitingForInput)
        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Already complete",
            id: completedRunId
        )
        try database.recordRunEnd(runId: completedRunId, status: .success)

        let interruptedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let reason = "Recovered after test restart."
        let recovered = try database.recoverOrphanedRunsAfterLaunch(
            interruptedAt: interruptedAt,
            reason: reason
        )

        #expect(Set(recovered) == Set([queuedRunId, runningRunId, waitingRunId]))
        for runId in recovered {
            let record = try #require(database.allRuns().first { $0.id == runId })
            let terminalEvent = try #require(database.events(runId: runId).last)
            #expect(record.status == .interrupted)
            #expect(record.endedAt == interruptedAt)
            #expect(record.error == reason)
            #expect(terminalEvent.kind == .interrupted)
            #expect(terminalEvent.metadata["recovery"] == "application_launch")
        }
        #expect(
            try database.allRuns().first { $0.id == completedRunId }?.status == .success
        )

        let eventCounts = try Dictionary(
            uniqueKeysWithValues: recovered.map { ($0, try database.events(runId: $0).count) }
        )
        #expect(try database.recoverOrphanedRunsAfterLaunch().isEmpty)
        for runId in recovered {
            #expect(try database.events(runId: runId).count == eventCounts[runId])
        }
    }

    @Test func recorderNeverRecoversWorkAdmittedByCurrentProcess() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let priorRunId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Prior process"
        )
        let recorder = SchedulerRunLifecycleRecorder(database: database)
        #expect(try recorder.recoverOrphanedRunsAfterLaunch() == [priorRunId])

        let currentRunId = UUID()
        try recorder.admit(
            RunLifecycleAdmission(
                runId: currentRunId,
                agentId: UUID(),
                triggerKind: .watcher,
                instructions: "Current process",
                startsImmediately: true
            )
        )

        #expect(try recorder.recoverOrphanedRunsAfterLaunch().isEmpty)
        let current = try #require(database.allRuns().first { $0.id == currentRunId })
        #expect(current.status == .running)
        #expect(current.endedAt == nil)
    }

    @Test func launchRecoveryRollsBackEveryRunWhenOneEventStreamIsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let healthyRunId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let corruptRunId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Healthy orphan",
            startedAt: startedAt,
            id: healthyRunId
        )
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Corrupt orphan",
            startedAt: startedAt,
            id: corruptRunId
        )
        database.close()

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            """
                INSERT INTO run_events
                    (id, run_id, sequence, event_type, metadata, occurred_at)
                VALUES
                    ('33333333-3333-3333-3333-333333333333',
                     '\(corruptRunId.uuidString)', 2, 'future_event', '{}', 101);
            """,
            on: connection
        )
        sqlite3_close(connection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(throws: SchedulerDatabaseError.self) {
            try database.recoverOrphanedRunsAfterLaunch(
                interruptedAt: startedAt.addingTimeInterval(10)
            )
        }

        let records = try database.allRuns()
        for runId in [healthyRunId, corruptRunId] {
            let record = try #require(records.first { $0.id == runId })
            #expect(record.status == .running)
            #expect(record.endedAt == nil)
        }
        #expect(try database.events(runId: healthyRunId).map(\.kind) == [.started])
    }

    @Test func childAdmissionUsesParentRootAndLinksParentAtomically() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let parentRunId = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Parent"
        )
        let childRunId = UUID()
        let resolvedRootRunId = try database.recordRunAdmission(
            RunLifecycleAdmission(
                runId: childRunId,
                agentId: agentId,
                triggerKind: .user,
                instructions: "Child",
                startsImmediately: true,
                parentRunId: parentRunId,
                title: "Delegated child"
            )
        )

        let child = try #require(database.allRuns().first { $0.id == childRunId })
        #expect(resolvedRootRunId == parentRunId)
        #expect(child.parentRunId == parentRunId)
        #expect(child.rootRunId == parentRunId)
        #expect(try database.events(runId: childRunId).map(\.kind) == [.created, .started])

        let parentEvents = try database.events(runId: parentRunId)
        #expect(parentEvents.map(\.kind) == [.started, .childLinked])
        #expect(parentEvents.last?.metadata["child_run_id"] == childRunId.uuidString)
    }

    @Test func duplicateChildAdmissionRollsBackWithoutDuplicateParentLink() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let parentRunId = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Parent"
        )
        let childRunId = UUID()
        let admission = RunLifecycleAdmission(
            runId: childRunId,
            agentId: agentId,
            triggerKind: .user,
            instructions: "Child",
            startsImmediately: true,
            parentRunId: parentRunId,
            rootRunId: parentRunId,
            title: "Delegated child"
        )

        try database.recordRunAdmission(admission)
        #expect(throws: SchedulerDatabaseError.self) {
            try database.recordRunAdmission(admission)
        }

        let duplicateChildRows = try database.allRuns().filter { $0.id == childRunId }
        #expect(duplicateChildRows.count == 1)
        #expect(try database.events(runId: childRunId).map(\.kind) == [.created, .started])
        let parentEvents = try database.events(runId: parentRunId)
        #expect(parentEvents.filter { $0.kind == .childLinked }.count == 1)
        #expect(parentEvents.last?.metadata["child_run_id"] == childRunId.uuidString)
    }

    @Test func metadataEventsAndTerminalStateRoundTrip() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let projectId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let parentRunId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let rootRunId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(12)

        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Root",
            startedAt: startedAt.addingTimeInterval(-2),
            id: rootRunId
        )
        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Parent",
            startedAt: startedAt.addingTimeInterval(-1),
            id: parentRunId,
            parentRunId: rootRunId,
            rootRunId: rootRunId
        )
        try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Build Run Center",
            startedAt: startedAt,
            id: runId,
            sessionId: sessionId,
            projectId: projectId,
            parentRunId: parentRunId,
            rootRunId: rootRunId,
            title: "Run Center foundation",
            modelId: "local/model"
        )
        let waiting = try database.appendRunEvent(
            runId: runId,
            kind: .waitingForInput,
            occurredAt: startedAt.addingTimeInterval(4),
            message: "Choose a base branch",
            metadata: ["authorization": "Bearer should-not-persist", "kind": "branch"]
        )
        let resumed = try database.appendRunEvent(
            runId: runId,
            kind: .resumed,
            occurredAt: startedAt.addingTimeInterval(6)
        )
        try database.recordRunEnd(
            runId: runId,
            status: .success,
            endedAt: endedAt,
            tokensIn: 100,
            tokensOut: 50,
            costUSD: 0.25
        )

        let record = try #require(database.runs(agentId: agentId).first)
        let events = try database.events(runId: runId)

        #expect(record.id == runId)
        #expect(record.sessionId == sessionId)
        #expect(record.projectId == projectId)
        #expect(record.parentRunId == parentRunId)
        #expect(record.rootRunId == rootRunId)
        #expect(record.title == "Run Center foundation")
        #expect(record.modelId == "local/model")
        #expect(record.eventBaselineState == .created)
        #expect(record.status == .success)
        #expect(record.updatedAt == endedAt)
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        #expect(events.map(\.kind) == [.started, .waitingForInput, .resumed, .completed])
        #expect(waiting.metadata["authorization"] == "<redacted>")
        #expect(waiting.metadata["kind"] == "branch")
        #expect(resumed.sequence == 3)

        let snapshot = try RunCenterProjector.project(
            runId: runId,
            legacyStatus: record.status,
            baselineState: record.eventBaselineState,
            events: events,
            proofContract: .none
        )
        #expect(snapshot.executionState == .completed)
        #expect(snapshot.lane == .done)
    }

    @Test func terminalCloseIsIdempotentButConflictingReceiptIsRejected() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Close once"
        )
        let endedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try database.recordRunEnd(
            runId: runId,
            status: .success,
            endedAt: endedAt,
            tokensIn: 10
        )
        try database.recordRunEnd(
            runId: runId,
            status: .success,
            endedAt: endedAt,
            tokensIn: 10
        )

        #expect(try database.events(runId: runId).map(\.kind) == [.started, .completed])
        #expect(throws: SchedulerDatabaseError.self) {
            try database.recordRunEnd(
                runId: runId,
                status: .success,
                endedAt: endedAt,
                tokensIn: 11
            )
        }
        #expect(try database.events(runId: runId).map(\.kind) == [.started, .completed])
    }

    @Test func activeLifecycleEventAfterTerminalIsRejectedButEvidenceIsAllowed() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Absorbing terminal"
        )
        try database.recordRunEnd(runId: runId, status: .success)

        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .resumed)
        }
        _ = try database.appendRunEvent(runId: runId, kind: .evidenceAttached)
        #expect(
            try database.events(runId: runId).map(\.kind)
                == [.started, .completed, .evidenceAttached]
        )
    }

    @Test func eventMessagesAndMetadataRedactSecretShapedValues() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Redact"
        )
        let event = try database.appendRunEvent(
            runId: runId,
            kind: .progress,
            message: "Bearer secret-token",
            metadata: ["api_key": "sk-not-real", "phase": "build"]
        )

        #expect(event.message == "<redacted>")
        #expect(event.metadata["api_key"] == "<redacted>")
        #expect(event.metadata["phase"] == "build")
        #expect(try database.events(runId: runId).last?.message == "<redacted>")
    }

    @Test func durableApprovalHeadRequiresResolutionBeforeResume() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Approve"
        )
        _ = try database.appendRunEvent(runId: runId, kind: .approvalRequested)
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .resumed)
        }
        _ = try database.appendRunEvent(runId: runId, kind: .approvalResolved)
        _ = try database.appendRunEvent(runId: runId, kind: .resumed)

        let events = try database.events(runId: runId)
        #expect(
            events.map(\.kind)
                == [.started, .approvalRequested, .approvalResolved, .resumed]
        )
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            events: events,
            proofContract: .none
        )
        #expect(snapshot.executionState == .running)
        #expect(!snapshot.approvalPending)
    }

    @Test func rootRunDefaultsToSelfAndAllRunsCrossesAgents() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let firstAgent = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let secondAgent = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let firstRun = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let secondRun = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try database.recordRunStart(
            agentId: firstAgent,
            triggerKind: .user,
            instructions: "First",
            startedAt: start,
            id: firstRun
        )
        try database.recordRunStart(
            agentId: secondAgent,
            triggerKind: .watcher,
            instructions: "Second",
            startedAt: start.addingTimeInterval(1),
            id: secondRun
        )

        let all = try database.allRuns()

        #expect(all.map(\.id) == [secondRun, firstRun])
        #expect(all.first(where: { $0.id == firstRun })?.rootRunId == firstRun)
        #expect(all.first(where: { $0.id == secondRun })?.rootRunId == secondRun)
    }

    @Test func crossAgentPaginationDoesNotSkipSameSecondRuns() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let agentId = UUID()
        let runIds = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        ]
        for runId in runIds {
            try database.recordRunStart(
                agentId: agentId,
                triggerKind: .user,
                instructions: runId.uuidString,
                startedAt: startedAt,
                id: runId
            )
        }

        let firstPage = try database.allRuns(limit: 2)
        let secondPage = try database.allRuns(
            limit: 2,
            before: RunCenterRunCursor(after: try #require(firstPage.last))
        )

        #expect(firstPage.map(\.id) == [runIds[2], runIds[1]])
        #expect(secondPage.map(\.id) == [runIds[0]])

        let firstAgentPage = try database.runs(agentId: agentId, limit: 2)
        let secondAgentPage = try database.runs(
            agentId: agentId,
            limit: 2,
            before: RunCenterRunCursor(after: try #require(firstAgentPage.last))
        )
        #expect(firstAgentPage.map(\.id) == [runIds[2], runIds[1]])
        #expect(secondAgentPage.map(\.id) == [runIds[0]])
    }

    @Test func deletingAgentRemovesOnlyItsRunEvents() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let deletedAgent = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let retainedAgent = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let deletedRun = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let retainedRun = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!

        try database.recordRunStart(
            agentId: deletedAgent,
            triggerKind: .user,
            instructions: "Delete",
            id: deletedRun
        )
        try database.recordRunStart(
            agentId: retainedAgent,
            triggerKind: .user,
            instructions: "Keep",
            id: retainedRun
        )
        _ = try database.appendRunEvent(runId: deletedRun, kind: .progress)
        _ = try database.appendRunEvent(runId: retainedRun, kind: .progress)

        try database.deleteAllForAgent(deletedAgent)

        #expect(try database.events(runId: deletedRun).isEmpty)
        #expect(try database.events(runId: retainedRun).count == 2)
        #expect(try database.allRuns().map(\.id) == [retainedRun])
    }

    @Test func nonterminalStatusCannotCloseRun() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Still running"
        )

        #expect(throws: SchedulerDatabaseError.self) {
            try database.recordRunEnd(runId: runId, status: .running)
        }
        #expect(try database.events(runId: runId).map(\.kind) == [.started])
    }

    @Test func delayedEventCannotMoveUpdatedAtBackward() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Monotonic update",
            startedAt: startedAt
        )
        _ = try database.appendRunEvent(
            runId: runId,
            kind: .progress,
            occurredAt: startedAt.addingTimeInterval(-10)
        )

        let record = try #require(database.allRuns().first)
        #expect(record.updatedAt == startedAt)
    }

    @Test func concurrentHandlesAllocateUniqueContiguousSequences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path

        let first = SchedulerDatabase()
        let second = SchedulerDatabase()
        try first.openForTesting(path: path)
        try second.openForTesting(path: path)
        defer {
            first.close()
            second.close()
        }

        let runId = try first.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Concurrent events"
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let database = index.isMultiple(of: 2) ? first : second
                    _ = try database.appendRunEvent(runId: runId, kind: .progress)
                }
            }
            try await group.waitForAll()
        }

        let events = try first.events(runId: runId)
        #expect(events.map(\.sequence) == Array(1...21))
    }

    @Test func partiallyAppliedV1DatabaseMigratesWithoutLosingRun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let runId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let runningRunId = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let approvalRunId = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let waitingRunId = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let agentId = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let sessionId = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            """
                CREATE TABLE agent_next_run (
                    agent_id TEXT PRIMARY KEY,
                    scheduled_at INTEGER NOT NULL,
                    instructions TEXT NOT NULL,
                    context_views TEXT NOT NULL DEFAULT '[]',
                    priority TEXT NOT NULL DEFAULT 'normal',
                    on_miss TEXT NOT NULL DEFAULT 'skip',
                    scheduled_by TEXT NOT NULL,
                    scheduled_at_wall INTEGER NOT NULL
                );
                CREATE TABLE agent_runs (
                    id TEXT PRIMARY KEY,
                    agent_id TEXT NOT NULL,
                    trigger_kind TEXT NOT NULL,
                    trigger_payload TEXT,
                    instructions TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER,
                    status TEXT NOT NULL,
                    tokens_in INTEGER,
                    tokens_out INTEGER,
                    cost_usd REAL,
                    error TEXT,
                    session_id TEXT
                );
                CREATE TABLE agent_pause (
                    agent_id TEXT PRIMARY KEY,
                    paused_until INTEGER NOT NULL,
                    reason TEXT
                );
                INSERT INTO agent_runs
                    (id, agent_id, trigger_kind, instructions, started_at,
                     ended_at, status, session_id)
                VALUES
                    ('\(runId.uuidString)', '\(agentId.uuidString)', 'user',
                     'Legacy run', 100, 112, 'success', '\(sessionId.uuidString)');
                INSERT INTO agent_runs
                    (id, agent_id, trigger_kind, instructions, started_at,
                     status)
                VALUES
                    ('\(runningRunId.uuidString)', '\(agentId.uuidString)', 'user',
                     'Legacy running run', 101, 'running');
                INSERT INTO agent_runs
                    (id, agent_id, trigger_kind, instructions, started_at, status)
                VALUES
                    ('\(approvalRunId.uuidString)', '\(agentId.uuidString)', 'user',
                     'Legacy approval run', 102, 'running');
                INSERT INTO agent_runs
                    (id, agent_id, trigger_kind, instructions, started_at, status)
                VALUES
                    ('\(waitingRunId.uuidString)', '\(agentId.uuidString)', 'user',
                     'Legacy waiting run', 103, 'running');
                PRAGMA user_version = 1;
            """,
            on: connection
        )
        sqlite3_close(connection)

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        defer { database.close() }

        let migrated = try #require(
            database.allRuns().first(where: { $0.id == runId })
        )
        #expect(try database.schemaVersionForTesting() == 2)
        #expect(migrated.id == runId)
        #expect(migrated.sessionId == sessionId)
        #expect(migrated.projectId == nil)
        #expect(migrated.updatedAt == Date(timeIntervalSince1970: 112))
        #expect(try database.events(runId: runId).isEmpty)

        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .started)
        }
        _ = try database.appendRunEvent(runId: runId, kind: .evidenceAttached)
        let afterEvidence = try #require(
            database.allRuns().first(where: { $0.id == runId })
        )
        #expect(afterEvidence.status == .success)
        #expect(afterEvidence.endedAt == Date(timeIntervalSince1970: 112))
        #expect(afterEvidence.eventBaselineState == .completed)
        let snapshot = try RunCenterProjector.project(
            runId: runId,
            legacyStatus: afterEvidence.status,
            baselineState: afterEvidence.eventBaselineState,
            events: try database.events(runId: runId),
            proofContract: .none
        )
        #expect(snapshot.executionState == .completed)

        _ = try database.appendRunEvent(
            runId: runningRunId,
            kind: .evidenceAttached,
            occurredAt: Date(timeIntervalSince1970: 119)
        )
        try database.recordRunEnd(
            runId: runningRunId,
            status: .success,
            endedAt: Date(timeIntervalSince1970: 120)
        )
        let closedMigratedRun = try #require(
            database.allRuns().first(where: { $0.id == runningRunId })
        )
        let closingEvents = try database.events(runId: runningRunId)
        #expect(closedMigratedRun.eventBaselineState == .running)
        #expect(closingEvents.map(\.kind) == [.evidenceAttached, .completed])
        let closedSnapshot = try RunCenterProjector.project(
            runId: runningRunId,
            legacyStatus: closedMigratedRun.status,
            baselineState: closedMigratedRun.eventBaselineState,
            events: closingEvents,
            proofContract: .none
        )
        #expect(closedSnapshot.executionState == .completed)

        _ = try database.appendRunEvent(runId: approvalRunId, kind: .approvalRequested)
        _ = try database.appendRunEvent(runId: approvalRunId, kind: .approvalResolved)
        _ = try database.appendRunEvent(runId: approvalRunId, kind: .resumed)
        try database.recordRunEnd(runId: approvalRunId, status: .success)
        #expect(
            try database.events(runId: approvalRunId).map(\.kind)
                == [.approvalRequested, .approvalResolved, .resumed, .completed]
        )

        _ = try database.appendRunEvent(runId: waitingRunId, kind: .waitingForInput)
        try database.recordRunEnd(runId: waitingRunId, status: .error)
        let waitingEvents = try database.events(runId: waitingRunId)
        let failedRun = try #require(
            database.allRuns().first(where: { $0.id == waitingRunId })
        )
        #expect(failedRun.eventBaselineState == .running)
        #expect(waitingEvents.map(\.kind) == [.waitingForInput, .failed])
        let failedSnapshot = try RunCenterProjector.project(
            runId: waitingRunId,
            legacyStatus: failedRun.status,
            baselineState: failedRun.eventBaselineState,
            events: waitingEvents,
            proofContract: .none
        )
        #expect(failedSnapshot.executionState == .failed)
    }

    @Test func corruptOrUnknownEventFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-corruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let runId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Corrupt me",
            id: runId
        )
        database.close()

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            """
                INSERT INTO run_events
                    (id, run_id, sequence, event_type, metadata, occurred_at)
                VALUES
                    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
                     '\(runId.uuidString)', 2, 'future_event', '{}', 101);
            """,
            on: connection
        )
        sqlite3_close(connection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.events(runId: runId)
        }
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .progress)
        }
    }

    @Test func interiorEventGapBlocksFurtherAppend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let runId = UUID()

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Detect a gap",
            id: runId
        )
        _ = try database.appendRunEvent(runId: runId, kind: .progress)
        _ = try database.appendRunEvent(runId: runId, kind: .progress)
        database.close()

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            "DELETE FROM run_events WHERE run_id = '\(runId.uuidString)' AND sequence = 2",
            on: connection
        )
        sqlite3_close(connection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .progress)
        }
    }

    @Test func alteredFirstLifecycleFactConflictsWithDurableBaseline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let runId = UUID()

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Protect baseline",
            id: runId
        )
        database.close()

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            "UPDATE run_events SET event_type = 'progress' "
                + "WHERE run_id = '\(runId.uuidString)' AND sequence = 1",
            on: connection
        )
        sqlite3_close(connection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.appendRunEvent(runId: runId, kind: .progress)
        }
    }

    @Test func failedMigrationClosesHandleAndSameInstanceCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-open-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            """
                CREATE TABLE agent_runs (
                    id TEXT PRIMARY KEY,
                    agent_id TEXT NOT NULL,
                    trigger_kind TEXT NOT NULL,
                    trigger_payload TEXT,
                    instructions TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER,
                    status TEXT NOT NULL,
                    tokens_in INTEGER,
                    tokens_out INTEGER,
                    cost_usd REAL,
                    error TEXT
                );
                CREATE VIEW run_events AS SELECT 1 AS id;
                PRAGMA user_version = 1;
            """,
            on: connection
        )
        sqlite3_close(connection)

        let database = SchedulerDatabase()
        #expect(throws: SchedulerDatabaseError.self) {
            try database.openForTesting(path: path)
        }
        #expect(!database.isOpen)

        let repairConnection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute("DROP VIEW run_events", on: repairConnection)
        sqlite3_close(repairConnection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(database.isOpen)
        #expect(try database.schemaVersionForTesting() == 2)
    }

    @Test func corruptRunStatusFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-row-corruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path
        let runId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        let database = SchedulerDatabase()
        try database.openForTesting(path: path)
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Corrupt row",
            id: runId
        )
        database.close()

        let connection = try EncryptedSQLiteOpener.open(
            path: path,
            key: nil,
            applyPerfPragmas: false
        )
        try execute(
            "UPDATE agent_runs SET status = 'future_terminal' WHERE id = '\(runId.uuidString)'",
            on: connection
        )
        sqlite3_close(connection)

        try database.openForTesting(path: path)
        defer { database.close() }
        #expect(throws: SchedulerDatabaseError.self) {
            _ = try database.allRuns()
        }
    }

    @Test func childRootIsDerivedFromExistingParent() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let parentRunId = try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Parent"
        )
        let childRunId = UUID()
        try database.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Child",
            id: childRunId,
            parentRunId: parentRunId
        )

        let child = try #require(database.allRuns().first(where: { $0.id == childRunId }))
        #expect(child.parentRunId == parentRunId)
        #expect(child.rootRunId == parentRunId)

        #expect(throws: SchedulerDatabaseError.self) {
            try database.recordRunStart(
                agentId: UUID(),
                triggerKind: .user,
                instructions: "Orphan",
                parentRunId: UUID()
            )
        }
    }

    @Test func deletingAgentWithCrossAgentChildrenIsBlocked() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let parentAgent = UUID()
        let childAgent = UUID()
        let parentRun = try database.recordRunStart(
            agentId: parentAgent,
            triggerKind: .user,
            instructions: "Parent"
        )
        let childRun = try database.recordRunStart(
            agentId: childAgent,
            triggerKind: .user,
            instructions: "Child",
            parentRunId: parentRun
        )

        #expect(throws: SchedulerDatabaseError.self) {
            try database.deleteAllForAgent(parentAgent)
        }
        #expect(try database.allRuns().map(\.id).contains(parentRun))
        #expect(try database.allRuns().map(\.id).contains(childRun))
    }

    @Test func crossHandleDeletionSerializesAgainstExistingChildLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-run-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.sqlite").path

        let first = SchedulerDatabase()
        let second = SchedulerDatabase()
        try first.openForTesting(path: path)
        try second.openForTesting(path: path)
        defer {
            first.close()
            second.close()
        }

        let parentAgent = UUID()
        let parentRun = try first.recordRunStart(
            agentId: parentAgent,
            triggerKind: .user,
            instructions: "Parent"
        )
        let childRun = try second.recordRunStart(
            agentId: UUID(),
            triggerKind: .user,
            instructions: "Child",
            parentRunId: parentRun
        )

        #expect(throws: SchedulerDatabaseError.self) {
            try first.deleteAllForAgent(parentAgent)
        }
        #expect(try second.allRuns().map(\.id).contains(parentRun))
        #expect(try second.allRuns().map(\.id).contains(childRun))
    }

    private func execute(_ sql: String, on connection: OpaquePointer) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw SchedulerDatabaseError.failedToExecute(
                message.map { String(cString: $0) } ?? "unknown fixture error"
            )
        }
    }
}
