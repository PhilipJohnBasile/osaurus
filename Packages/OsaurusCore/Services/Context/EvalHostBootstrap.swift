//
//  EvalHostBootstrap.swift
//  osaurus
//
//  Public, off-process bootstrap helpers for the OsaurusEvals package and
//  future scoreboards. Brings the eval CLI's view of plugins + search
//  indices in line with the host app so `capability_search` /
//  `capability_claims` domains see the same catalog the chat path does.
//

import Foundation

@MainActor
public enum EvalHostBootstrap {

    /// Plugin ids currently registered with the host. Exposed for the
    /// OsaurusEvals runner so it can `skip + warn` cases whose
    /// `requirePlugins` aren't installed locally instead of failing
    /// them. Includes native dylib plugins (osaurus.browser, etc.) —
    /// kept narrow on purpose; if future eval cases need MCP/sandbox
    /// fixture introspection too, extend this surface explicitly
    /// rather than exposing the full `PluginManager`.
    ///
    /// Returns an empty set if `loadInstalledPlugins()` hasn't been
    /// called yet — `PluginManager.plugins` only lists plugins LOADED
    /// in this process (via `dlopen`), not just installed on disk.
    public static func installedPluginIds() -> Set<String> {
        var ids: Set<String> = []
        for loaded in PluginManager.shared.plugins {
            ids.insert(loaded.plugin.id)
        }
        return ids
    }

    /// Names of the agent-enableable dynamic tools currently in the
    /// registry (loaded MCP, plugin, and sandbox-plugin tools; authoritative
    /// built-ins are excluded). Exposed so the
    /// OsaurusEvals `capability_claims` runner can seed an isolated eval
    /// agent's allowlist authoritatively — `ToolRegistry` itself stays
    /// internal to OsaurusCore. Empty until `loadInstalledPlugins()` (or
    /// the index bootstrap) has synced the registry.
    public static func dynamicToolNames() -> [String] {
        ToolRegistry.shared.listDynamicTools().map(\.name)
    }

    /// Stable eval-only dynamic tool used to prove the positive
    /// `capabilities_load` path without pretending an authoritative built-in
    /// is loadable. The AgentLoop runner registers it only around the one
    /// fixture that requests it and removes it before the next case.
    nonisolated public static let dynamicLoadProbeToolName = "eval_dynamic_load_probe"

    public static func registerDynamicLoadProbe() {
        let probe = EvalDynamicLoadProbeTool()
        ToolRegistry.shared.registerPluginTool(probe)
        ToolRegistry.shared.setEnabled(true, for: probe.name)
    }

    public static func unregisterDynamicLoadProbe() {
        ToolRegistry.shared.unregister(names: [dynamicLoadProbeToolName])
    }

    /// Deterministic multi-tool "plugin group" fixture (calendar-shaped).
    /// Unlike the single-tool probe above, this registers a real GROUP —
    /// three tools sharing a `plugin/<id>` manifest entry — so eval cases
    /// can prove the production discovery flow end to end: natural query →
    /// enabled-capabilities manifest names the group → `capabilities` loads
    /// `plugin/osaurus.eval.calendar` → the model calls a member tool and
    /// grounds its answer in the deterministic stub results. Calendar-shaped
    /// on purpose: it mirrors the live plugin flow that folder-surface,
    /// tool-named eval queries never exercised (the #2250 blind spot),
    /// without touching EventKit or requiring the real plugin.
    nonisolated public static let calendarProbePluginId = "osaurus.eval.calendar"
    nonisolated public static let calendarProbeToolNames: [String] = [
        "eval_calendar_create_event",
        "eval_calendar_get_events",
        "eval_calendar_search_events",
    ]

    public static func registerCalendarProbeGroup() {
        for tool in EvalCalendarProbeTool.groupTools() {
            ToolRegistry.shared.registerPluginTool(tool)
            ToolRegistry.shared.setEnabled(true, for: tool.name)
        }
    }

    public static func unregisterCalendarProbeGroup() {
        ToolRegistry.shared.unregister(names: calendarProbeToolNames)
    }

    /// True when at least one curated AppleScript bundle is installed and
    /// ready — the gate the `applescript` / `mac_query` tools use before
    /// appearing in the composed schema.
    public static var hasReadyAppleScriptModel: Bool {
        ModelPickerItemCache.shared.hasReadyAppleScriptModel
    }

