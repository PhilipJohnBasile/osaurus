//
//  RunCenterViewModel.swift
//  osaurus
//

import Foundation

@MainActor
final class RunCenterViewModel: ObservableObject {
    @Published private(set) var board: RunCenterBoardReadModel?
    @Published private(set) var selectedRunId: UUID?
    @Published private(set) var detail: RunCenterDetailReadModel?
    @Published private(set) var isLoading = false
    @Published private(set) var isDetailLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var conversationErrorMessage: String?

    private let repository: RunCenterReadRepository
    private let pollingIntervalNanoseconds: UInt64
    private var boardTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var boardGeneration: UInt = 0
    private var detailGeneration: UInt = 0
    private var conversationGeneration: UInt = 0

    init(
        repository: RunCenterReadRepository = RunCenterReadRepository(),
        pollingInterval: TimeInterval = 5
    ) {
        self.repository = repository
        pollingIntervalNanoseconds = UInt64(max(pollingInterval, 0.25) * 1_000_000_000)
    }

    var needsYouCount: Int { board?.needsYou.count ?? 0 }

    func start() {
        refresh()
        guard pollingTask == nil else { return }
        let interval = pollingIntervalNanoseconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        boardTask?.cancel()
        detailTask?.cancel()
        cancelConversationLoad()
    }

    func refresh() {
        boardGeneration &+= 1
        let generation = boardGeneration
        let repository = repository
        boardTask?.cancel()
        if board == nil { isLoading = true }
        errorMessage = nil
        boardTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return BoardLoadOutcome.success(try repository.board())
                } catch {
                    return BoardLoadOutcome.failure(error.localizedDescription)
                }
            }.value
            guard let self, !Task.isCancelled, generation == boardGeneration else { return }
            isLoading = false
            switch outcome {
            case .success(let model):
                board = model
                errorMessage = nil
                if let selectedRunId {
                    loadDetail(runId: selectedRunId)
                }
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    func select(_ runId: UUID) {
        cancelConversationLoad()
        selectedRunId = runId
        detail = nil
        errorMessage = nil
        loadDetail(runId: runId)
    }

    func showBoard() {
        cancelConversationLoad()
        detailTask?.cancel()
        detailGeneration &+= 1
        selectedRunId = nil
        detail = nil
        isDetailLoading = false
        errorMessage = nil
        conversationErrorMessage = nil
    }

    func openConversation() {
        cancelConversationLoad()
        guard let runId = selectedRunId,
            let sessionId = detail?.card.run.sessionId
        else {
            conversationErrorMessage = L("This run has no canonical conversation.")
            return
        }
        let generation = conversationGeneration
        let repository = repository
        conversationErrorMessage = nil
        conversationTask = Task { [weak self] in
            let session = await Task.detached(priority: .userInitiated) {
                repository.conversation(sessionId: sessionId)
            }.value
            guard let self, !Task.isCancelled,
                generation == conversationGeneration,
                selectedRunId == runId,
                detail?.card.run.sessionId == sessionId
            else { return }
            guard let session else {
                conversationErrorMessage = L("The canonical conversation is unavailable.")
                return
            }
            if let window = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
                ChatWindowManager.shared.showWindow(id: window.id)
            } else {
                ChatWindowManager.shared.createWindow(
                    agentId: session.agentId,
                    sessionData: session
                )
            }
        }
    }

    private func cancelConversationLoad() {
        conversationTask?.cancel()
        conversationTask = nil
        conversationGeneration &+= 1
        conversationErrorMessage = nil
    }

    private func loadDetail(runId: UUID) {
        detailGeneration &+= 1
        let generation = detailGeneration
        let repository = repository
        detailTask?.cancel()
        isDetailLoading = true
        detailTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return DetailLoadOutcome.success(try repository.detail(runId: runId))
                } catch {
                    return DetailLoadOutcome.failure(error.localizedDescription)
                }
            }.value
            guard let self, !Task.isCancelled, generation == detailGeneration,
                selectedRunId == runId
            else { return }
            isDetailLoading = false
            switch outcome {
            case .success(let model):
                detail = model
                errorMessage = nil
            case .failure(let message):
                detail = nil
                errorMessage = message
            }
        }
    }
}

private enum BoardLoadOutcome: Sendable {
    case success(RunCenterBoardReadModel)
    case failure(String)
}

private enum DetailLoadOutcome: Sendable {
    case success(RunCenterDetailReadModel)
    case failure(String)
}
