//
//  CapabilityRequestActions.swift
//  OsaurusCore
//
//  Resolves and performs the user-side action behind an inline
//  capability-request card (see RequestCapabilityTool). The card never
//  lets the model self-enable anything: the primary action is a USER
//  click, and enabling routes through the exact same
//  `AgentManager.update` path the settings toggle uses, so consent and
//  persistence semantics are identical to flipping the switch by hand.
//

import Foundation

extension Notification.Name {
    /// Posted by an inline capability card's "Retry request" button after a
    /// machine-operating capability (browser/computer/AppleScript) was
    /// enabled — the explicit user go-ahead the auto-resume path
    /// deliberately withholds for those kinds. userInfo: `agentId`
    /// (uuidString), `capability` (DormantCapability.Kind rawValue).
    public static let capabilityRequestRetry = Notification.Name(
        "osaurus.capabilityRequestRetry")
}

@MainActor
public enum CapabilityRequestActions {

    /// What the card should offer for one request, resolved against LIVE
    /// state at render time (settings may have changed since the model
    /// asked).
    public enum Action: Equatable {
        /// Capability is already callable — the user (or another card)
        /// enabled it after the request was made.
        case alreadyEnabled
        /// One toggle away on a custom agent: the card offers one-click
        /// enable.
        case enable
        /// Multi-step or not agent-local (missing model, global switch,
        /// Default-agent config): the card deep-links to the exact
        /// settings surface.
        case openSettings(tab: ManagementTab, buttonTitle: String)
        /// Nothing actionable (e.g. Browser Use on the built-in Default
        /// agent): the card explains and suggests the path.
        case explainOnly(message: String)
    }

    /// Resolve the card's affordance for `kind` on `agentId`.
    public static func resolve(kind: DormantCapability.Kind, agentId: UUID) -> Action {
        let manager = AgentManager.shared
        let caps = manager.effectiveCapabilities(for: agentId)
        let agent = manager.agent(for: agentId)
        let isCustom = agent.map { !$0.isBuiltIn } ?? false

        switch kind {
        case .tools:
            if caps.toolsEnabled { return .alreadyEnabled }
            return isCustom
                ? .enable
                : .openSettings(tab: .chat, buttonTitle: L("Open Chat Settings"))

        case .webSearch:
            if caps.toolsEnabled && caps.webSearchEnabled { return .alreadyEnabled }
            return isCustom
                ? .enable
                : .openSettings(tab: .search, buttonTitle: L("Open Search Settings"))

        case .image:
            if !ModelPickerItemCache.shared.hasReadyImageModel {
                return .openSettings(
                    tab: .imageGeneration,
                    buttonTitle: L("Install an Image Model")
                )
            }
            if caps.toolsEnabled && caps.imageEnabled { return .alreadyEnabled }
            return isCustom
                ? .enable
                : .openSettings(tab: .imageGeneration, buttonTitle: L("Open Image Settings"))

        case .browserUse:
            if caps.toolsEnabled && caps.browserUseEnabled { return .alreadyEnabled }
            guard isCustom else {
                return .explainOnly(
                    message: L(
                        "Browser Use is available on custom agents. Create an agent with Browser Use enabled to do this."
                    )
                )
            }
            return .enable

        case .computerUse:
            if caps.toolsEnabled && caps.computerUseEnabled { return .alreadyEnabled }
            guard isCustom else {
                return .explainOnly(
                    message: L(
                        "Computer Use is available on custom agents. Create an agent with Computer Use enabled to do this."
                    )
                )
            }
            return .enable

        case .appleScript:
            if !ModelPickerItemCache.shared.hasReadyAppleScriptModel {
                return .openSettings(
                    tab: .models,
                    buttonTitle: L("Install an AppleScript Model")
                )
            }
            if caps.toolsEnabled && caps.appleScriptEnabled { return .alreadyEnabled }
            return isCustom
                ? .enable
                : .openSettings(tab: .agents, buttonTitle: L("Open Agent Settings"))

        case .spawn:
            if caps.toolsEnabled && caps.spawnDelegationEnabled,
                !(caps.spawnableAgentIDs.isEmpty && caps.spawnableModelNames.isEmpty)
            {
                return .alreadyEnabled
            }
            // Spawn always needs target selection alongside the toggle, so
            // route to settings rather than half-enabling it.
            return .openSettings(tab: .agents, buttonTitle: L("Open Agent Settings"))
        }
    }

    /// Perform the one-click enable for `.enable`. Returns true when the
    /// toggle was applied; false when the agent could not be mutated
    /// (deleted, built-in) — the card falls back to opening settings.
    @discardableResult
    public static func enable(kind: DormantCapability.Kind, agentId: UUID) -> Bool {
        guard var agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else {
            return false
        }
        switch kind {
        case .tools:
            agent.toolsEnabled = true
        case .webSearch:
            agent.toolsEnabled = true
            agent.settings.webSearchEnabled = true
        case .image:
            agent.toolsEnabled = true
            agent.settings.imageEnabled = true
        case .browserUse:
            agent.toolsEnabled = true
            agent.settings.browserUseEnabled = true
        case .computerUse:
            agent.toolsEnabled = true
            agent.settings.computerUseEnabled = true
        case .appleScript:
            agent.toolsEnabled = true
            agent.settings.appleScriptEnabled = true
        case .spawn:
            // Handled via settings (needs target selection); never
            // one-click. Kept exhaustive so a new kind forces a decision.
            return false
        }
        AgentManager.shared.update(agent)
        return true
    }

    /// Open the Management window on `tab`, deep-linked to this agent
    /// where the tab supports it. When the destination is the agent
    /// detail, also arm the one-shot capability highlight so the exact
    /// toggle scrolls into view and glows (same affordance as the
    /// settings-search landing).
    public static func openSettings(
        tab: ManagementTab,
        agentId: UUID,
        highlighting kind: DormantCapability.Kind? = nil
    ) {
        if let kind, tab == .agents {
            ManagementStateManager.shared.pendingCapabilityHighlight = kind
        }
        AppDelegate.shared?.showManagementWindow(
            initialTab: tab,
            deeplinkAgentId: tab == .agents ? agentId : nil
        )
    }
}
