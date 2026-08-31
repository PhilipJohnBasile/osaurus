//
//  RunCenterView.swift
//  osaurus
//
//  Native read-only operator surface over the existing durable run ledger.
//

import SwiftUI

struct RunCenterView: View {
    @Environment(\.theme) private var theme
    @StateObject private var viewModel: RunCenterViewModel

    init(viewModel: @autoclosure @escaping () -> RunCenterViewModel = RunCenterViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        Group {
            if viewModel.selectedRunId != nil {
                detailSurface
            } else {
                boardSurface
            }
        }
        .background(theme.primaryBackground)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var boardSurface: some View {
        VStack(spacing: 0) {
            ManagerHeaderWithActions(
                title: "Run Center",
                subtitle: "Durable execution state across agents and projects",
                count: viewModel.board?.cards.count
            ) {
                needsYouBadge
                HeaderIconButton(
                    "arrow.clockwise",
                    isLoading: viewModel.isLoading,
                    help: "Refresh Run Center"
                ) {
                    viewModel.refresh()
                }
                .accessibilityIdentifier("run-center-refresh")
            }

            Divider().opacity(0.35)

            if viewModel.isLoading, viewModel.board == nil {
                runCenterLoadingState
            } else if let error = viewModel.errorMessage, viewModel.board == nil {
                runCenterErrorState(message: error)
            } else if let board = viewModel.board,
                board.cards.isEmpty,
                board.unavailableCards.isEmpty
            {
                runCenterEmptyState
            } else if let board = viewModel.board {
                VStack(spacing: 0) {
                    if let error = viewModel.errorMessage {
                        inlineRefreshError(error)
                    }
                    if !board.unavailableCards.isEmpty {
                        unreadableRuns(board.unavailableCards)
                    }
                    runBoard(board)
                }
            }
        }
        .accessibilityIdentifier("run-center-board")
    }

    private var needsYouBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
            Text("Needs You", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: "\(viewModel.needsYouCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.warningColor.opacity(0.18)))
        }
        .foregroundColor(viewModel.needsYouCount > 0 ? theme.warningColor : theme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
        )
        .accessibilityIdentifier("run-center-needs-you-count")
    }

