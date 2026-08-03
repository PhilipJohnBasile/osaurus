//
//  RequestCapabilityTool.swift
//  osaurus
//
//  `request_capability(capability, reason)` — the model's bridge from "I
//  can't" to "one click away". When the system prompt's Dormant
//  capabilities section tells the model a request needs a gated
//  capability, the model calls this instead of refusing. The chat layer
//  intercepts the result marker and renders a native inline card with the
//  enable affordance; the model receives only a compact confirmation and
//  is told to wait for the user.
//
//  The tool itself never mutates settings — enabling is a user action on
//  the card, routed through the same AgentManager path the settings
//  toggle uses. This tool only records intent.
//

import Foundation

public final class RequestCapabilityTool: OsaurusTool, @unchecked Sendable {

    public let name = CapabilityRequestContract.toolName
    public let description =
        "Ask the user to enable a dormant Osaurus capability that the current "
        + "request needs (see the Dormant capabilities list in your instructions). "
        + "The app shows the user an inline enable card. Call this INSTEAD of "
        + "saying you can't do something a dormant capability covers, then wait "
        + "for the user — do not retry the task in the same turn."

    public var parameters: JSONValue? {
        let ids = DormantCapability.Kind.allCases.map { JSONValue.string($0.rawValue) }
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string(CapabilityRequestContract.capabilityArgument)]),
            "properties": .object([
                CapabilityRequestContract.capabilityArgument: .object([
                    "type": .string("string"),
                    "enum": .array(ids),
                    "description": .string(
                        "Id of the dormant capability the user's request needs, "
                        + "exactly as listed in the Dormant capabilities section."
                    ),
                ]),
                CapabilityRequestContract.reasonArgument: .object([
                    "type": .string("string"),
                    "description": .string(
                        "One short sentence, addressed to the user, saying why "
                        + "this capability is needed for their request."
                    ),
                ]),
            ]),
        ])
    }

    public init() {}

    /// Rewrite the spec's `capability` enum to the session's ACTUAL
    /// dormant ids. The registry's canned spec lists every kind; leaving
    /// non-dormant ids in the schema invites a model to request a
    /// capability the prompt never listed (e.g. `web_search` when only
    /// the master `tools` switch is off). The dormant set is
    /// session-constant, so the narrowed spec is KV-cache safe.
    static func constrainedSpec(_ base: Tool, allowedIds: [String]) -> Tool {
        guard !allowedIds.isEmpty,
            case .object(var schema)? = base.function.parameters,
            case .object(var properties)? = schema["properties"],
            case .object(var capability)? =
                properties[CapabilityRequestContract.capabilityArgument]
        else { return base }
        capability["enum"] = .array(allowedIds.map { .string($0) })
        properties[CapabilityRequestContract.capabilityArgument] = .object(capability)
        schema["properties"] = .object(properties)
        return Tool(
            type: base.type,
            function: ToolFunction(
                name: base.function.name,
                description: base.function.description,
                parameters: .object(schema)
            )
        )
    }

    // MARK: - Marker contract

    /// Payload round-tripped from the tool result to the chat card. The
    /// card resolves the CURRENT blocker/affordance at render time (state
    /// may have changed since compose), so only intent is carried here.
    public struct Payload: Codable, Sendable, Equatable {
        public let capability: DormantCapability.Kind
        public let reason: String?
        /// Agent the request was made against, stamped by the chat layer
        /// at interception time (the tool has no session context). Drives
        /// the card's enable action; optional for decode compatibility.
        public var agentId: UUID?

        public init(capability: DormantCapability.Kind, reason: String?, agentId: UUID? = nil) {
            self.capability = capability
            self.reason = reason
            self.agentId = agentId
        }
    }

    /// Re-encode a payload into the marker format (used by the chat layer
    /// to stamp `agentId` onto the stored card result).
    public static func marker(for payload: Payload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return markerStart + String(decoding: data, as: UTF8.self) + markerEnd
    }

    static let markerStart = "---CAPABILITY_REQUEST_START---\n"
    static let markerEnd = "\n---CAPABILITY_REQUEST_END---"

    /// Extract the card payload from a full tool result, or nil when the
    /// result is not a capability-request marker. Accepts both the raw
    /// marker block and the canonical envelope shape where the marker
    /// lives inside `result.text` — the registry boundary
    /// (`ToolRegistry.normalizeToolResult`) wraps every result into an
    /// envelope, so the raw form only survives in stored card overrides.
    /// Mirrors `RenderChartTool`'s dual-format parsing.
    public static func payload(from toolResult: String) -> Payload? {
        let source: String
        if let envelope = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let text = envelope["text"] as? String
        {
            source = text
        } else {
            source = toolResult
        }
        guard let start = source.range(of: markerStart),
            let end = source.range(of: markerEnd, range: start.upperBound..<source.endIndex)
        else { return nil }
        let json = String(source[start.upperBound..<end.lowerBound])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// Compact confirmation for the model's history (mirrors
    /// `RenderChartTool.compactModelResult`): the full marker feeds the UI
    /// card only, and the model must not see or recite it.
    public static func compactModelResult(for payload: Payload) -> String {
        ToolEnvelope.success(
            tool: CapabilityRequestContract.toolName,
            text:
                "The user has been shown an enable card for "
                + "\(payload.capability.displayName). Tell them briefly what you "
                + "will do once it is enabled, then stop and wait — do not retry "
                + "the task or call this tool again for the same capability this turn."
        )
    }

    // MARK: - Execution

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let capabilityReq = requireString(
            args,
            CapabilityRequestContract.capabilityArgument,
            expected: "a dormant capability id from the Dormant capabilities list",
            tool: name
        )
        guard case .value(let rawCapability) = capabilityReq else {
            return capabilityReq.failureEnvelope ?? ""
        }
        guard let kind = DormantCapability.Kind(rawValue: rawCapability) else {
            let ids = DormantCapability.Kind.allCases
                .map { $0.rawValue }
                .joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Unknown capability `\(rawCapability)`. Use one of the ids "
                    + "from the Dormant capabilities section: \(ids).",
                field: CapabilityRequestContract.capabilityArgument,
                expected: "one of: \(ids)",
                tool: name
            )
        }

        let reasonReq = optionalString(
            args,
            CapabilityRequestContract.reasonArgument,
            expected: "a short user-facing sentence",
            tool: name
        )
        guard case .value(let reason) = reasonReq else { return reasonReq.failureEnvelope ?? "" }

        let payload = Payload(capability: kind, reason: reason)
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        // Wrapped in the canonical success envelope (marker in `result.text`,
        // like render_chart). Returning the raw marker instead does NOT
        // survive the registry boundary: `normalizeToolResult` wraps any
        // non-envelope output, JSON-escaping the marker's newlines inside
        // `result.text`, and a plain substring scan then misses it. Emitting
        // the canonical shape ourselves means `payload(from:)` always goes
        // through the envelope decode, which restores the text byte-exact.
        return ToolEnvelope.success(
            tool: name,
            text: Self.markerStart + json + Self.markerEnd
        )
    }
}
