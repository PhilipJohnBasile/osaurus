// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Image generation bridge contract")
struct ImageGenerationBridgeContractTests {

    /// True when a `Package.resolved` pins `revision` — regardless of how
    /// SwiftPM spaced the JSON. Collapsing whitespace keeps the assertion
    /// about the PIN rather than about the serializer's formatting.
    private func pins(_ resolvedJSON: String, to revision: String) -> Bool {
        let compact = resolvedJSON.filter { !$0.isWhitespace }
        return compact.contains("\"revision\":\"\(revision)\"")
    }

    @Test("image models route through the image-generation picker source")
    func imageModelPickerItemUsesImageGenerationSource() {
        let model = ImageModelInfo(
            id: "Qwen-Image-Edit-mflux-q8",
            canonicalName: "qwen-image-edit",
            displayName: "Qwen Image Edit q8",
            kind: "imageEdit",
            ready: true,
            quantizationBits: 8,
            defaultSteps: 20,
            defaultGuidance: 4.0,
            capabilities: ImageModelCapabilities(imageEdit: true, multipleSourceImages: true),
            blockedReasons: [],
            totalBytes: 42
        )

        let item = ModelPickerItem.fromImageModel(model)

        #expect(item.id == "Qwen-Image-Edit-mflux-q8")
        #expect(item.displayName == "Qwen Image Edit q8")
        #expect(item.quantization == "8-bit")
        #expect(item.source.isImageGeneration)
        #expect(item.source.displayName == "Image Models")
    }

    @Test("source wiring keeps vMLXFlux bridge, routes, Metal gate, and proven revision")
    func sourceContractMatchesProvenVMLXRevision() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot =
            coreRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let packageSwift = try String(
            contentsOf: coreRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime/ImageGenerationService.swift"),
            encoding: .utf8
        )
        let gate = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime/MetalGate.swift"),
            encoding: .utf8
        )
        let handler = try String(
            contentsOf: coreRoot.appendingPathComponent("Networking/HTTPHandler.swift"),
            encoding: .utf8
        )
        let packageResolved = try String(
            contentsOf: coreRoot.appendingPathComponent("Package.resolved"),
            encoding: .utf8
        )
        let workspaceResolved = try String(
            contentsOf: repoRoot.appendingPathComponent("osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
            encoding: .utf8
        )
        let appResolved = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            ),
            encoding: .utf8
        )

        let expectedRevision = "2fc5d7bbf2a5baa7868a24631c8d47632c23a9b7"
        #expect(packageSwift.contains(#"revision: "\#(expectedRevision)""#))
        // Whitespace-insensitive, because the literal spacing is SwiftPM's to
        // choose and not part of the contract. `Package.resolved` used to be
        // written as `"revision" : "…"` and is now written `"revision": "…"`;
        // an exact-string assertion failed on all three files while every pin
        // was in fact correct, which reads as a bad repin and is not one.
        // What this test exists to catch — the pin sites disagreeing — is
        // fully preserved.
        #expect(pins(packageResolved, to: expectedRevision))
        #expect(pins(workspaceResolved, to: expectedRevision))
        #expect(pins(appResolved, to: expectedRevision))
        #expect(service.contains("import vMLXFlux"))
        #expect(service.contains("await MetalGate.shared.enterImageGeneration()"))
        #expect(service.contains("await MetalGate.shared.exitImageGeneration()"))
        #expect(gate.contains("public func enterImageGeneration() async"))
        #expect(gate.contains("public func exitImageGeneration()"))
        #expect(handler.contains(#"path == "/images/models""#))
        #expect(handler.contains(#"path == "/images/generations""#))
        #expect(handler.contains(#"path == "/images/edits""#))
        #expect(handler.contains(#"path == "/images/upscale""#))
        #expect(handler.contains(#"path == "/images/cancel""#))
    }
}
