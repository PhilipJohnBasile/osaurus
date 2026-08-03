//
//  DormantCapabilitiesTests.swift
//
//  The dormant-capabilities resolver + prompt section are the truthful
//  counterpart to the enabled manifest: a gated capability must be
//  NAMED with its recovery path instead of silently omitted (which made
//  models answer "I can't" for features one toggle away). These tests
//  pin the resolver's blocker mapping and the section's contract with
//  the `request_capability` tool.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Dormant capability resolver")
struct DormantCapabilityResolverTests {

    private func snapshot(
        toolsDisabled: Bool = false,
        globalToolsDisabled: Bool = false,
        webSearchEnabled: Bool = true,
        computerUseEnabled: Bool = false,
        browserUseEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        appleScriptEnabled: Bool = false,
        spawnableModelNames: [String] = []
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: toolsDisabled,
            globalToolsDisabled: globalToolsDisabled,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: "test-model",
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false,
            webSearchEnabled: webSearchEnabled,
            computerUseEnabled: computerUseEnabled,
            browserUseEnabled: browserUseEnabled,
            spawnDelegationEnabled: spawnDelegationEnabled,
            imageEnabled: imageEnabled,
            appleScriptEnabled: appleScriptEnabled,
            spawnableModelNames: spawnableModelNames
        )
    }

    private func inputs(
        effectiveToolsOff: Bool = false,
        sizeClassDisablesTools: Bool = false,
        isDefaultAgent: Bool = false,
        hasReadyImageModel: Bool = true,
        hasReadyAppleScriptModel: Bool = true
    ) -> DormantCapabilityResolver.Inputs {
        .init(
            effectiveToolsOff: effectiveToolsOff,
            sizeClassDisablesTools: sizeClassDisablesTools,
            isDefaultAgent: isDefaultAgent,
            hasReadyImageModel: hasReadyImageModel,
            hasReadyAppleScriptModel: hasReadyAppleScriptModel
        )
    }

    @Test("tools off collapses to a single master entry")
    func toolsOffIsOneEntry() {
        let dormant = DormantCapabilityResolver.resolve(
            snapshot: snapshot(toolsDisabled: true),
            inputs: inputs(effectiveToolsOff: true)
        )
        #expect(dormant.count == 1)
        #expect(dormant.first?.kind == .tools)
        #expect(dormant.first?.blocker == .toolsDisabled)
        #expect(dormant.first?.isOneToggleAway == true)
    }

    @Test("global kill switch and size class map to their own blockers")
    func toolsOffBlockerPriority() {
        let global = DormantCapabilityResolver.resolve(
            snapshot: snapshot(toolsDisabled: true, globalToolsDisabled: true),
            inputs: inputs(effectiveToolsOff: true)
        )
        #expect(global.first?.blocker == .globalToolsDisabled)

        let sizeClass = DormantCapabilityResolver.resolve(
            snapshot: snapshot(),
            inputs: inputs(effectiveToolsOff: true, sizeClassDisablesTools: true)
        )
        #expect(sizeClass.first?.blocker == .contextLimit)
        #expect(sizeClass.first?.isOneToggleAway == false)
    }

    @Test("per-capability toggles surface as notConfigured")
    func perCapabilityToggles() {
        let dormant = DormantCapabilityResolver.resolve(
            snapshot: snapshot(webSearchEnabled: false),
            inputs: inputs()
        )
        let kinds = dormant.map(\.kind)
        #expect(kinds.contains(.webSearch))
        #expect(kinds.contains(.image))
        #expect(kinds.contains(.browserUse))
        #expect(kinds.contains(.computerUse))
        #expect(kinds.contains(.appleScript))
        #expect(kinds.contains(.spawn))
        #expect(!kinds.contains(.tools))
        #expect(dormant.allSatisfy { $0.blocker == .notConfigured })
    }

    @Test("enabled capability with missing model surfaces the install blocker")
    func missingModelBlockers() {
        let dormant = DormantCapabilityResolver.resolve(
            snapshot: snapshot(imageEnabled: true, appleScriptEnabled: true),
            inputs: inputs(hasReadyImageModel: false, hasReadyAppleScriptModel: false)
        )
        #expect(dormant.first { $0.kind == .image }?.blocker == .noImageModel)
        #expect(dormant.first { $0.kind == .appleScript }?.blocker == .noAppleScriptModel)
        #expect(dormant.first { $0.kind == .image }?.isOneToggleAway == false)
    }

    @Test("spawn enabled without targets needs setup, with targets is not dormant")
    func spawnTargets() {
        let without = DormantCapabilityResolver.resolve(
            snapshot: snapshot(spawnDelegationEnabled: true),
            inputs: inputs()
        )
        #expect(without.first { $0.kind == .spawn }?.blocker == .noConfiguredTargets)

        let with = DormantCapabilityResolver.resolve(
            snapshot: snapshot(
                spawnDelegationEnabled: true,
                spawnableModelNames: ["m"]
            ),
            inputs: inputs()
        )
        #expect(!with.contains { $0.kind == .spawn })
    }

    @Test("default agent reports browser use as a surface limitation")
    func defaultAgentBrowser() {
        let dormant = DormantCapabilityResolver.resolve(
            snapshot: snapshot(browserUseEnabled: true),
            inputs: inputs(isDefaultAgent: true)
        )
        #expect(dormant.first { $0.kind == .browserUse }?.blocker == .unsupportedSurface)
    }

    @Test("fully enabled agent has nothing dormant")
    func nothingDormant() {
        let dormant = DormantCapabilityResolver.resolve(
            snapshot: snapshot(
                webSearchEnabled: true,
                computerUseEnabled: true,
                browserUseEnabled: true,
                spawnDelegationEnabled: true,
                imageEnabled: true,
                appleScriptEnabled: true,
                spawnableModelNames: ["m"]
            ),
            inputs: inputs()
        )
        #expect(dormant.isEmpty)
    }
}