    /// Boot every subsystem the chat path's capability search depends on
    /// so an out-of-process eval CLI sees the same indices the host app
    /// does. Mirrors the relevant slice of
    /// `AppDelegate.applicationDidFinishLaunching`. Idempotent.
    ///
    /// Subsystem coverage:
    /// - **plugins** — dlopen every installed plugin into
    ///   `PluginManager` / `ToolRegistry` / `SkillManager` so plugin
    ///   tools become visible to `listDynamicTools()` and
    ///   `installedPluginIds()`.
    /// - **tools index** — open `ToolDatabase`, init
    ///   `ToolSearchService`, sync from registry. Without these,
    ///   `capabilities_discover` cannot surface installed tools.
    /// - **methods + skills indices** — open `MethodDatabase`, init
    ///   `MethodSearchService`, force `SkillManager.refresh()` +
    ///   `SkillSearchService` init/rebuild. Without these, every
    ///   method/skill recall fixture would silently report 0 raw
    ///   hits, making "infrastructure not booted" indistinguishable
    ///   from "real recall miss". The explicit `refresh()` await
    ///   replaces relying on `SkillManager`'s eager init Task —
    ///   out-of-process callers can start querying before that Task
    ///   ever gets scheduled.
    public static func loadInstalledPlugins() async {
        await PluginManager.shared.loadAll()

        try? ToolDatabase.shared.open()
        await ToolSearchService.shared.initialize()
        await ToolIndexService.shared.syncFromRegistry()

        try? MethodDatabase.shared.open()
        await MethodSearchService.shared.initialize()
        await SkillManager.shared.refresh()
        await SkillSearchService.shared.initialize()
        await SkillSearchService.shared.rebuildIndex()
    }
}

private struct EvalDynamicLoadProbeTool: OsaurusTool {
    let name = EvalHostBootstrap.dynamicLoadProbeToolName
    let description =
        "Return a deterministic acknowledgement that a deferred dynamic tool loaded and executed."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON _: String) async throws -> String {
        ToolEnvelope.success(tool: name, text: "dynamic load probe executed")
    }
}

/// One member tool of the calendar-shaped probe plugin group. Every result is
/// deterministic (no clock, no EventKit) so `agent_loop` grounding assertions
/// can pin exact substrings. `ToolGroupDeclaring` gives the trio a shared
/// `plugin/<id>` manifest identity without a loaded plugin instance.
private struct EvalCalendarProbeTool: OsaurusTool, ToolGroupDeclaring {
    let name: String
    let description: String
    let parameters: JSONValue?
    let declaredGroupId = EvalHostBootstrap.calendarProbePluginId

    private let respond: @Sendable ([String: Any]) -> String

    func execute(argumentsJSON: String) async throws -> String {
        let args =
            (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        return ToolEnvelope.success(tool: name, text: respond(args))
    }

    static func groupTools() -> [EvalCalendarProbeTool] {
        let getEvents = EvalCalendarProbeTool(
            name: "eval_calendar_get_events",
            description:
                "Get the events on the user's calendar for a date. "
                + "Returns each event's start/end time, title, and location.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Day to list, e.g. 2026-08-05 or 'tomorrow'. Defaults to today."
                        ),
                    ])
                ]),
            ]),
            respond: { args in
                let date = (args["date"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "today"
                return """
                    2 events on \(date):
                    - 09:00-09:30 Team standup (Conference Room B)
                    - 14:00-15:00 Dentist appointment (Smile Dental, Dr. Nguyen)
                    """
            }
        )
        let createEvent = EvalCalendarProbeTool(
            name: "eval_calendar_create_event",
            description:
                "Create a new event on the user's calendar. "
                + "Returns the created event's id and scheduled slot.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Event title."),
                    ]),
                    "date": .object([
                        "type": .string("string"),
                        "description": .string("Day for the event, e.g. 2026-08-07 or 'Friday'."),
                    ]),
                    "start_time": .object([
                        "type": .string("string"),
                        "description": .string("Start time, e.g. 19:00."),
                    ]),
                ]),
                "required": .array([.string("title")]),
            ]),
            respond: { args in
                let title = args["title"] as? String ?? ""
                let date = (args["date"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "today"
                let time =
                    (args["start_time"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "09:00"
                return "Created event '\(title)' (id: evt-eval-0001) on \(date) at \(time)."
            }
        )
        let searchEvents = EvalCalendarProbeTool(
            name: "eval_calendar_search_events",
            description:
                "Search the user's calendar for events whose title or location "
                + "matches a query string.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Text to match against event titles/locations."),
                    ])
                ]),
                "required": .array([.string("query")]),
            ]),
            respond: { args in
                let query = args["query"] as? String ?? ""
                let normalized = query.lowercased()
                if normalized.contains("dentist") || normalized.contains("appointment") {
                    return """
                        1 event matching '\(query)':
                        - 14:00-15:00 Dentist appointment (Smile Dental, Dr. Nguyen) on 2026-08-05
                        """
                }
                return "No events found matching '\(query)'."
            }
        )
        return [getEvents, createEvent, searchEvents]
    }
}
