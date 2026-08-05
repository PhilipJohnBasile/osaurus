//
//  CapabilityGatewayPromptRegressionTests.swift
//  osaurusTests
//
//  Pins the #2250 calendar/plugin regression closed: chat schemas publish
//  only the merged `capabilities` gateway, so every capability-teaching
//  prompt section (enabled-capabilities manifest, grounding, discovery
//  nudge) must both RENDER for gateway-only schemas and NAME the gateway —
//  never the stripped `capabilities_discover` / `capabilities_load` pair.
//
//  Before this pin, the manifest gate required `capabilities_load` in the
//  resolved schema, so custom agents silently lost the manifest (models had
//  no grounded way to know a plugin existed), and the sections that did
//  render instructed the legacy loader, steering models into a
//  non-retryable toolNotFound dead end.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct CapabilityGatewayPromptRegressionTests {

    @Test("custom agent auto-mode prompt renders the manifest and names only the gateway")
    func customAgentManifestNamesTheGateway() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            try await DynamicCatalogTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-gateway-prompt-\(UUID().uuidString)",
                    isDirectory: true
                )
                try? FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true
                )
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                AgentManager.shared.refresh()
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    AgentManager.shared.refresh()
                    try? FileManager.default.removeItem(at: root)
                }

                // A grouped plugin tool — the manifest's whole reason to
                // exist. Group id gives it a plugin block in the render.
                let plugin = SandboxPlugin(
                    name: "GatewayFixture \(UUID().uuidString.prefix(6))",
                    description: "Gateway regression fixture plugin"
                )
                let groupTool = SandboxPluginTool(
                    spec: SandboxToolSpec(
                        id: "probe",
                        description: "Probe tool for the gateway manifest",
                        parameters: [:],
                        run: "echo hi"
                    ),
                    plugin: plugin
                )
                ToolRegistry.shared.registerPluginTool(groupTool)
                ToolRegistry.shared.setEnabled(true, for: groupTool.name)
                defer { ToolRegistry.shared.unregister(names: [groupTool.name]) }

                let agent = Agent(
                    name: "GatewayPrompt-\(UUID().uuidString.prefix(6))",
                    systemPrompt: "Be concise.",
                    agentAddress: "test-gateway-prompt-\(UUID().uuidString)",
                    toolSelectionMode: .auto,
                    memoryEnabled: false
                )
                AgentManager.shared.add(agent)
                defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

                let context = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    executionMode: .none,
                    model: "gpt-5",
                    query: "what's on my calendar today?"
                )

                // Schema: gateway only, legacy pair stripped.
                let schemaNames = Set(context.tools.map(\.function.name))
                #expect(schemaNames.contains("capabilities"))
                #expect(!schemaNames.contains("capabilities_discover"))
                #expect(!schemaNames.contains("capabilities_load"))

                // Manifest renders for the gateway-only schema and lists the
                // plugin tool the model would otherwise deny having.
                let manifest = try #require(context.enabledManifest)
                #expect(manifest.contains("## Enabled capabilities"))
                #expect(manifest.contains(groupTool.name))
                #expect(manifest.contains("`capabilities`"))

                // The manifest section actually renders into the prompt —
                // #2250's minimal-contract early return dropped it (and all
                // capability grounding) from custom-agent plain chat.
                #expect(context.prompt.contains("## Enabled capabilities"))
                #expect(context.prompt.contains(groupTool.name))

                // The complete prompt never names a capability tool the
                // schema does not publish — obeying the prompt must not
                // dead-end (#2250).
                #expect(!context.prompt.contains("capabilities_discover"))
                #expect(!context.prompt.contains("capabilities_load"))

                // Discovery-aware grounding co-fires with the manifest.
                #expect(context.prompt.contains("Enabled capabilities list"))
            }
        }
    }

    @Test("custom agent with a publish binding renders Channel Destinations")
    func customAgentPublishBindingRendersChannelDestinations() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-channel-dest-prompt-\(UUID().uuidString)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            let previousChannelDir = AgentChannelConfigurationStore.overrideDirectory
            AgentChannelConfigurationStore.overrideDirectory = root
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previousChannelDir
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let agent = Agent(
                name: "ChannelDest-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Be concise.",
                agentAddress: "test-channel-dest-\(UUID().uuidString)",
                toolSelectionMode: .auto,
                memoryEnabled: false
            )
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            var configuration = AgentChannelConfiguration()
            configuration.bindings = [
                AgentChannelBinding(
                    id: "daily-report",
                    agentId: agent.id,
                    connectionId: "discord",
                    roomId: "room-1",
                    threadId: nil,
                    label: "Daily report",
                    guidance: "Post the daily summary.",
                    allowedSources: [.chat],
                    outboundMode: .autonomous,
                    ratePolicy: AgentChannelBindingRatePolicy(),
                    enabled: true
                )
            ]
            try AgentChannelConfigurationStore.save(configuration)

            let context = await ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    executionMode: .none,
                    model: "gpt-5",
                    query: "post the daily report"
                )
            }

            // The binding surfaces the narrow publish tool in auto mode …
            #expect(
                context.tools.contains {
                    $0.function.name == AgentChannelPublishTool.toolName
                }
            )
            // … and the schema's "see the Channel Destinations context"
            // pointer must not dangle: the custom-agent (lean) compose path
            // has to render the section the default-agent path always had.
            let ids = context.manifest.sections.map(\.id)
            #expect(ids.contains("channelDestinations"))
            #expect(context.prompt.contains("`daily-report`"))

            // Mid-session-mutable content: the section must trail the static
            // prefix so binding edits never invalidate the KV cache.
            #expect(!context.staticPrefix.contains("daily-report"))
        }
    }

    @Test("eval calendar probe group renders as one plugin group and unregisters cleanly")
    func evalCalendarProbeGroupLifecycle() async throws {
        try await DynamicCatalogTestLock.shared.run {
            EvalHostBootstrap.unregisterCalendarProbeGroup()
            EvalHostBootstrap.registerCalendarProbeGroup()

            // Every member tool declares the shared group, so the trio flows
            // through the same manifest grouping and `plugin/<id>` loading as
            // a real plugin — the contract the PluginFlow eval lane rides on.
            for name in EvalHostBootstrap.calendarProbeToolNames {
                #expect(
                    ToolRegistry.shared.groupName(for: name)
                        == EvalHostBootstrap.calendarProbePluginId
                )
            }
            let groups = SystemPromptComposer.deriveEnabledManifest(agentId: UUID())
            let group = try #require(
                groups.first { $0.groupId == EvalHostBootstrap.calendarProbePluginId }
            )
            #expect(
                group.tools.map(\.name).sorted()
                    == EvalHostBootstrap.calendarProbeToolNames.sorted()
            )

            EvalHostBootstrap.unregisterCalendarProbeGroup()
            let remaining = SystemPromptComposer.deriveEnabledManifest(agentId: UUID())
            #expect(
                !remaining.contains { $0.groupId == EvalHostBootstrap.calendarProbePluginId }
            )
            for name in EvalHostBootstrap.calendarProbeToolNames {
                #expect(ToolRegistry.shared.groupName(for: name) == nil)
            }
        }
    }
}
