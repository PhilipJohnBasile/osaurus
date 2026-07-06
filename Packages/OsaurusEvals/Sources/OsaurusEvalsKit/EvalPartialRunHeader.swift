//
//  EvalPartialRunHeader.swift
//  OsaurusEvalsKit
//
//  Metadata stamped as the first line of a `.partial.jsonl` sidecar so
//  `--resume` can refuse to mix incompatible runs (model / catalog / judge).
//

import Foundation

public struct EvalPartialRunHeader: Sendable, Codable, Equatable {
    public static let kindValue = "run-header"

    public let kind: String
    public let runModel: String?
    public let catalogHash: String?
    public let judge: String?
    public let filter: String?

    public init(
        runModel: String?,
        catalogHash: String?,
        judge: String?,
        filter: String?
    ) {
        self.kind = Self.kindValue
        self.runModel = runModel
        self.catalogHash = catalogHash
        self.judge = judge
        self.filter = filter
    }
}

public enum EvalPartialRunHeaderError: Error, LocalizedError, Equatable {
    case resumeMismatch(field: String, expected: String?, found: String?)

    public var errorDescription: String? {
        switch self {
        case .resumeMismatch(let field, let expected, let found):
            return
                "resume refused: \(field) mismatch (sidecar=\(found ?? "nil"), "
                + "current=\(expected ?? "nil"))"
        }
    }
}
