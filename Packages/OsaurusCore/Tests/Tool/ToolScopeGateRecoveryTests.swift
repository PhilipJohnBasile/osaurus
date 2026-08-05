//
//  ToolScopeGateRecoveryTests.swift
//  osaurusTests
//
//  Pins the execution-scope gate's error contract (#2145). A registered,
//  enabled dynamic tool the turn simply never exposed must come back as a
//  RETRYABLE tool_not_found pointing at the loader tool the request
//  exposes (`capabilities` on chat, `capabilities_load` legacy), so the model
//  can load it and recover instead of apologizing and giving up. A name the
//  registry does not know keeps the opaque, non-retryable refusal — the
//  gate must not reveal anything about tools that were deliberately
//  withheld.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class ScopeProbeTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description = "Test-only scope gate probe."
    let parameters: JSONValue? = nil
    private(set) var executions = 0

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

@Suite(.serialized)
@MainActor
struct ToolScopeGateRecoveryTests {

    private func envelope(_ result: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: Any]
    }

    @Test
    func unscopedButLoadableTool_returnsRetryableCapabilitiesLoadHint() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_loadable_probe")
        ToolRegistry.shared.registerPluginTool(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        // Scope exposes nothing — the skill-invocation shape from #2145,
        // where the model calls a real tool it was never shown.
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 0)
        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        // Empty scope exposes neither loader, so the hint falls back to the
        // only discoverable one on chat surfaces: `capabilities`.
        #expect(message.contains("Call capabilities with ids"))
        #expect(message.contains("tool/\(tool.name)"))
    }

    @Test
    func unscopedButLoadableTool_hintsLegacyLoaderWhenThatIsWhatTheRequestExposes() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_legacy_loader_probe")
        ToolRegistry.shared.registerPluginTool(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        let loadSpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities_load",
                description: "legacy loader",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [loadSpec])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains("Call capabilities_load with ids"))
    }

    /// The #2250 regression shape: sessions frozen before the gateway
    /// switch, older skill bodies, and legacy-trained models still call
    /// `capabilities_load` / `capabilities_discover` by name. Those are
    /// registered built-ins, so without the carve-out they'd take the
    /// opaque non-retryable refusal and the model would give up one call
    /// away from succeeding. With the gateway in scope, the gate must
    /// steer to `capabilities` with a retryable envelope instead.
    @Test
    func legacyCapabilityToolNames_redirectToGatewayWhenItIsInScope() async throws {
        let gatewaySpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities",
                description: "merged gateway",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [gatewaySpec])
        for legacyName in ["capabilities_load", "capabilities_discover"] {
            let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(name: legacyName, argumentsJSON: "{}")
            }
            let parsed = try envelope(result)
            #expect(parsed?["ok"] as? Bool == false)
            #expect(parsed?["kind"] as? String == "tool_not_found")
            #expect(parsed?["retryable"] as? Bool == true, "\(legacyName) must be retryable")
            let message = parsed?["message"] as? String ?? ""
            #expect(message.contains("`capabilities`"), "\(legacyName) hint must name the gateway")
        }
    }

    /// Without the gateway in scope the legacy names keep the opaque
    /// refusal — the carve-out must not invent a loader the request
    /// does not expose.
    @Test
    func legacyCapabilityToolNames_stayOpaqueWithoutTheGateway() async throws {
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(
                name: "capabilities_load",
                argumentsJSON: "{}"
            )
        }
        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
    }

    @Test
    func unexposedGatedBuiltInDoesNotSuggestCapabilitiesLoad() async throws {
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: BrowserUseTool.toolName,
                    argumentsJSON: #"{"goal":"open example.com"}"#
                )
            }
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("Call capabilities"))
    }

    @Test
    func unscopedUnknownName_keepsOpaqueNonRetryableRefusal() async throws {
        let unknown = "test_scope_gate_ghost_\(UUID().uuidString.prefix(8))"

        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: unknown, argumentsJSON: "{}")
        }

        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("Call capabilities"))
    }

    @Test
    func unscopedAgentWithheldTool_keepsOpaqueNonRetryableRefusal() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_withheld_probe")
        ToolRegistry.shared.register(tool)
        // Registered but globally disabled: capabilities_load would refuse
        // it, so the gate must not hint at it.
        ToolRegistry.shared.setEnabled(false, for: tool.name)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 0)
        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("Call capabilities"))
    }

    /// The live Qwen3-4B PluginFlow shape: the model reads the
    /// `plugin/<id>` row in the enabled-capabilities manifest and calls
    /// the GROUP id as if it were a tool
    /// (`osaurus.eval.calendar({"date":"tomorrow"})`). The gate must
    /// return a RETRYABLE envelope steering to a gateway load of
    /// `plugin/<id>` — with and without the `plugin/` prefix — instead of
    /// the generic "do not guess tool names" dead end.
    @Test
    func groupIdCalledAsTool_redirectsToGatewayLoad() async throws {
        EvalHostBootstrap.registerCalendarProbeGroup()
        defer { EvalHostBootstrap.unregisterCalendarProbeGroup() }

        let gatewaySpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities",
                description: "merged gateway",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [gatewaySpec])
        for guessed in [
            EvalHostBootstrap.calendarProbePluginId,
            "plugin/\(EvalHostBootstrap.calendarProbePluginId)",
        ] {
            let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: guessed,
                    argumentsJSON: #"{"date":"tomorrow"}"#
                )
            }
            let parsed = try envelope(result)
            #expect(parsed?["ok"] as? Bool == false)
            #expect(parsed?["kind"] as? String == "tool_not_found")
            #expect(parsed?["retryable"] as? Bool == true, "\(guessed) must be retryable")
            let message = parsed?["message"] as? String ?? ""
            #expect(message.contains("capability group"))
            #expect(
                message.contains("plugin/\(EvalHostBootstrap.calendarProbePluginId)"),
                "\(guessed) hint must carry the loadable id"
            )
            // No member tool names in the hint — same anti-hallucination
            // stance as the missing "did you mean" list.
            #expect(!message.contains("eval_calendar_get_events"))
        }
    }

    /// A group whose member tools are all outside this agent's allowlist
    /// keeps the opaque refusal — the rescue must not reveal withheld
    /// groups.
    @Test
    func groupIdCalledAsTool_staysOpaqueWhenAgentIsNotAllowedAnyMember() async throws {
        EvalHostBootstrap.registerCalendarProbeGroup()
        defer { EvalHostBootstrap.unregisterCalendarProbeGroup() }

        // A manual-mode agent whose allowlist has none of the group tools.
        let agent = Agent(
            name: "GroupRescueDenied-\(UUID().uuidString.prefix(6))",
            systemPrompt: "",
            agentAddress: "test-group-rescue-\(UUID().uuidString)",
            toolSelectionMode: .manual,
            memoryEnabled: false
        )
        AgentManager.shared.add(agent)
        AgentManager.shared.updateEnabledToolNames(["get_current_time"], for: agent.id)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: EvalHostBootstrap.calendarProbePluginId,
                    argumentsJSON: "{}"
                )
            }
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("capability group"))
    }

    @Test
    func scopeActivationMakesTheToolExecutable() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_activated_probe")
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        let scope = ToolExecutionScope(exposed: [])
        scope.activate([tool.name])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }
}
