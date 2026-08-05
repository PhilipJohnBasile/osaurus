//
//  PluginFlowSuiteTests.swift
//  OsaurusEvalsKitTests
//
//  Decode + contract guard for the PluginFlow lane — the sandbox-surface,
//  natural-query plugin-discovery cases added after the #2250 regression
//  showed the folder-surface, tool-named AgentLoop cases never exercised
//  the flow real users hit (manifest → `capabilities` load → member tool).
//
//  Model-free: this pins the lane's SHAPE so a refactor can't silently
//  degrade it back into the blind spot it exists to close (e.g. dropping
//  the sandbox fixture, naming tools in queries, or losing the
//  surface-pinning systemPromptContains assertions).
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct PluginFlowSuiteTests {

    private func loadSuite() throws -> EvalSuite {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/PluginFlow", isDirectory: true)
        return try EvalSuite.load(from: suiteDir)
    }

    @Test func pluginFlowSuiteDecodesCleanly() throws {
        let suite = try loadSuite()
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        // Floor, not exact: new cases must not break this smoke.
        #expect(suite.cases.count >= 6, "PluginFlow suite shrank; got \(suite.cases.count)")
    }

    @Test func everyCaseRunsTheSandboxSurfaceWithTheProbeGroup() throws {
        let suite = try loadSuite()
        for testCase in suite.cases {
            #expect(testCase.domain == "agent_loop", "\(testCase.id) wrong domain")
            #expect(
                testCase.fixtures.sandbox != nil,
                "\(testCase.id) must compose the sandbox chat surface"
            )
            #expect(
                testCase.fixtures.enablePluginGroups
                    == [EvalHostBootstrap.calendarProbePluginId],
                "\(testCase.id) must request exactly the calendar probe group"
            )
            // Surface pinning: the case fails (not silently retargets) if a
            // prompt refactor stops rendering the manifest on this surface.
            let promptPins = testCase.expect.agentLoop?.systemPromptContains ?? []
            #expect(
                promptPins.contains("## Enabled capabilities"),
                "\(testCase.id) missing the manifest surface pin"
            )
            #expect(
                promptPins.contains(
                    "plugin/\(EvalHostBootstrap.calendarProbePluginId)"
                ),
                "\(testCase.id) missing the plugin-group surface pin"
            )
        }
    }

    @Test func naturalQueriesNeverNameTheMemberTools() throws {
        let suite = try loadSuite()
        // The bare-id rescue case is deliberately instruction-following (it
        // pins argument-shape recovery); every other query must stay natural
        // language, because obedience queries were exactly the eval blind
        // spot that let the live discovery regression ship.
        for testCase in suite.cases where testCase.id != "pluginflow.calendar-bare-id-rescue" {
            for toolName in EvalHostBootstrap.calendarProbeToolNames {
                #expect(
                    !testCase.query.contains(toolName),
                    "\(testCase.id) query names member tool \(toolName)"
                )
            }
            #expect(
                !testCase.query.lowercased().contains("capabilities"),
                "\(testCase.id) query names the capabilities gateway"
            )
        }
    }

    @Test func everyCaseProvesTheGatewayLoadPath() throws {
        let suite = try loadSuite()
        for testCase in suite.cases {
            let exp = try #require(testCase.expect.agentLoop, "\(testCase.id) missing agentLoop")
            let must = Set(exp.mustCallTools ?? []).union(exp.mustCallToolsInOrder ?? [])
            #expect(
                must.contains("capabilities"),
                "\(testCase.id) must assert the capabilities gateway was called"
            )
            let memberAssertions = must.union(exp.mustCallAnyTools ?? [])
            #expect(
                memberAssertions.contains(where: {
                    EvalHostBootstrap.calendarProbeToolNames.contains($0)
                }),
                "\(testCase.id) must assert a member tool was reached"
            )
        }
    }
}
