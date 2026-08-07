//
//  ChatRunSnapshot.swift
//  osaurus
//
//  Immutable inputs for one logical ChatSession run. Agent loops rebuild an
//  API request for every model step, but ambient UI/store state must never be
//  re-read after this snapshot is captured.
//

import Foundation

struct ChatRunSnapshot: Sendable {
    let agentId: UUID
    let agentConfig: AgentConfigSnapshot
    let model: String?
    let modelType: String?
    let chatConfiguration: ChatConfiguration
    let generationControls: ChatTurnGenerationControls
    let temperature: Float?
    let maxResponseTokens: Int?
    let contextWindow: AgentLoopBudget.ContextWindowResolution
    let sessionId: UUID?
    let source: SessionSource
    let loadIntent: ModelLoadIntent
    let sourcePluginId: String?
    let oneOffSkillId: UUID?
    let isRemoteAgentTarget: Bool
    let remoteAgentProviderId: UUID?
    let remoteAgentLogModel: String?
    let supportsImages: Bool
    let supportsAudio: Bool
    let supportsVideo: Bool
    let screenContextEnabled: Bool
    let enabledToolNames: Set<String>?
}

/// The request prefix after asynchronous preparation has completed. From this
/// point onward, model steps may only append run-owned conversation events.
struct SealedChatRunContext: Sendable {
    let snapshot: ChatRunSnapshot
    let composedContext: ComposedContext
    let systemPrompt: String
    let baselineTools: [Tool]
    let executionMode: ExecutionMode
    let folderRoot: URL?
    let initialMessages: [ChatMessage]
    let initialTurnIds: Set<UUID>
}
