//
//  SettingsVisibilityTests.swift
//  OsaurusCoreTests
//
//  Guardrails for the Developer Mode visibility policy:
//  - the preference persists through its UserDefaults key,
//  - every sidebar tab (including Insights) stays visible regardless of
//    the mode; the filtering hook only affects future developer tabs,
//  - Server settings sections classify into standard/advanced/developer
//    and filter consistently in both the grouped sidebar and the flat
//    section list,
//  - settings search drops developer entries while the mode is off.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct DeveloperModePreferenceTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsVisibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToDisabled() {
        let settings = DeveloperModeSettings(userDefaults: makeDefaults())
        #expect(settings.isEnabled == false)
        #expect(settings.shows(.standard))
        #expect(settings.shows(.advanced))
        #expect(!settings.shows(.developer))
    }

    @Test func persistsThroughUserDefaultsKey() {
        let defaults = makeDefaults()
        let settings = DeveloperModeSettings(userDefaults: defaults)
        settings.isEnabled = true
        #expect(defaults.bool(forKey: DeveloperModeSettings.defaultsKey))
        // A fresh instance reading the same defaults sees the persisted value.
        let reloaded = DeveloperModeSettings(userDefaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.shows(.developer))

        settings.isEnabled = false
        #expect(!defaults.bool(forKey: DeveloperModeSettings.defaultsKey))
    }
}

struct SidebarVisibilityFilteringTests {

    @Test func everyTabStaysVisibleRegardlessOfDeveloperMode() {
        // No current tab is developer-only; Insights in particular is an
        // everyday surface and must never leave the sidebar.
        #expect(ManagementTab.allCases.allSatisfy { $0.visibility != .developer })
        for section in ManagementSection.allCases {
            #expect(section.sidebarTabs(developerModeEnabled: false) == section.tabs)
            #expect(section.sidebarTabs(developerModeEnabled: true) == section.tabs)
        }
    }

    @Test func insightsRemainsListedAndRoutable() {
        #expect(
            ManagementSection.allCases.contains { section in
                section.sidebarTabs(developerModeEnabled: false).contains(.insights)
            }
        )
        #expect(ManagementTab.resolved(from: "insights") == .insights)
        #expect(ManagementTab.visibleCases.contains(.insights))
    }
}

struct ServerSettingsSectionClassificationTests {

    @Test func everySectionHasExactlyOneGroup() {
        for section in ServerSettingsSection.allCases {
            let owners = ServerSettingsSectionGroup.allCases.filter {
                $0.sections.contains(section)
            }
            #expect(owners == [section.group])
        }
    }

    @Test func classificationMatchesThePlan() {
        let standard = ServerSettingsSection.allCases.filter { $0.visibility == .standard }
        let advanced = ServerSettingsSection.allCases.filter { $0.visibility == .advanced }
        let developer = ServerSettingsSection.allCases.filter { $0.visibility == .developer }

        #expect(
            Set(standard) == Set([.connection, .authentication, .sampling, .memorySafety, .modelMemory, .power])
        )
        #expect(
            Set(advanced)
                == Set([
                    .globalProxy, .concurrency, .cache, .decodePerformance, .speculative,
                    .multimodal, .tools, .requestLimits,
                ])
        )
        #expect(developer == [.liveActivity])
    }

    @Test func advancedSectionsLiveInTheAdvancedGroup() {
        for section in ServerSettingsSection.allCases where section.visibility == .advanced {
            #expect(section.group == .advanced)
        }
        #expect(ServerSettingsSection.liveActivity.group == .diagnostics)
    }

    @Test func visibleSectionsFilterOnlyDeveloperTier() {
        let normal = ServerSettingsSection.visibleSections(developerModeEnabled: false)
        #expect(!normal.contains(.liveActivity))
        #expect(normal == ServerSettingsSection.allCases.filter { $0.visibility != .developer })
        #expect(
            ServerSettingsSection.visibleSections(developerModeEnabled: true)
                == ServerSettingsSection.allCases
        )
    }

    @Test func emptyGroupsDisappearWhenModeIsOff() {
        #expect(ServerSettingsSectionGroup.diagnostics.sections(developerModeEnabled: false).isEmpty)
        #expect(
            ServerSettingsSectionGroup.diagnostics.sections(developerModeEnabled: true)
                == [.liveActivity]
        )
        // Non-developer groups are unaffected by the mode.
        for group in ServerSettingsSectionGroup.allCases where group != .diagnostics {
            #expect(group.sections(developerModeEnabled: false) == group.sections)
        }
    }

    @Test func standardSectionsRenderBeforeAdvancedAndDiagnostics() {
        // `allCases` order is the render order; the plan puts everyday
        // setup first, Advanced tuning next, and Diagnostics last.
        let order = ServerSettingsSection.allCases
        let lastStandard = order.lastIndex { $0.visibility == .standard }!
        let firstAdvanced = order.firstIndex { $0.visibility == .advanced }!
        let firstDeveloper = order.firstIndex { $0.visibility == .developer }!
        #expect(lastStandard < firstAdvanced)
        let lastAdvanced = order.lastIndex { $0.visibility == .advanced }!
        #expect(lastAdvanced < firstDeveloper)
    }
}

struct SettingsSearchVisibilityTests {

    @Test func developerEntriesAreDroppedWhenModeIsOff() {
        for entry in SettingsSearchIndex.entries where entry.visibility == .developer {
            let visible = SettingsSearchIndex.search(entry.title, includeDeveloper: true)
            let hidden = SettingsSearchIndex.search(entry.title, includeDeveloper: false)
            #expect(visible.contains { $0.id == entry.id })
            #expect(!hidden.contains { $0.id == entry.id })
        }
    }

    @Test func standardEntriesAreUnaffectedByTheFilter() {
        let withDeveloper = SettingsSearchIndex.search("hotkey", includeDeveloper: true)
        let withoutDeveloper = SettingsSearchIndex.search("hotkey", includeDeveloper: false)
        #expect(withDeveloper.map(\.id) == withoutDeveloper.map(\.id))
    }

    @Test func developerModeToggleItselfIsSearchableForEveryone() {
        let hits = SettingsSearchIndex.search("developer mode", includeDeveloper: false)
        #expect(hits.contains { $0.id == "settings.advanced.developerMode" && $0.tab == .settings })
    }

    @Test func insightsIsSearchableForEveryone() {
        let insights = SettingsSearchIndex.search("insights", includeDeveloper: false)
        #expect(insights.contains { $0.id == "insights.requests" && $0.tab == .insights })
    }

    @Test func developerSurfacesAreHiddenOutsideDeveloperMode() {
        let liveActivity = SettingsSearchIndex.search("live activity", includeDeveloper: false)
        #expect(!liveActivity.contains { $0.id == "server.liveActivity" })
    }
}
