//
//  NativeCapabilityRequestView.swift
//  osaurus
//
//  Inline enable card for a `request_capability` tool call: the model
//  asked the user to switch on a dormant capability, and this card is the
//  consent moment. One-toggle cases enable in place (same AgentManager
//  path as the settings switch); setup cases deep-link into the exact
//  settings tab. Mirrors NativeEmptyResponseNoticeView's single-row
//  notice-with-button layout so it reads as chat furniture, not a modal.
//

import AppKit
import SwiftUI

final class NativeCapabilityRequestView: NSView {

    static let cardHeight: CGFloat = 44

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    private var kind: DormantCapability.Kind = .tools
    private var agentId: UUID = Agent.defaultId
    private var resolvedAction: CapabilityRequestActions.Action = .alreadyEnabled
    /// Last configure inputs, kept so the `.agentUpdated` observer can
    /// re-resolve the affordance in place (the cell doesn't reconfigure on
    /// settings changes — the block's Equatable payload is unchanged).
    private var lastPayload: RequestCapabilityTool.Payload?
    private var lastTheme: (any ThemeProtocol)?
    // `nonisolated(unsafe)`: deinit is nonisolated and must remove the
    // block observer; NotificationCenter add/remove are thread-safe and
    // the token is written once from the MainActor before any read.
    private nonisolated(unsafe) var agentUpdatedObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            label.isEditable = false
        }

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let agentUpdatedObserver {
            NotificationCenter.default.removeObserver(agentUpdatedObserver)
        }
    }

    /// Refresh the card in place when any agent setting changes, so a user
    /// returning from the settings deep-link sees "enabled" / "Retry
    /// request" without waiting for a cell reconfigure. Registered lazily
    /// on first configure (init runs before the card has inputs).
    private func observeAgentUpdatesIfNeeded() {
        guard agentUpdatedObserver == nil else { return }
        agentUpdatedObserver = NotificationCenter.default.addObserver(
            forName: .agentUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let payload = self.lastPayload, let theme = self.lastTheme
                else { return }
                self.configure(payload: payload, agentId: self.agentId, theme: theme)
            }
        }
    }

    func configure(
        payload: RequestCapabilityTool.Payload,
        agentId: UUID,
        theme: any ThemeProtocol
    ) {
        self.kind = payload.capability
        self.agentId = agentId
        self.lastPayload = payload
        self.lastTheme = theme
        observeAgentUpdatesIfNeeded()
        // Re-resolve on every configure so scroll-back reflects the LIVE
        // state — a card enabled last week renders as already-enabled, not
        // as a stale offer.
        resolvedAction = CapabilityRequestActions.resolve(kind: kind, agentId: agentId)

        layer?.backgroundColor = NSColor(theme.accentColor).withAlphaComponent(0.06).cgColor

        let cfg = NSImage.SymbolConfiguration(
            pointSize: CGFloat(theme.captionSize), weight: .medium)
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor(theme.accentColor)

        titleLabel.font = NSFont.systemFont(
            ofSize: CGFloat(theme.captionSize) + 1, weight: .medium)
        titleLabel.textColor = NSColor(theme.primaryText)
        detailLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1)
        detailLabel.textColor = NSColor(theme.tertiaryText)

        apply(action: resolvedAction, reason: payload.reason)
    }

    private var symbolName: String {
        switch kind {
        case .tools: return "wrench.and.screwdriver"
        case .webSearch: return "globe"
        case .image: return "photo"
        case .browserUse: return "safari"
        case .computerUse: return "display"
        case .appleScript: return "applescript"
        case .spawn: return "person.2"
        }
    }

    private func apply(action: CapabilityRequestActions.Action, reason: String?) {
        switch action {
        case .alreadyEnabled:
            titleLabel.stringValue = String(
                format: L("%@ is enabled"), kind.displayName)
            if kind.autoResumesAfterEnable {
                detailLabel.stringValue = L("This capability is ready to use.")
                actionButton.isHidden = true
            } else {
                // Machine-operating capabilities never auto-resume; the
                // explicit go-ahead lives on this button (the session
                // ignores the retry if the conversation has moved on).
                detailLabel.stringValue = L("Ready when you are.")
                actionButton.isHidden = false
                actionButton.title = L("Retry request")
            }

        case .openSettings(_, let buttonTitle):
            titleLabel.stringValue = String(
                format: L("This needs %@"), kind.displayName)
            detailLabel.stringValue =
                reason ?? L("A quick setup step is required first.")
            actionButton.isHidden = false
            actionButton.title = buttonTitle

        case .explainOnly(let message):
            titleLabel.stringValue = String(
                format: L("This needs %@"), kind.displayName)
            detailLabel.stringValue = message
            actionButton.isHidden = true
        }
    }

    @objc private func actionTapped() {
        switch resolvedAction {
        case .alreadyEnabled:
            // "Retry request" for a machine-operating capability.
            NotificationCenter.default.post(
                name: .capabilityRequestRetry,
                object: nil,
                userInfo: [
                    "agentId": agentId.uuidString,
                    "capability": kind.rawValue,
                ]
            )
        case .openSettings(let tab, _):
            CapabilityRequestActions.openSettings(
                tab: tab, agentId: agentId, highlighting: kind)
        case .explainOnly:
            break
        }
    }
}
