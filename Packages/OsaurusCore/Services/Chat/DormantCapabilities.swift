//
//  DormantCapabilities.swift
//  OsaurusCore
//
//  Derives the list of capabilities that EXIST in Osaurus but are gated
//  off for the current agent/session, so the prompt composer can tell
//  the model the truth: "this is one toggle away", instead of silently
//  omitting the capability and leaving the model to confabulate an
//  "I can't do that".
//
//  Pure by design, mirroring `AgentCapabilityReadiness`: every
//  environment fact (installed image model, size class, default-agent
//  routing) is passed in by the caller, so the resolver is deterministic
//  and unit-testable without MainActor probes.
//

import Foundation

/// Shared names for the capability-request bridge between the prompt
/// (which tells the model to call it), the tool schema, and the chat
/// layer (which intercepts the call and renders the enable card).
public enum CapabilityRequestContract {
    public static let toolName = "request_capability"
    public static let capabilityArgument = "capability"
    public static let reasonArgument = "reason"
}

/// One capability the app supports but the current session cannot call,
/// with the machine-readable reason it is off. `blocker` reuses the
/// settings-surface vocabulary so chat and settings explain the same
/// gate with the same words.
public struct DormantCapability: Sendable, Equatable, Identifiable {

    /// Stable ids, also used as the `capability` argument of the
    /// `request_capability` tool and round-tripped through chat cards.
    public enum Kind: String, Sendable, CaseIterable, Codable {
        /// The per-agent (or global) master Tools switch. When this is the
        /// blocker, every tool-backed capability below is implicitly off.
        case tools
        case webSearch = "web_search"
        case image
        case browserUse = "browser_use"
        case computerUse = "computer_use"
        case appleScript = "applescript"
        case spawn
    }

    public let kind: Kind
    public let blocker: AgentCapabilityBlocker

    public var id: String { kind.rawValue }

    /// Readiness bucket for the blocker — drives both prompt phrasing and
    /// the chat card's affordance (one-click enable vs settings deep link
    /// vs plain explanation).
    public var state: AgentCapabilityReadinessState {
        AgentCapabilityReadiness.resolve(
            configured: blocker != .notConfigured,
            toolsEnabled: blocker != .toolsDisabled && blocker != .globalToolsDisabled,
            blockers: [blocker]
        ).state
    }

    /// True when a single toggle flip makes the capability callable —
    /// the case the chat card can resolve with one click.
    public var isOneToggleAway: Bool {
        switch blocker {
        case .notConfigured, .toolsDisabled:
            return true
        default:
            return false
        }
    }

    public init(kind: Kind, blocker: AgentCapabilityBlocker) {
        self.kind = kind
        self.blocker = blocker
    }
}

extension DormantCapability.Kind {

    /// Short user-facing name, used in both the prompt section and the
    /// chat card title.
    public var displayName: String {
        switch self {
        case .tools: return L("Tools")
        case .webSearch: return L("Web Search")
        case .image: return L("Image Generation")
        case .browserUse: return L("Browser Use")
        case .computerUse: return L("Computer Use")
        case .appleScript: return L("AppleScript")
        case .spawn: return L("Subagents")
        }
    }

    /// Whether the chat session may auto-resend the blocked request the
    /// moment this capability is enabled. Capabilities that operate the
    /// user's machine (browser, screen, app automation) stay explicit:
    /// the card offers a "Retry request" button instead, so "flip toggle →
    /// agent starts driving the browser" can never happen as a side
    /// effect of a settings change.
    public var autoResumesAfterEnable: Bool {
        switch self {
        case .tools, .webSearch, .image, .spawn:
            return true
        case .browserUse, .computerUse, .appleScript:
            return false
        }
    }

    /// One-line "what unlocks when this is on" for the prompt section.
    /// English-only on purpose: this is model-facing prompt text, not UI
    /// copy, and must stay byte-stable across locales for KV caching.
    var promptSummary: String {
        switch self {
        case .tools:
            return
                "the master switch for every tool: web search, live data such as weather, "
                + "file access, and all capabilities below"
        case .webSearch:
            return "search the web and fetch live pages for current information"
        case .image:
            return "generate images from text prompts with a local image model"
        case .browserUse:
            return "drive a real browser to visit sites and act on them for the user"
        case .computerUse:
            return "see the screen and operate macOS apps on the user's behalf"
        case .appleScript:
            return "automate macOS apps via AppleScript"
        case .spawn:
            return "delegate work to other agents or models in parallel"
        }
    }
}

