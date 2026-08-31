//
//  DispatchRunIdentityTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Dispatch durable run identity")
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
            parentToolCallId: "call-42"
        )
        let handle = DispatchHandle(id: request.id, runId: request.runId, request: request)

        #expect(handle.runId == request.runId)
        #expect(request.parentRunId == parentRunId)
        #expect(request.rootRunId == rootRunId)
        #expect(request.parentSessionId == parentSessionId)
        #expect(request.parentToolCallId == "call-42")
        #expect(request.runId != parentRunId)
        #expect(request.runId != rootRunId)
    }
}
