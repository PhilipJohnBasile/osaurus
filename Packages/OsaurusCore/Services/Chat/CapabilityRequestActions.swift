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
    ///
    /// The card never mutates settings itself — every actionable case
    /// deep-links into the settings window with the relevant control
    /// highlighted. Deliberate product choice: the trip through settings
    /// teaches users where their agent's capabilities live, and the
    /// post-enable resume brings them straight back to a continued
    /// conversation.
    public enum Action: Equatable {
        /// Capability is already callable — the user enabled it after the
        /// request was made.
        case alreadyEnabled
        /// The card deep-links to the settings surface owning the fix
        /// (toggle, model install, target selection).
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

        let agentSettings = Action.openSettings(
            tab: .agents, buttonTitle: L("Enable in Settings"))

        switch kind {
        case .tools:
            if caps.toolsEnabled { return .alreadyEnabled }
            return isCustom
                ? agentSettings
                : .openSettings(tab: .chat, buttonTitle: L("Open Chat Settings"))

        case .webSearch:
            if caps.toolsEnabled && caps.webSearchEnabled { return .alreadyEnabled }
            return isCustom
                ? agentSettings
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
                ? agentSettings
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
            return agentSettings

        case .computerUse:
            if caps.toolsEnabled && caps.computerUseEnabled { return .alreadyEnabled }
            guard isCustom else {
                return .explainOnly(
                    message: L(
                        "Computer Use is available on custom agents. Create an agent with Computer Use enabled to do this."
                    )
                )
            }
            return agentSettings

        case .appleScript:
            if !ModelPickerItemCache.shared.hasReadyAppleScriptModel {
                return .openSettings(
                    tab: .models,
                    buttonTitle: L("Install an AppleScript Model")
                )
            }
            if caps.toolsEnabled && caps.appleScriptEnabled { return .alreadyEnabled }
            return agentSettings

        case .spawn:
            if caps.toolsEnabled && caps.spawnDelegationEnabled,
                !(caps.spawnableAgentIDs.isEmpty && caps.spawnableModelNames.isEmpty)
            {
                return .alreadyEnabled
            }
            return agentSettings
        }
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
        // Both requests ride shared state, NOT construction-time deeplink
        // args: a reused management window would otherwise rebuild its
        // hosting controller to deliver `deeplinkAgentId`, and the dying
        // graph's subscriptions consumed the highlight before the new one
        // mounted (observed live: card click landed on the agent detail
        // with no tab switch and no glow).
        if tab == .agents {
            ManagementStateManager.shared.pendingAgentDetailId = agentId
            if let kind {
                ManagementStateManager.shared.pendingCapabilityHighlight =
                    .init(agentId: agentId, kind: kind)
            }
        }
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }
}
