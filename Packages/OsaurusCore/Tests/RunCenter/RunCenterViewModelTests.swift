//
//  RunCenterViewModelTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Run Center view model")
@MainActor
struct RunCenterViewModelTests {
    @Test func loadsBoardSelectsDetailAndReturnsToBoard() async throws {
        let run = makeRun(title: "Operator run")
        let events = [event(run, 1, .started)]
        let boardFacts = RunCenterBoardFacts(
            runs: [run],
            eventsByRunId: [run.id: events]
        )
        let detailFacts = RunCenterDetailFacts(
            run: run,
            tree: [run],
            eventsByRunId: [run.id: events]
        )
        let repository = RunCenterReadRepository(
            loadBoardFacts: { boardFacts },
            loadDetailFacts: { id in id == run.id ? detailFacts : nil }
        )
        let viewModel = RunCenterViewModel(repository: repository)

        viewModel.refresh()
        try await waitUntil("board load") { viewModel.board != nil }
        #expect(viewModel.board?.cards.map(\.id) == [run.id])
        #expect(viewModel.isLoading == false)

        viewModel.select(run.id)
        try await waitUntil("detail load") { viewModel.detail != nil }
        #expect(viewModel.selectedRunId == run.id)
        #expect(viewModel.detail?.card.id == run.id)
        #expect(viewModel.isDetailLoading == false)

        viewModel.showBoard()
        #expect(viewModel.selectedRunId == nil)
        #expect(viewModel.detail == nil)
        #expect(viewModel.errorMessage == nil)
        viewModel.stop()
    }

    @Test func reportsBoardAndDetailLoadFailuresWithoutInventingData() async throws {
        let run = makeRun(title: "Existing run")
        let events = [event(run, 1, .started)]
        let failingBoard = RunCenterReadRepository(
            loadBoardFacts: { throw FixtureFailure.board },
            loadDetailFacts: { _ in nil }
        )
        let boardViewModel = RunCenterViewModel(repository: failingBoard)

        boardViewModel.refresh()
        try await waitUntil("board error") { boardViewModel.errorMessage != nil }
        #expect(boardViewModel.board == nil)
        #expect(boardViewModel.errorMessage == "Fixture board failure")

        let missingDetail = RunCenterReadRepository(
            loadBoardFacts: {
                RunCenterBoardFacts(runs: [run], eventsByRunId: [run.id: events])
            },
            loadDetailFacts: { _ in nil }
        )
        let detailViewModel = RunCenterViewModel(repository: missingDetail)
        detailViewModel.refresh()
        try await waitUntil("board before missing detail") { detailViewModel.board != nil }
        detailViewModel.select(run.id)
        try await waitUntil("detail error") { detailViewModel.errorMessage != nil }
        #expect(detailViewModel.detail == nil)
        #expect(detailViewModel.errorMessage?.contains(run.id.uuidString) == true)

        boardViewModel.stop()
        detailViewModel.stop()
    }

    @Test func staleRefreshCannotOverwriteTheNewestBoard() async throws {
        let older = makeRun(title: "Older snapshot")
        let newer = makeRun(title: "Newer snapshot")
        let gate = RunCenterViewModelLoadGate(
            first: RunCenterBoardFacts(
                runs: [older],
                eventsByRunId: [older.id: [event(older, 1, .started)]]
            ),
            second: RunCenterBoardFacts(
                runs: [newer],
                eventsByRunId: [newer.id: [event(newer, 1, .started)]]
            )
        )
        let repository = RunCenterReadRepository(
            loadBoardFacts: { gate.load() },
            loadDetailFacts: { _ in nil }
        )
        let viewModel = RunCenterViewModel(repository: repository)

        viewModel.refresh()
        try await waitUntil("first refresh entry") { gate.firstEntered }
        viewModel.refresh()
        try await waitUntil("newest refresh") {
            viewModel.board?.cards.map(\.id) == [newer.id]
        }
        gate.releaseFirst()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(viewModel.board?.cards.map(\.id) == [newer.id])
        #expect(viewModel.errorMessage == nil)
        viewModel.stop()
    }

