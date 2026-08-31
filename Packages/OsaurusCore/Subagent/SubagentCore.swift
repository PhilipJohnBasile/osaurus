//
//  SubagentCore.swift
//  OsaurusCore — Subagent framework
//
//  Foundation value types shared by every nested subagent KIND (spawn,
//  image, computer_use). Generalized from the most-mature
//  computer_use scaffolding so all paths funnel through one host
//  (`SubagentSession`) and one compact-result contract (`SubagentResult`)
//  instead of four bespoke implementations.
//
//  This file is intentionally behavior-free: it declares the contract the
//  kinds + host agree on. Wiring (the kinds, the feed binding, the handoff
//  middleware, the capability registry) lands in the dedicated files.
//

import Foundation

// MARK: - Scope

/// Identifies one nested subagent run and the chat scope it belongs to.
///
/// Resolved once from `ChatExecutionContext` (with fresh fallbacks outside
/// chat — HTTP / eval — so the loop still runs, just without the row
/// binding). Every subagent kind binds to its chat row the same way
/// `computer_use` does today.
public struct SubagentScope: Sendable, Equatable {
    /// Stable durable identity allocated before target resolution or
    /// authorization. In-memory children use it when they enter execution;
    /// true delegated chats hand the same value to BackgroundTaskManager.
    public let runId: UUID
    /// The chat session whose tool call started this subagent.
    public let sessionId: String
    /// The originating tool-call id — the key the live feed/interrupt and
    /// the chat row are addressed by.
    public let toolCallId: String
    /// Transcript tool-call id that launched this child. Batch children use a
    /// synthetic `toolCallId` for sibling feed isolation, but retain this
    /// original parent call for durable provenance.
    public let parentToolCallId: String
    /// Caller-stable batch job identity. This is provenance only; `runId`
    /// remains the durable lifecycle identity.
    public let stableJobId: String?
    /// The agent whose model/settings scope the run.
    public let agentId: UUID
    /// Exact model selected by the parent turn. Nil on surfaces that do not
    /// publish a local parent (remote/API/eval calls).
    public let parentModelName: String?
    /// Explicit parent-turn Thinking choice. Nil preserves the nested model's
    /// own bundle default; true/false must survive every reconstructed step.
    public let enableThinking: Bool?
    /// Durable parent/root lineage captured from the launching turn. These
    /// remain immutable even when a detached child outlives that task tree.
    public let parentRunId: UUID?
    public let rootRunId: UUID?

    public init(
        sessionId: String,
        toolCallId: String,
        agentId: UUID,
        parentModelName: String? = nil,
        enableThinking: Bool? = nil,
        runId: UUID = UUID(),
        parentRunId: UUID? = nil,
        rootRunId: UUID? = nil,
        parentToolCallId: String? = nil,
        stableJobId: String? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.parentToolCallId = parentToolCallId ?? toolCallId
        self.agentId = agentId
        self.parentModelName = parentModelName
        self.enableThinking = enableThinking
        self.parentRunId = parentRunId
        self.rootRunId = rootRunId
        self.stableJobId = stableJobId
    }

    /// Resolve from the active chat execution context. Outside chat we fall
    /// back to fresh session/tool ids and the default agent (mirrors
    /// `ComputerUseTool.execute`); the child can still receive its own durable
    /// root row, but it has no parent/root lineage to inherit.
    public static func current() -> SubagentScope {
        SubagentScope(
            sessionId: ChatExecutionContext.currentSessionId ?? UUID().uuidString,
            toolCallId: ChatExecutionContext.currentToolCallId ?? UUID().uuidString,
            agentId: ChatExecutionContext.currentAgentId ?? Agent.defaultId,
            parentModelName: ChatExecutionContext.currentModelName,
            enableThinking: ChatExecutionContext.currentEnableThinking,
            parentRunId: ChatExecutionContext.currentRunId,
            rootRunId: ChatExecutionContext.currentRootRunId
        )
    }
}

// MARK: - Resolved model

/// The model a kind resolved for its run, validated BEFORE any residency
/// eviction (reject-before-evict). `isLocal` drives whether the optional
/// handoff middleware needs to free GPU residency first.
public struct ResolvedModel: Sendable, Equatable {
    /// User-facing model name (what the runner sends as `model`).
    public let name: String
    /// Stable installed-model id when known (local bundles); `nil` for
    /// remote/router models.
    public let id: String?
    /// True when this is an installed local bundle (so the handoff
    /// middleware may need single-GPU-residency eviction).
    public let isLocal: Bool

