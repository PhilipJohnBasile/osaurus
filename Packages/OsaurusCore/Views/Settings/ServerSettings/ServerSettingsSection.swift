//
//  ServerSettingsSection.swift
//  osaurus
//
//  Anchor + grouping model for the Server → Settings sidebar
//  navigation. Each case is the `.id(...)` of one section card in
//  `ServerSettingsTabContent`; the sidebar uses these to render the
//  left rail and to drive `ScrollViewReader.scrollTo(...)`.
//
//  Sections are classified by audience (`SettingsVisibility`):
//  everyday setup first, operational tuning under Advanced, and
//  runtime diagnostics only while Developer Mode is on.
//

import SwiftUI

/// One anchor row in the Server → Settings sidebar. Order of the
/// `allCases` array is also the visual order in the panel (sidebar +
/// scroll content), so keep new cases inserted in the position they
/// should render.
enum ServerSettingsSection: String, CaseIterable, Hashable, Identifiable {
    // Standard: daily setup and safe defaults.
    case connection
    case authentication
    case sampling
    case memorySafety
    case modelMemory
    case power
    // Advanced: operational tuning, available to everyone.
    case globalProxy
    case concurrency
    case cache
    case decodePerformance
    case speculative
    case multimodal
    case tools
    case requestLimits
    // Developer: runtime diagnostics, visible only in Developer Mode.
    case liveActivity

    var id: String { rawValue }

    /// User-facing row title.
    var title: String {
        switch self {
        case .connection: return L("Connection")
        case .globalProxy: return L("Global Proxy")
        case .authentication: return L("Authentication")
        case .sampling: return L("Sampling Defaults")
        case .concurrency: return L("Concurrency & Batching")
        case .cache: return L("Cache")
        case .memorySafety: return L("Memory Safety")
        case .decodePerformance: return L("Decode Performance")
        case .speculative: return L("Speculative Decoding")
        case .liveActivity: return L("Live Activity")
        case .multimodal: return L("Multimodal")
        case .tools: return L("Tools & Templates")
        case .modelMemory: return L("Model Memory")
        case .power: return L("Power & Sleep")
        case .requestLimits: return L("Request Limits")
        }
    }

    /// SF Symbol used for the sidebar row icon.
    var icon: String {
        switch self {
        case .connection: return "network"
        case .globalProxy: return "shield.lefthalf.filled"
        case .authentication: return "key.horizontal"
        case .sampling: return "slider.horizontal.3"
        case .concurrency: return "gauge.with.dots.needle.bottom.0percent"
        case .cache: return "externaldrive.connected.to.line.below"
        case .memorySafety: return "memorychip.fill"
        case .decodePerformance: return "speedometer"
        case .speculative: return "bolt.horizontal"
        case .liveActivity: return "waveform.path.ecg"
        case .multimodal: return "photo.on.rectangle.angled"
        case .tools: return "wrench.and.screwdriver"
        case .modelMemory: return "memorychip"
        case .power: return "powersleep"
        case .requestLimits: return "shield.lefthalf.filled"
        }
    }

    /// Who this section is for. Drives sidebar + content filtering: only
    /// `developer` sections are hidden (while Developer Mode is off);
    /// `advanced` sections stay reachable under the Advanced group.
    var visibility: SettingsVisibility {
        switch self {
        case .connection, .authentication, .sampling, .memorySafety, .modelMemory, .power:
            return .standard
        case .globalProxy, .concurrency, .cache, .decodePerformance, .speculative, .multimodal,
            .tools, .requestLimits:
            return .advanced
        case .liveActivity:
            return .developer
        }
    }

    var group: ServerSettingsSectionGroup {
        switch self {
        case .connection, .authentication:
            return .server
        case .sampling:
            return .generation
        case .memorySafety, .modelMemory, .power:
            return .lifecycle
        case .globalProxy, .concurrency, .cache, .decodePerformance, .speculative, .multimodal,
            .tools, .requestLimits:
            return .advanced
        case .liveActivity:
            return .diagnostics
        }
    }

    /// Sections to render for the given Developer Mode state, in display
    /// order. `developer` sections drop out entirely while the mode is off.
    static func visibleSections(developerModeEnabled: Bool) -> [ServerSettingsSection] {
        allCases.filter { developerModeEnabled || $0.visibility != .developer }
    }
}

/// Sidebar group header. Order here drives the visual order of groups
/// in the sidebar; sections inside a group preserve `ServerSettingsSection.allCases` order.
enum ServerSettingsSectionGroup: String, CaseIterable, Hashable {
    case server
    case generation
    case lifecycle
    case advanced
    case diagnostics

    var title: String {
        switch self {
        case .server: return L("Server")
        case .generation: return L("Generation")
        case .lifecycle: return L("Memory & Lifecycle")
        case .advanced: return L("Advanced")
        case .diagnostics: return L("Diagnostics")
        }
    }

    /// Sections in this group, preserving `ServerSettingsSection.allCases` order.
    var sections: [ServerSettingsSection] {
        ServerSettingsSection.allCases.filter { $0.group == self }
    }

    /// Sections in this group that should render for the given Developer
    /// Mode state. Groups whose result is empty are hidden entirely.
    func sections(developerModeEnabled: Bool) -> [ServerSettingsSection] {
        sections.filter { developerModeEnabled || $0.visibility != .developer }
    }
}