    private func runBoard(_ board: RunCenterBoardReadModel) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RunCenterLane.allCases, id: \.self) { lane in
                    RunCenterLaneColumn(
                        lane: lane,
                        cards: board.cards(in: lane),
                        onSelect: viewModel.select
                    )
                    .frame(width: 260)
                    .accessibilityIdentifier("run-center-lane-\(lane.rawValue)")
                }
            }
            .padding(20)
        }
    }

    private func unreadableRuns(_ issues: [RunCenterProjectionIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Unreadable runs", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: "\(issues.count)")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
            }
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: runTitle(issue.run))
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: issue.message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
            }
        }
        .foregroundColor(theme.errorColor)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.errorColor.opacity(0.24), lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .accessibilityIdentifier("run-center-unreadable-runs")
    }

    private func inlineRefreshError(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(verbatim: message)
                .lineLimit(2)
            Spacer()
            Button(localized: "Retry") { viewModel.refresh() }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
        }
        .font(.system(size: 12))
        .foregroundColor(theme.errorColor)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(theme.errorColor.opacity(0.07))
    }

    private var detailSurface: some View {
        VStack(spacing: 0) {
            detailSurfaceContent
        }
        .accessibilityIdentifier("run-center-detail")
    }

    @ViewBuilder
    private var detailSurfaceContent: some View {
        if let detail = viewModel.detail {
            RunCenterDetailHeader(
                detail: detail,
                onBack: { viewModel.showBoard() },
                onOpenConversation: detail.card.run.sessionId == nil
                    ? nil
                    : { viewModel.openConversation() }
            )
            Divider().opacity(0.35)
            RunCenterDetailContent(
                detail: detail,
                conversationError: viewModel.conversationErrorMessage
            )
        } else {
            AgentDetailHeaderBar(
                onBack: { viewModel.showBoard() },
                backTitle: "Run Center"
            ) {
                Text("Run detail", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            } status: {
                EmptyView()
            } actions: {
                EmptyView()
            }
            Divider().opacity(0.35)
            if viewModel.isDetailLoading {
                runCenterLoadingState
            } else {
                runCenterErrorState(
                    message: viewModel.errorMessage ?? L("Run detail is unavailable")
                )
            }
        }
    }

    private var runCenterLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Reading durable run history…", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runCenterEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("No runs yet", bundle: .module)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Executions will appear here as durable lifecycle facts are recorded.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runCenterErrorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(theme.errorColor)
            Text("Run Center is unavailable", bundle: .module)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(verbatim: message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button(localized: "Retry") { viewModel.refresh() }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RunCenterLaneColumn: View {
    @Environment(\.theme) private var theme

    let lane: RunCenterLane
    let cards: [RunCenterBoardCard]
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(laneColor)
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(lane.title), bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text(verbatim: "\(cards.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.tertiaryBackground))
            }

            if cards.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: lane.icon)
                        .font(.system(size: 18, weight: .light))
                    Text("No runs", bundle: .module)
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder.opacity(0.7), style: StrokeStyle(dash: [4, 4]))
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 9) {
                        ForEach(cards) { card in
                            Button {
                                onSelect(card.id)
                            } label: {
                                RunCenterCardView(card: card, laneColor: laneColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("run-center-card-\(card.id.uuidString)")
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.primaryBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var laneColor: Color {
        switch lane {
        case .working: theme.accentColor
        case .needsYou: theme.warningColor
        case .inReview: theme.warningColor
        case .proven: theme.successColor
        case .done: theme.secondaryText
        case .failed: theme.errorColor
        }
    }
}

private struct RunCenterCardView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let card: RunCenterBoardCard
    let laneColor: Color

    var body: some View {
        SimpleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: runTitle(card.run))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    Circle().fill(card.hasPartialAggregate ? theme.warningColor : laneColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                }

                if let attention = card.attention {
                    HStack(spacing: 5) {
                        Image(systemName: attention.kind.icon)
                        Text(LocalizedStringKey(attention.kind.title), bundle: .module)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                }

                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                    Text(
                        verbatim: agentManager.agent(for: card.run.agentId)?.name
                            ?? shortId(card.run.agentId)
                    )
                    .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundColor(theme.secondaryText)

                HStack(spacing: 6) {
                    RunCenterMiniPill(text: card.run.triggerKind.displayTitle)
                    if let model = card.run.modelId, !model.isEmpty {
                        RunCenterMiniPill(text: model)
                    }
                }

                HStack(spacing: 5) {
                    if card.run.parentRunId != nil {
                        Image(systemName: "arrow.turn.down.right")
                        Text("Child", bundle: .module)
                    } else if card.linkedChildCount > 0 {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text("\(card.linkedChildCount) children", bundle: .module)
                    }
                    Spacer()
                    Text(verbatim: card.run.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)

                if card.hasPartialAggregate {
                    Text("Partial aggregate: one or more children failed", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.warningColor)
                }
            }
        }
    }
}

private struct RunCenterMiniPill: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.tertiaryBackground))
    }
}

private struct RunCenterDetailHeader: View {
    @Environment(\.theme) private var theme

    let detail: RunCenterDetailReadModel
    let onBack: () -> Void
    let onOpenConversation: (() -> Void)?