    @Test func staleConversationLookupCannotActOnANewSelection() async throws {
        let first = makeRun(title: "First run", sessionId: UUID())
        let second = makeRun(title: "Second run", sessionId: UUID())
        let firstEvents = [event(first, 1, .started)]
        let secondEvents = [event(second, 1, .started)]
        let conversationGate = RunCenterConversationLoadGate(
            firstSession: makeSession(for: first),
            secondSession: makeSession(for: second)
        )
        let repository = RunCenterReadRepository(
            loadBoardFacts: {
                RunCenterBoardFacts(
                    runs: [first, second],
                    eventsByRunId: [
                        first.id: firstEvents,
                        second.id: secondEvents,
                    ]
                )
            },
            loadDetailFacts: { id in
                if id == first.id {
                    return RunCenterDetailFacts(
                        run: first,
                        tree: [first],
                        eventsByRunId: [first.id: firstEvents]
                    )
                }
                if id == second.id {
                    return RunCenterDetailFacts(
                        run: second,
                        tree: [second],
                        eventsByRunId: [second.id: secondEvents]
                    )
                }
                return nil
            },
            loadConversation: { sessionId in
                conversationGate.load(sessionId: sessionId)
            }
        )
        let viewModel = RunCenterViewModel(repository: repository)

        viewModel.refresh()
        try await waitUntil("board before conversation race") { viewModel.board != nil }
        viewModel.select(first.id)
        try await waitUntil("first detail") { viewModel.detail?.card.id == first.id }
        viewModel.openConversation()
        try await waitUntil("conversation lookup entry") {
            conversationGate.staleLookupEntered
        }

        viewModel.select(second.id)
        try await waitUntil("second detail") { viewModel.detail?.card.id == second.id }
        conversationGate.releaseStaleLookup()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(viewModel.selectedRunId == second.id)
        #expect(viewModel.conversationErrorMessage == nil)
        viewModel.stop()
    }

    private func makeRun(title: String, sessionId: UUID? = nil) -> AgentRunRecord {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return AgentRunRecord(
            id: UUID(),
            agentId: UUID(),
            triggerKind: .user,
            instructions: title,
            startedAt: startedAt,
            status: .running,
            sessionId: sessionId,
            rootRunId: nil,
            title: title,
            updatedAt: startedAt,
            eventBaselineState: .created
        )
    }

    private func makeSession(for run: AgentRunRecord) -> ChatSessionData {
        ChatSessionData(
            id: run.sessionId!,
            title: run.title ?? "Fixture",
            turns: [],
            agentId: run.agentId
        )
    }

    private func event(
        _ run: AgentRunRecord,
        _ sequence: Int,
        _ kind: RunCenterEventKind
    ) -> RunCenterEvent {
        RunCenterEvent(
            runId: run.id,
            sequence: sequence,
            kind: kind,
            occurredAt: run.startedAt
        )
    }

    private func waitUntil(
        _ label: String,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for \(label)")
        throw FixtureFailure.timeout
    }
}

private enum FixtureFailure: LocalizedError {
    case board
    case timeout

    var errorDescription: String? {
        switch self {
        case .board: "Fixture board failure"
        case .timeout: "Fixture timeout"
        }
    }
}

private final class RunCenterViewModelLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let first: RunCenterBoardFacts
    private let second: RunCenterBoardFacts
    private var callCount = 0
    private var entered = false
    private var released = false

    init(first: RunCenterBoardFacts, second: RunCenterBoardFacts) {
        self.first = first
        self.second = second
    }

    var firstEntered: Bool {
        lock.withLock { entered }
    }

    func releaseFirst() {
        lock.withLock { released = true }
    }

    func load() -> RunCenterBoardFacts {
        let call = lock.withLock { () -> Int in
            callCount += 1
            if callCount == 1 { entered = true }
            return callCount
        }
        guard call == 1 else { return second }
        while !lock.withLock({ released }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return first
    }
}

private final class RunCenterConversationLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstSession: ChatSessionData
    private let secondSession: ChatSessionData
    private var firstDetailLoaded = false
    private var entered = false
    private var released = false

    init(firstSession: ChatSessionData, secondSession: ChatSessionData) {
        self.firstSession = firstSession
        self.secondSession = secondSession
    }

    var staleLookupEntered: Bool {
        lock.withLock { entered }
    }

    func releaseStaleLookup() {
        lock.withLock { released = true }
    }

    func load(sessionId: UUID) -> ChatSessionData? {
        if sessionId == secondSession.id { return secondSession }
        guard sessionId == firstSession.id else { return nil }
        let shouldBlock = lock.withLock { () -> Bool in
            if !firstDetailLoaded {
                firstDetailLoaded = true
                return false
            }
            entered = true
            return true
        }
        guard shouldBlock else { return firstSession }
        while !lock.withLock({ released }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return nil
    }
}
