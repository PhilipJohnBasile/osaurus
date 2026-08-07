import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatRunSnapshotTests {
    private static let timeout: Duration = .seconds(10)

    @Test("send freezes ambient model, prompt, sampling, and thinking controls")
    func sendFreezesAmbientInputsBeforeAsyncComposition() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.disableTools = true
            chatConfig.warmModelsOnLoad = false
            ChatConfigurationStore.save(chatConfig)

            let manager = AgentManager.shared
            var agent = Agent(
                name: "Run Snapshot \(UUID().uuidString)",
                systemPrompt: "FROZEN_PROMPT_SENTINEL",
                temperature: 0.23,
                maxTokens: 321,
                toolsEnabled: false,
                memoryEnabled: false
            )
            manager.add(agent)

            let engine = ChatRunSnapshotCaptureEngine()
            let session = ChatSession()
            session.forceChatEngineRouteForTests = true
            session.agentId = agent.id
            session.selectedModel = "foundation"
            session.activeModelOptions = ["disableThinking": .bool(true)]
            session.chatEngineFactory = { _ in engine }

            session.send("Freeze this request.")

            // The send task has not had a chance to compose yet: mutate every
            // ambient source that the old path re-read after its first await.
            session.selectedModel = "snapshot-model-after"
            session.activeModelOptions = ["disableThinking": .bool(false)]
            agent.systemPrompt = "MUTATED_PROMPT_SENTINEL"
            agent.temperature = 0.91
            agent.maxTokens = 999
            manager.update(agent)

            try await waitForSnapshot(timeout: Self.timeout) {
                await engine.request != nil
            }
            let request = try #require(await engine.request)

            #expect(request.model == "foundation")
            #expect(request.temperature == 0.23)
            #expect(request.max_tokens == 321)
            #expect(request.enable_thinking == false)
            #expect(request.messages.first?.content?.contains("FROZEN_PROMPT_SENTINEL") == true)
            #expect(request.messages.first?.content?.contains("MUTATED_PROMPT_SENTINEL") == false)

            #expect(session.isContextBudgetLive)
            #expect(
                session.activeContextWindowResolution?.tokens
                    == AgentLoopBudget.resolveContextWindowSync(
                        modelId: "foundation"
                    )
            )
            #expect(session.activeContextMaxResponseTokens == 321)
            let frozenStaticRows = Dictionary(
                uniqueKeysWithValues: session.estimatedContextBreakdown.context.map {
                    ($0.id, $0.tokens)
                }
            )
            // A model/settings notification may invalidate the next-turn
            // preview while this request is active. It must not clear the
            // authoritative run budget or switch the live denominator.
            session.invalidateTokenCache(preservingPromptShapeBaseline: true)
            #expect(session.isContextBudgetLive)
            #expect(
                session.activeContextWindowResolution?.tokens
                    == AgentLoopBudget.resolveContextWindowSync(
                        modelId: "foundation"
                    )
            )
            #expect(
                Dictionary(
                    uniqueKeysWithValues: session.estimatedContextBreakdown.context.map {
                        ($0.id, $0.tokens)
                    }
                ) == frozenStaticRows
            )

            session.input = "unsent draft must stay outside the active request"
            #expect(
                Dictionary(
                    uniqueKeysWithValues: session.estimatedContextBreakdown.context.map {
                        ($0.id, $0.tokens)
                    }
                ) == frozenStaticRows
            )
            #expect(
                session.estimatedContextBreakdown.allEntries
                    .first { $0.id == "input" }?.tokens ?? 0 == 0
            )

            try await waitForSnapshot(timeout: Self.timeout) {
                !session.isSendActiveForComposer
            }
            _ = await manager.delete(id: agent.id)
        }
    }
}

private actor ChatRunSnapshotCaptureEngine: ChatEngineProtocol {
    private(set) var request: ChatCompletionRequest?

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        self.request = request
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                continuation.yield("ok")
                continuation.finish()
            }
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatRunSnapshotTests", code: 1)
    }
}

@MainActor
private func waitForSnapshot(
    timeout: Duration,
    _ predicate: @escaping () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatRunSnapshotTests", code: 2)
}