@Suite("Dormant capabilities prompt section")
struct DormantCapabilitiesSectionTests {

    @Test("empty dormant list renders no section")
    func emptyIsNil() {
        #expect(
            SystemPromptTemplates.dormantCapabilitiesSection(
                [], requestToolAvailable: true) == nil
        )
    }

    @Test("section names capability ids and gates the recovery on the request tool")
    func recoveryContract() {
        let dormant = [
            DormantCapability(kind: .webSearch, blocker: .notConfigured),
            DormantCapability(kind: .image, blocker: .noImageModel),
        ]
        let withTool = SystemPromptTemplates.dormantCapabilitiesSection(
            dormant, requestToolAvailable: true)!
        #expect(withTool.contains("web_search"))
        #expect(withTool.contains("image"))
        #expect(withTool.contains(CapabilityRequestContract.toolName))
        // The literal call example (arguments included) must be present —
        // prose alone made a small model call the capability id as a tool.
        #expect(withTool.contains("request_capability({\"capability\": \"web_search\"})"))
        #expect(withTool.contains("NOT tool names"))

        // Without the tool in the schema, its name must NOT appear —
        // naming an uncallable tool is the recitation-loop trap
        // SystemPromptDefaultIdentityTests documents. The text path names
        // the concrete setting instead.
        let withoutTool = SystemPromptTemplates.dormantCapabilitiesSection(
            dormant, requestToolAvailable: false)!
        #expect(!withoutTool.contains(CapabilityRequestContract.toolName))
        #expect(withoutTool.contains("Image Generation"))
    }

    @Test("compact variant stays id-based and short")
    func compactVariant() {
        let dormant = [DormantCapability(kind: .browserUse, blocker: .notConfigured)]
        let compact = SystemPromptTemplates.dormantCapabilitiesSection(
            dormant, requestToolAvailable: true, compact: true)!
        #expect(compact.contains("browser_use"))
        #expect(compact.count < 700)
    }
}

@Suite("Tools-off consent carve-out")
struct ToolsOffCarveOutTests {

    private func snapshot(
        toolsDisabled: Bool,
        globalToolsDisabled: Bool = false
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: toolsDisabled,
            globalToolsDisabled: globalToolsDisabled,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: "test-model",
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
    }

    @Test("per-agent toggle off keeps the single consent tool")
    func perAgentToggleQualifies() {
        #expect(
            SystemPromptComposer.toolsOffCarveOutApplies(
                snapshot: snapshot(toolsDisabled: true),
                sizeClassDisablesTools: false
            )
        )
    }

    @Test("global kill switch and tiny-context strip stay at zero tools")
    func hardOffCasesExcluded() {
        #expect(
            !SystemPromptComposer.toolsOffCarveOutApplies(
                snapshot: snapshot(toolsDisabled: true, globalToolsDisabled: true),
                sizeClassDisablesTools: false
            )
        )
        #expect(
            !SystemPromptComposer.toolsOffCarveOutApplies(
                snapshot: snapshot(toolsDisabled: true),
                sizeClassDisablesTools: true
            )
        )
    }
}

@Suite("Post-enable resume policy")
struct CapabilityAutoResumePolicyTests {

    @Test("machine-operating capabilities never auto-resume")
    func sensitiveKindsWait() {
        #expect(!DormantCapability.Kind.browserUse.autoResumesAfterEnable)
        #expect(!DormantCapability.Kind.computerUse.autoResumesAfterEnable)
        #expect(!DormantCapability.Kind.appleScript.autoResumesAfterEnable)
    }

    @Test("tame capabilities auto-resume")
    func tameKindsResume() {
        #expect(DormantCapability.Kind.tools.autoResumesAfterEnable)
        #expect(DormantCapability.Kind.webSearch.autoResumesAfterEnable)
        #expect(DormantCapability.Kind.image.autoResumesAfterEnable)
        #expect(DormantCapability.Kind.spawn.autoResumesAfterEnable)
    }
}