    var body: some View {
        AgentDetailHeaderBar(onBack: onBack, backTitle: "Run Center") {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: runTitle(detail.card.run))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(verbatim: shortId(detail.card.run.id))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
        } status: {
            HStack(spacing: 6) {
                if detail.card.hasPartialAggregate {
                    detailPill("Partial", color: theme.warningColor)
                }
                detailPill(detail.card.snapshot.lane.title, color: laneColor)
            }
        } actions: {
            if let onOpenConversation {
                AgentDetailHeaderActionButton(
                    icon: "bubble.left.and.bubble.right",
                    tint: theme.accentColor,
                    help: "Open Conversation",
                    action: onOpenConversation
                )
                .accessibilityIdentifier("run-center-open-conversation")
            }
        }
    }

    private var laneColor: Color {
        switch detail.card.snapshot.lane {
        case .working: theme.accentColor
        case .needsYou, .inReview: theme.warningColor
        case .proven: theme.successColor
        case .done: theme.secondaryText
        case .failed: theme.errorColor
        }
    }

    private func detailPill(_ title: String, color: Color) -> some View {
        Text(LocalizedStringKey(title), bundle: .module)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct RunCenterDetailContent: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared

    let detail: RunCenterDetailReadModel
    let conversationError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summarySection
                lineageSection
                eventsSection
                conversationSection
                traceSection
                availabilitySection
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var summarySection: some View {
        detailSection("Run facts", icon: "list.bullet.rectangle") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                fact("Run ID", shortId(detail.card.run.id))
                fact(
                    "Agent",
                    agentManager.agent(for: detail.card.run.agentId)?.name
                        ?? detail.card.run.agentId.uuidString
                )
                fact("Trigger", detail.card.run.triggerKind.displayTitle)
                fact("Execution", detail.card.snapshot.executionState.displayTitle)
                fact("Evidence", detail.card.snapshot.evidenceState.displayTitle)
                fact("Model", detail.card.run.modelId ?? L("Not captured"))
                fact("Session", detail.card.run.sessionId?.uuidString ?? L("Not linked"))
                fact(
                    "Project",
                    projectManager.project(for: detail.card.run.projectId)?.name
                        ?? detail.card.run.projectId?.uuidString
                        ?? L("Not linked")
                )
                fact("Tokens in", detail.card.run.tokensIn.map(String.init) ?? L("Not captured"))
                fact("Tokens out", detail.card.run.tokensOut.map(String.init) ?? L("Not captured"))
                fact(
                    "Cost",
                    detail.card.run.costUSD.map { String(format: "$%.4f", $0) }
                        ?? L("Not captured")
                )
                fact("Updated", detail.card.run.updatedAt.formatted(date: .abbreviated, time: .standard))
            }
            if let error = detail.card.run.error, !error.isEmpty {
                availabilityRow("Run error", error, color: theme.errorColor)
            }
        }
    }

    private var lineageSection: some View {
        detailSection("Lineage", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.tree, id: \.id) { run in
                    HStack(spacing: 7) {
                        Image(
                            systemName: run.id == detail.card.run.id
                                ? "circle.inset.filled" : "circle"
                        )
                        .font(.system(size: 9))
                        .foregroundColor(
                            run.id == detail.card.run.id
                                ? theme.accentColor : theme.tertiaryText
                        )
                        Text(verbatim: runTitle(run))
                            .font(
                                .system(
                                    size: 12,
                                    weight: run.id == detail.card.run.id
                                        ? .semibold : .regular
                                )
                            )
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text(verbatim: shortId(run.id))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.leading, CGFloat(lineageDepth(run, in: detail.tree) * 18))
                }
            }
        }
    }

    private var eventsSection: some View {
        detailSection("Events", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.eventStreams) { stream in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Run \(shortId(stream.runId))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                        if stream.events.isEmpty {
                            Text("No event stream", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        } else {
                            ForEach(stream.events) { event in
                                HStack(alignment: .top, spacing: 9) {
                                    Text(verbatim: "#\(event.sequence)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)
                                        .frame(width: 30, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(LocalizedStringKey(event.kind.displayTitle), bundle: .module)
                                                .font(.system(size: 11.5, weight: .semibold))
                                            Spacer()
                                            Text(
                                                verbatim: event.occurredAt.formatted(
                                                    date: .omitted,
                                                    time: .standard
                                                )
                                            )
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                        if let message = event.message, !message.isEmpty {
                                            Text(verbatim: message)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.secondaryText)
                                        }
                                        if !event.metadata.isEmpty {
                                            Text(
                                                verbatim: event.metadata
                                                    .sorted { $0.key < $1.key }
                                                    .map { "\($0.key)=\($0.value)" }
                                                    .joined(separator: "  ")
                                            )
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(theme.tertiaryText)
                                            .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var conversationSection: some View {
        detailSection("Conversation context", icon: "bubble.left.and.bubble.right") {
            if let conversation = detail.conversation {
                VStack(alignment: .leading, spacing: 9) {
                    Text(verbatim: conversation.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "This is the whole canonical conversation and may include turns from other runs.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    ForEach(conversation.turns.suffix(4)) { turn in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: turn.role.capitalized)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                            Text(verbatim: turn.content)
                                .font(.system(size: 11))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(4)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.tertiaryBackground.opacity(0.65))
                        )
                    }
                }
            } else {
                availabilityRow(
                    "Conversation",
                    detail.conversationUnavailableReason ?? L("Unavailable"),
                    color: theme.warningColor
                )
            }
            if let conversationError {
                availabilityRow("Open Conversation", conversationError, color: theme.errorColor)
            }
        }
    }

    private var traceSection: some View {
        detailSection("Run trace and tool activity", icon: "doc.text.magnifyingglass") {
            switch detail.trace {
            case .available(let trace):
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    fact("Trace status", trace.status)
                    fact("Trace turns", String(trace.turnCount))
                    fact("Tool calls", String(trace.toolCallCount))
                    fact("Trace tokens in", trace.tokensIn.map(String.init) ?? L("Not captured"))
                    fact("Trace tokens out", trace.tokensOut.map(String.init) ?? L("Not captured"))
                }
                if !trace.toolNames.isEmpty {
                    Text(verbatim: trace.toolNames.joined(separator: " · "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
            case .missing:
                availabilityRow("Trace", L("No terminal run trace is available"), color: theme.warningColor)
            case .corrupt:
                availabilityRow("Trace", L("The run trace could not be decoded"), color: theme.errorColor)
            case .identityMismatch:
                availabilityRow("Trace", L("The trace identity does not match this run"), color: theme.errorColor)
            }
        }
    }

    private var availabilitySection: some View {
        detailSection("Evidence and runtime coverage", icon: "checklist.unchecked") {
            availabilityRow("Proof", detail.proofAvailability, color: theme.warningColor)
            availabilityRow("Runtime settings", detail.runtimeSettingsAvailability, color: theme.warningColor)
            availabilityRow("Tests and evals", detail.testAndEvalAvailability, color: theme.warningColor)
            availabilityRow("Artifacts", detail.artifactAvailability, color: theme.warningColor)
        }
    }

    private func detailSection<Content: View>(
        _ title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SimpleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .foregroundColor(theme.accentColor)
                    Text(title, bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
                content()
            }
        }
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label, bundle: .module)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Text(verbatim: value)
                .font(.system(size: 11.5))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.tertiaryBackground.opacity(0.6))
        )
    }

    private func availabilityRow(
        _ label: LocalizedStringKey,
        _ message: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label, bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(verbatim: message)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }
}

private extension RunCenterLane {
    var title: String {
        switch self {
        case .working: L("Working")
        case .needsYou: L("Needs You")
        case .inReview: L("In Review")
        case .proven: L("Proven")
        case .done: L("Done")
        case .failed: L("Failed")
        }
    }

    var icon: String {
        switch self {
        case .working: "bolt"
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .inReview: "doc.text.magnifyingglass"
        case .proven: "checkmark.seal"
        case .done: "checkmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}

private extension RunCenterAttentionKind {
    var title: String {
        switch self {
        case .clarification: L("Clarification needed")
        case .approval: L("Approval needed")
        case .readyToResume: L("Ready to resume")
        }
    }

    var icon: String {
        switch self {
        case .clarification: "questionmark.bubble"
        case .approval: "hand.raised"
        case .readyToResume: "play.circle"
        }
    }
}

private extension AgentRunTriggerKind {
    var displayTitle: String {
        switch self {
        case .schedule: L("Self-scheduled")
        case .recurringSchedule: L("Schedule")
        case .watcher: L("Watcher")
        case .user: L("User")
        }
    }
}

private extension RunCenterExecutionState {
    var displayTitle: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

private extension RunCenterEvidenceState {
    var displayTitle: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

private extension RunCenterEventKind {
    var displayTitle: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

private func runTitle(_ run: AgentRunRecord) -> String {
    if let title = run.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        return title
    }
    let firstLine = run.instructions.split(separator: "\n", maxSplits: 1).first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return firstLine?.isEmpty == false ? firstLine! : L("Untitled run")
}

private func shortId(_ id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
}

private func lineageDepth(_ run: AgentRunRecord, in tree: [AgentRunRecord]) -> Int {
    let byId = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0) })
    var depth = 0
    var current = run
    var seen = Set<UUID>()
    while let parentId = current.parentRunId,
        let parent = byId[parentId],
        seen.insert(current.id).inserted
    {
        depth += 1
        current = parent
    }
    return depth
}
