//
//  EvalAssertionRecorder.swift
//  OsaurusEvalsKit
//
//  Structured pass/fail records for eval case scoring — complements the
//  human-readable `notes` array and powers assertion-level diffing.
//

import Foundation

/// Accumulates structured assertions while scoring a case row.
public struct EvalAssertionRecorder: Sendable {
    public private(set) var assertions: [EvalCaseAssertion] = []
    private var sequence = 0

    public init() {}

    public mutating func record(kind: String, pass: Bool, detail: String) {
        sequence += 1
        assertions.append(
            EvalCaseAssertion(
                id: "\(kind)-\(sequence)",
                kind: kind,
                pass: pass,
                detail: detail
            )
        )
    }

    public mutating func check(
        _ ok: Bool,
        pass: String,
        fail: String,
        kind: String = "check"
    ) {
        record(kind: kind, pass: ok, detail: ok ? pass : fail)
    }
}
