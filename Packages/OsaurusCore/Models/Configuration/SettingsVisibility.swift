//
//  SettingsVisibility.swift
//  osaurus
//
//  Three-tier visibility policy for settings surfaces plus the persisted
//  Developer Mode switch that reveals the `developer` tier.
//
//  - `standard`: setup, status, permissions, safety, common preferences,
//    and recovery actions. Always visible.
//  - `advanced`: legitimate power-user controls. Always available, but
//    presented under collapsed/grouped "Advanced" surfaces.
//  - `developer`: raw JSON, inspectors, internal metrics, test harnesses,
//    experimental or not-yet-wired controls, and copyable diagnostic
//    reports. Visible only while Developer Mode is enabled.
//
//  Developer Mode must never hide actionable errors or required recovery
//  steps — views that gate on it keep plain-language health summaries and
//  fixes in the standard tier and only tuck away implementation detail.
//

import Foundation
import SwiftUI

// MARK: - Settings Visibility

/// Which audience a settings surface is meant for. Drives sidebar/tab
/// filtering, settings-search filtering, and in-view gating.
public enum SettingsVisibility: String, Sendable, CaseIterable {
    case standard
    case advanced
    case developer
}

// MARK: - Developer Mode

/// Persisted app-wide Developer Mode switch. Observed by settings views so
/// toggling takes effect immediately, without a restart.
@MainActor
public final class DeveloperModeSettings: ObservableObject {
    public static let shared = DeveloperModeSettings()

    /// UserDefaults key. Read through this class rather than directly so
    /// call sites stay consistent and testable.
    public static let defaultsKey = "ai.osaurus.settings.developerModeEnabled"

    private let userDefaults: UserDefaults

    @Published public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            userDefaults.set(isEnabled, forKey: Self.defaultsKey)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: Self.defaultsKey)
    }

    /// Whether a surface with the given visibility should render right now.
    public func shows(_ visibility: SettingsVisibility) -> Bool {
        visibility != .developer || isEnabled
    }
}