    public init(name: String, id: String? = nil, isLocal: Bool) {
        self.name = name
        self.id = id
        self.isLocal = isLocal
    }
}

// MARK: - Permission

/// Outcome of a kind's permission step. Each kind owns its consent UX (a
/// config gate, an interactive prompt, or a rich per-action gate inside
/// `run`); the host only needs the final allow/deny verdict.
public enum SubagentDecision: Sendable, Equatable {
    /// Proceed to (optional handoff +) run.
    case allow
    /// Refuse by policy (configuration). Maps to a `rejected` envelope.
    case denied(String)
    /// Refuse because the user explicitly declined an approval prompt. Maps
    /// to a `user_denied` envelope.
    case userDenied(String)
}

// MARK: - Result

/// The compact result a kind hands back. One shape across the whole
/// subagent family: a structured `payload` (the success `result` object the
/// inline-render bridge + agent-loop nudge read), plus a `summary` mirror
/// for surfaces that only want prose.
///
/// `@unchecked Sendable`: `payload` is a JSON object (scalars / strings /
/// arrays / nested dicts) built right before return, matching the existing
/// `ToolEnvelope.success(result:)` usage across the tools.
public struct SubagentResult: @unchecked Sendable {
    /// The success `result` object handed to `ToolEnvelope.success`.
    public var payload: [String: Any]
    /// Prose digest mirror for the live feed's terminal status + any surface
    /// that doesn't parse the payload. Defaults to the payload's `summary`.
    public var summary: String?

    public init(payload: [String: Any], summary: String? = nil) {
        self.payload = payload
        self.summary = summary ?? (payload["summary"] as? String) ?? (payload["digest"] as? String)
    }
}

// MARK: - Errors

/// Typed non-success outcomes a kind can throw. The host maps each to the
/// canonical `ToolEnvelope` failure kind + retryable default, centralizing
/// the envelope construction while letting each kind keep its own message.
public enum SubagentError: Error, Sendable {
    /// Policy refusal (configuration / not-spawnable / handoff disabled).
    case denied(String)
    /// User declined an interactive approval / stopped the run.
    case userDenied(String)
    /// The kind cannot run right now (no model, tools not registered, agent
    /// missing). Not retryable as-is.
    case unavailable(String)
    /// Malformed arguments for the kind's contract.
    case invalidArgs(message: String, field: String? = nil, expected: String? = nil)
    /// Hit a wall-clock / elapsed-time budget.
    case timedOut(String)
    /// Used the whole iteration budget without converging.
    case iterationCap(String)
    /// The inner loop attempted an unavailable child tool.
    case toolRejected(String)
    /// Overflowed the context window even after compaction.
    case overBudget(String)
    /// Returned empty output after tool execution.
    case emptyExhausted(String)
    /// Generic runtime failure; `retryable` chosen by the kind.
    case executionFailed(message: String, retryable: Bool = true)

    /// Map to the canonical failure envelope JSON string.
    public func envelope(tool: String) -> String {
        switch self {
        case .denied(let m):
            return ToolEnvelope.failure(kind: .rejected, message: m, tool: tool, retryable: false)
        case .userDenied(let m):
            return ToolEnvelope.failure(kind: .userDenied, message: m, tool: tool, retryable: false)
        case .unavailable(let m):
            return ToolEnvelope.failure(kind: .unavailable, message: m, tool: tool, retryable: false)
        case .invalidArgs(let m, let field, let expected):
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: m,
                field: field,
                expected: expected,
                tool: tool
            )
        case .timedOut(let m):
            return ToolEnvelope.failure(kind: .timeout, message: m, tool: tool, retryable: true)
        case .iterationCap(let m):
            return ToolEnvelope.failure(kind: .executionError, message: m, tool: tool, retryable: true)
        case .toolRejected(let m):
            return ToolEnvelope.failure(kind: .rejected, message: m, tool: tool, retryable: false)
        case .overBudget(let m):
            return ToolEnvelope.failure(kind: .executionError, message: m, tool: tool, retryable: true)
        case .emptyExhausted(let m):
            return ToolEnvelope.failure(kind: .executionError, message: m, tool: tool, retryable: true)
        case .executionFailed(let m, let retryable):
            return ToolEnvelope.failure(
                kind: .executionError,
                message: m,
                tool: tool,
                retryable: retryable
            )
        }
    }
}

/// A subagent failure known to belong to an admitted durable run. The wrapper
/// preserves the original envelope semantics while adding exact run
/// correlation; launch/admission failures must never use it.
struct DurableSubagentError: Error, Sendable {
    let runId: UUID
    let underlying: SubagentError
}