/// Resolves which supported capabilities are dormant for one composed
/// chat session. Inputs mirror `AgentCapabilityReadiness.subagent` so
/// both surfaces agree on why something is off.
public enum DormantCapabilityResolver {

    public struct Inputs: Sendable, Equatable {
        public let effectiveToolsOff: Bool
        public let sizeClassDisablesTools: Bool
        public let isDefaultAgent: Bool
        public let hasReadyImageModel: Bool
        public let hasReadyAppleScriptModel: Bool

        public init(
            effectiveToolsOff: Bool,
            sizeClassDisablesTools: Bool,
            isDefaultAgent: Bool,
            hasReadyImageModel: Bool,
            hasReadyAppleScriptModel: Bool
        ) {
            self.effectiveToolsOff = effectiveToolsOff
            self.sizeClassDisablesTools = sizeClassDisablesTools
            self.isDefaultAgent = isDefaultAgent
            self.hasReadyImageModel = hasReadyImageModel
            self.hasReadyAppleScriptModel = hasReadyAppleScriptModel
        }
    }

    /// Derive the dormant list. Ordering is deterministic (master switch
    /// first, then `Kind.allCases` order) so the rendered prompt section
    /// stays byte-stable across composes with unchanged settings.
    public static func resolve(
        snapshot: AgentConfigSnapshot,
        inputs: Inputs
    ) -> [DormantCapability] {
        var dormant: [DormantCapability] = []

        // Master switch off: report ONE entry instead of drowning the
        // prompt in per-capability repeats of the same root cause. The
        // context-size auto-disable is not user-fixable, so it maps to
        // `contextLimit` rather than a toggle blocker.
        if inputs.effectiveToolsOff {
            let blocker: AgentCapabilityBlocker
            if inputs.sizeClassDisablesTools {
                blocker = .contextLimit
            } else if snapshot.globalToolsDisabled {
                blocker = .globalToolsDisabled
            } else {
                blocker = .toolsDisabled
            }
            dormant.append(DormantCapability(kind: .tools, blocker: blocker))
            return dormant
        }

        if !snapshot.webSearchEnabled {
            dormant.append(DormantCapability(kind: .webSearch, blocker: .notConfigured))
        }

        if !snapshot.imageEnabled {
            dormant.append(DormantCapability(kind: .image, blocker: .notConfigured))
        } else if !inputs.hasReadyImageModel {
            dormant.append(DormantCapability(kind: .image, blocker: .noImageModel))
        }

        // Browser Use is hard-off for the built-in Default agent (see
        // AgentConfigSnapshot.browserUseEnabled) — surface it as a
        // surface limitation, not a toggle, so the model never promises
        // a switch that does not exist there.
        if inputs.isDefaultAgent {
            dormant.append(DormantCapability(kind: .browserUse, blocker: .unsupportedSurface))
        } else if !snapshot.browserUseEnabled {
            dormant.append(DormantCapability(kind: .browserUse, blocker: .notConfigured))
        }

        if !snapshot.computerUseEnabled {
            dormant.append(DormantCapability(kind: .computerUse, blocker: .notConfigured))
        }

        if !snapshot.appleScriptEnabled {
            dormant.append(DormantCapability(kind: .appleScript, blocker: .notConfigured))
        } else if !inputs.hasReadyAppleScriptModel {
            dormant.append(DormantCapability(kind: .appleScript, blocker: .noAppleScriptModel))
        }

        if !snapshot.spawnDelegationEnabled {
            dormant.append(DormantCapability(kind: .spawn, blocker: .notConfigured))
        } else if snapshot.spawnableAgentIDs.isEmpty && snapshot.spawnableModelNames.isEmpty {
            dormant.append(DormantCapability(kind: .spawn, blocker: .noConfiguredTargets))
        }

        return dormant
    }
}