@Suite("Consent discovery schema")
struct ConsentDiscoverySchemaTests {

    @Test("intent roster covers every card kind and excludes plumbing")
    func rosterContents() {
        let names = Set(SystemPromptComposer.consentIntentToolNames)
        // Every blocked-tool → card-kind mapping must have a stub, or the
        // capability is undiscoverable in tools-off sessions.
        for expected in [
            "web_search", "image", "computer_use", "browser_use",
            "applescript", "spawn_agent",
        ] {
            #expect(names.contains(expected), "missing stub for \(expected)")
        }
        // Plumbing must never mint enable cards.
        for excluded in [
            "todo", "complete", "clarify", "share_artifact", "capabilities",
            "get_current_time", CapabilityRequestContract.toolName,
        ] {
            #expect(!names.contains(excluded), "\(excluded) must not be stubbed")
        }
        // Every roster entry must carry its hand-written disambiguation
        // line — a nil-description stub reintroduces the wrong-tool picks
        // the copy exists to prevent.
        for name in names {
            #expect(
                SystemPromptComposer.consentStubDescriptions[name] != nil,
                "missing stub description for \(name)"
            )
        }
    }

    @MainActor
    @Test("blocked tools map to their capability kind")
    func blockedToolKindMapping() {
        #expect(ChatSession.capabilityKind(forTool: "web_search") == .webSearch)
        #expect(ChatSession.capabilityKind(forTool: "computer_use") == .computerUse)
        #expect(ChatSession.capabilityKind(forTool: "spawn_batch") == .spawn)
        #expect(ChatSession.capabilityKind(forTool: "file_read") == nil)
    }
}

@Suite("request_capability constrained spec")
struct CapabilityRequestConstrainedSpecTests {

    @Test("capability enum narrows to the session's dormant ids")
    func enumNarrows() throws {
        let tool = RequestCapabilityTool()
        let base = Tool(
            type: "function",
            function: ToolFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            )
        )
        let narrowed = RequestCapabilityTool.constrainedSpec(base, allowedIds: ["tools"])
        guard
            case .object(let schema)? = narrowed.function.parameters,
            case .object(let properties)? = schema["properties"],
            case .object(let capability)? = properties["capability"],
            case .array(let ids)? = capability["enum"]
        else {
            Issue.record("narrowed spec lost its parameter structure")
            return
        }
        #expect(ids == [.string("tools")])
        // Empty allow-list must fall back to the base spec, never an
        // empty enum (which would make the tool uncallable).
        let unchanged = RequestCapabilityTool.constrainedSpec(base, allowedIds: [])
        #expect(unchanged.function.parameters == base.function.parameters)
    }
}

@Suite("request_capability marker round-trip")
struct CapabilityRequestMarkerTests {

    @Test("payload survives marker encode/decode with agent stamp")
    func roundTrip() throws {
        let agentId = UUID()
        let payload = RequestCapabilityTool.Payload(
            capability: .browserUse,
            reason: "Needed to check your Amazon orders.",
            agentId: agentId
        )
        let marker = try #require(RequestCapabilityTool.marker(for: payload))
        let decoded = try #require(RequestCapabilityTool.payload(from: marker))
        #expect(decoded == payload)
        #expect(decoded.agentId == agentId)
    }

    @Test("non-marker text yields no payload")
    func nonMarker() {
        #expect(RequestCapabilityTool.payload(from: "{\"ok\":true}") == nil)
    }

    /// Regression: the registry boundary (`normalizeToolResult`) wraps any
    /// non-envelope output into a success envelope, JSON-escaping the
    /// marker's newlines inside `result.text`. A plain substring scan
    /// missed the marker in that shape, so the interception fell through
    /// and no card ever rendered (observed live, 2026-08-03). The parser
    /// must accept the envelope-wrapped form.
    @Test("registry-normalized result still parses")
    func registryNormalizedParses() throws {
        let payload = RequestCapabilityTool.Payload(
            capability: .tools, reason: "Needed to look up the weather.")
        let raw = try #require(RequestCapabilityTool.marker(for: payload))
        let normalized = ToolRegistry.normalizeToolResult(
            raw, tool: CapabilityRequestContract.toolName)
        #expect(RequestCapabilityTool.payload(from: normalized) == payload)
    }

    /// The tool's own output is already the canonical envelope shape and
    /// must parse directly (this is what postProcessToolResult sees).
    @Test("execute output parses")
    func executeOutputParses() async throws {
        let result = try await RequestCapabilityTool().execute(
            argumentsJSON: "{\"capability\": \"tools\", \"reason\": \"To check the weather.\"}"
        )
        let decoded = try #require(RequestCapabilityTool.payload(from: result))
        #expect(decoded.capability == .tools)
        #expect(decoded.reason == "To check the weather.")
    }
}
