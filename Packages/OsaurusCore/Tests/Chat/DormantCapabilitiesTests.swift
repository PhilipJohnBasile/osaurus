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
}
