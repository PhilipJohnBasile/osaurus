//
//  OnboardingCard.swift
//  osaurus
//
//  A self-paced feature-discovery card shown at the top of the chat
//  sidebar. Onboarding stays short (it optimizes for activation); this
//  card lives outside that flow and nudges new users toward the rich,
//  buried feature set (voice, schedules, memory, plugins) without adding
//  onboarding friction.
//
//  Completion is *state-derived*: a step is "done" when the feature has
//  actually been configured/used (a model downloaded, a schedule created,
//  a memory written, a plugin installed) — not merely visited. That makes
//  progress honest and self-maintaining, and it doubles as a power-user
//  filter: someone who already set everything up never gets nagged.
//

import AppKit
import Aptabase
import SwiftUI

// MARK: - Steps

/// The features the guide surfaces, in display order. Each step maps to a
/// dino mascot (the "collect-all-the-dinos" progress motif) and a deep-link
/// into the management window.
enum FeatureGuideStep: String, CaseIterable, Identifiable {
    case voice
    case schedules
    case memory
    case plugins

    var id: String { rawValue }

    /// English source string; rendered via `LocalizedStringKey(_, bundle: .module)`.
    var title: String {
        switch self {
        case .voice: return "Give it a voice"
        case .schedules: return "Schedule a task"
        case .memory: return "Add a memory"
        case .plugins: return "Install a plugin"
        }
    }

    var subtitle: String {
        switch self {
        case .voice: return "Speak and listen with TTS & STT"
        case .schedules: return "Run agents on a schedule"
        case .memory: return "Let it remember across chats"
        case .plugins: return "Extend it with integrations"
        }
    }

    /// Each step gets its own colored dino, greyed-out until complete.
    var mascot: AgentMascot {
        switch self {
        case .voice: return .purple
        case .schedules: return .orange
        case .memory: return .blue
        case .plugins: return .green
        }
    }

    var tab: ManagementTab {
        switch self {
        case .voice: return .voice
        case .schedules: return .schedules
        case .memory: return .memory
        case .plugins: return .plugins
        }
    }

    /// Primary call-to-action label on the spotlight card.
    var cta: String {
        switch self {
        case .voice: return "Set up voice"
        case .schedules: return "Create a schedule"
        case .memory: return "Open memory"
        case .plugins: return "Browse plugins"
        }
    }

    /// Sets any one-shot sub-tab focus request before the window opens.
    @MainActor
    func applyDeepLink() {
        switch self {
        case .voice:
            // VoiceTab.textToSpeech.rawValue — land on the TTS pane.
            ManagementStateManager.shared.voiceSubTabRequest = "Text To Speech"
        case .schedules, .memory, .plugins:
            break
        }
    }
}

// MARK: - Model

/// Shared, app-wide state for the feature guide. Owns the derived
/// completion set, dismissal, and expand/collapse — all chat windows
/// observe the same instance so the guide stays consistent.
@MainActor
final class FeatureGuideModel: ObservableObject {
    static let shared = FeatureGuideModel()

    @Published private(set) var completed: Set<FeatureGuideStep> = []
    @Published var isDismissed: Bool

    private let dismissedKey = "featureGuide_dismissed"
    private let enrolledKey = "featureGuide_enrolled"

    /// Memory is the one signal without a synchronous/observable source, so
    /// it's resolved asynchronously and merged in. `memoryEvaluated` gates
    /// enrollment until we've seen the full picture once.
    private var memoryComplete = false
    private var memoryEvaluated = false

    private var observers: [NSObjectProtocol] = []
    private var didFireViewed = false
    private var didFireCompleted = false

    private init() {
        let defaults = UserDefaults.standard
        self.isDismissed = defaults.bool(forKey: dismissedKey)
        registerObservers()
        recompute()
        refreshMemory()
    }

    // MARK: Visibility

    /// Hidden once dismissed, and never shown during onboarding (or a
    /// version-bump re-onboarding) so the two surfaces don't overlap.
    var isVisible: Bool {
        // TEMPORARY (dev): force the card on for testing regardless of
        // dismissal / onboarding state. Set `forceShowForTesting` to false
        // (or `return gated`) to restore real gating once development is done.
        let forceShowForTesting = true
        let gated = !isDismissed && !OnboardingService.shared.shouldShowOnboarding
        return forceShowForTesting || gated
    }

    var total: Int { FeatureGuideStep.allCases.count }
    var completedCount: Int { completed.count }
    var allComplete: Bool { completedCount >= total }

    func isComplete(_ step: FeatureGuideStep) -> Bool { completed.contains(step) }

    // MARK: Actions

    func navigate(_ step: FeatureGuideStep) {
        FeatureGuideTelemetry.stepClicked(step)
        step.applyDeepLink()
        AppDelegate.shared?.showManagementWindow(initialTab: step.tab)
    }

    func dismiss(via: String, silent: Bool = false) {
        guard !isDismissed else { return }
        isDismissed = true
        UserDefaults.standard.set(true, forKey: dismissedKey)
        if !silent {
            FeatureGuideTelemetry.dismissed(via: via, completedCount: completedCount, total: total)
        }
    }

    /// Fires the "viewed" funnel event the first time the card is shown.
    func notifyViewedIfNeeded() {
        guard isVisible, !didFireViewed else { return }
        didFireViewed = true
        FeatureGuideTelemetry.viewed(completedCount: completedCount, total: total)
    }

    func refresh() {
        recompute()
        refreshMemory()
    }

    // MARK: Derivation

    private func recompute() {
        var done: Set<FeatureGuideStep> = []
        if isVoiceConfigured { done.insert(.voice) }
        if !ScheduleManager.shared.schedules.isEmpty { done.insert(.schedules) }
        if !PluginManager.shared.plugins.isEmpty { done.insert(.plugins) }
        if memoryComplete { done.insert(.memory) }
        completed = done
        enrollIfNeeded()
        maybeFireCompleted()
    }

    /// True once the user has actually set up either side of voice — a TTS
    /// model is loaded, or at least one speech (STT) model is downloaded.
    /// Deliberately does NOT key off `TTSConfiguration.enabled`, which
    /// defaults to `true` for fresh installs and would falsely read as done.
    private var isVoiceConfigured: Bool {
        if TTSService.shared.modelState == .ready { return true }
        if SpeechModelManager.shared.downloadedModelsCount > 0 { return true }
        return false
    }

    private func refreshMemory() {
        Task { [weak self] in
            let count = (try? await Self.memoryEpisodeCount()) ?? 0
            guard let self else { return }
            let newValue = count > 0
            let firstEval = !self.memoryEvaluated
            self.memoryEvaluated = true
            if newValue != self.memoryComplete || firstEval {
                self.memoryComplete = newValue
                self.recompute()
            }
        }
    }

    private static func memoryEpisodeCount() async throws -> Int {
        // The memory DB isn't main-actor isolated; count off the main thread.
        try await Task.detached(priority: .utility) {
            try MemoryDatabase.shared.episodeCount()
        }.value
    }

    /// One-time enrollment. Runs once we've evaluated every signal (incl.
    /// memory). If the user already has all four features set up, they're a
    /// power user who never asked for a guide — dismiss silently so the card
    /// never appears for them.
    private func enrollIfNeeded() {
        guard memoryEvaluated else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: enrolledKey) else { return }
        defaults.set(true, forKey: enrolledKey)
        if completedCount >= total {
            dismiss(via: "auto_all_complete", silent: true)
        }
    }

    private func maybeFireCompleted() {
        guard allComplete, !didFireCompleted, !isDismissed else { return }
        didFireCompleted = true
        FeatureGuideTelemetry.completed()
    }

    // MARK: Observation

    /// Refresh on the cheap change signals we have, plus whenever a window
    /// regains key — that covers the common loop of jumping to a settings
    /// pane, configuring a feature, and returning to the chat window.
    private func registerObservers() {
        let names: [Notification.Name] = [
            .ttsConfigurationChanged,
            .schedulesChanged,
            NSWindow.didBecomeKeyNotification,
        ]
        let center = NotificationCenter.default
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
    }
    // No deinit cleanup: this is an app-lifetime singleton, so the observers
    // live as long as the process and never need removing.
}

// MARK: - Telemetry

/// Mirrors `OnboardingTelemetry` — keeps the `feature_guide_*` funnel names
/// next to the UI they describe. Events buffer until consent is decided,
/// same as the rest of the funnel.
@MainActor
enum FeatureGuideTelemetry {
    static func viewed(completedCount: Int, total: Int, service: TelemetryService = .shared) {
        service.track("feature_guide_viewed", ["completed": completedCount, "total": total])
    }

    static func stepClicked(_ step: FeatureGuideStep, service: TelemetryService = .shared) {
        service.track("feature_guide_step_clicked", ["step": step.rawValue])
    }

    static func completed(service: TelemetryService = .shared) {
        service.track("feature_guide_completed")
    }

    static func dismissed(
        via: String,
        completedCount: Int,
        total: Int,
        service: TelemetryService = .shared
    ) {
        service.track(
            "feature_guide_dismissed",
            ["via": via, "completed": completedCount, "total": total]
        )
    }
}

// MARK: - Card

/// Paged feature-spotlight card. Each page is one feature: its dino mascot
/// (top-right), title + subtitle (left), and a CTA (bottom-right) that
/// deep-links into the feature. Page dots sit bottom-left; swipe or tap a
/// dot to move between features. Renders nothing (and contributes no
/// layout) when the guide isn't visible, so the sidebar reflows cleanly.
struct OnboardingCard: View {
    @ObservedObject private var model = FeatureGuideModel.shared
    @Environment(\.theme) private var theme

    @State private var page = 0
    @State private var slideForward = true
    @State private var didInitPage = false

    private let steps = FeatureGuideStep.allCases
    private let cardHeight: CGFloat = 162

    private var currentStep: FeatureGuideStep { steps[min(page, steps.count - 1)] }

    var body: some View {
        if model.isVisible {
            card
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .onAppear {
                    model.refresh()
                    model.notifyViewedIfNeeded()
                    initPageIfNeeded()
                }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageContent(currentStep)
                .id(currentStep)
                .transition(slideTransition)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            bottomBar
        }
        .frame(height: cardHeight, alignment: .top)
        .overlay(alignment: .topTrailing) { dismissButton }
        .padding(14)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(currentStep.mascot.color.opacity(theme.isDark ? 0.4 : 0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(theme.isDark ? 0.3 : 0.1), radius: 10, y: 4)
        // Pill straddles the top edge — added after the clip so it isn't trimmed.
        .overlay(alignment: .top) { headerPill.offset(y: -11) }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width < -40 {
                        goTo(page + 1)
                    } else if value.translation.width > 40 {
                        goTo(page - 1)
                    }
                }
        )
    }

    private var headerPill: some View {
        Text("Get the most out of Osaurus", bundle: .module)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(pillBackground)
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.35 : 0.12), radius: 5, y: 2)
    }

    /// Frosted glass with a faint accent tint so the pill stays on-brand.
    /// A fully opaque base sits behind the glass so nothing behind the pill
    /// (notably the card's top border, which the pill straddles) bleeds
    /// through the translucent material.
    @ViewBuilder
    private var pillBackground: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(theme.secondaryBackground)
            if theme.glassEnabled {
                ThemedGlassSurface(cornerRadius: 12)
            }
            Capsule(style: .continuous)
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
        }
    }

    /// Liquid-glass card surface, with a solid fallback for non-glass themes.
    @ViewBuilder
    private var cardBackground: some View {
        if theme.glassEnabled {
            ThemedGlassSurface(cornerRadius: 14)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.5 : 0.65))
        }
    }

    // MARK: Page content

    private func pageContent(_ step: FeatureGuideStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                mascot(step)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(step.title), bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(step.subtitle), bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
    }

    private func mascot(_ step: FeatureGuideStep) -> some View {
        Image(step.mascot.assetName, bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 50, height: 50)
            .overlay(alignment: .bottomTrailing) {
                if model.isComplete(step) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.successColor)
                        .background(Circle().fill(theme.primaryBackground))
                }
            }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            pageDots
            Spacer(minLength: 8)
            actionButton
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                Button { goTo(index) } label: {
                    Capsule(style: .continuous)
                        .fill(dotColor(isCurrent: index == page, done: model.isComplete(step)))
                        .frame(width: index == page ? 16 : 6, height: 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(theme.animationQuick(), value: page)
    }

    private func dotColor(isCurrent: Bool, done: Bool) -> Color {
        if isCurrent { return theme.accentColor }
        if done { return theme.successColor.opacity(0.7) }
        return theme.secondaryText.opacity(0.3)
    }

    private var actionButton: some View {
        let step = currentStep
        let done = model.isComplete(step)
        return Button { model.navigate(step) } label: {
            HStack(spacing: 5) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(LocalizedStringKey(done ? "Open" : step.cta), bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                if !done {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundColor(done ? theme.successColor : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(done ? theme.successColor.opacity(0.15) : step.mascot.color)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var dismissButton: some View {
        Button { model.dismiss(via: "user") } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Paging

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func goTo(_ newPage: Int) {
        let clamped = max(0, min(steps.count - 1, newPage))
        guard clamped != page else { return }
        slideForward = clamped > page
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            page = clamped
        }
    }

    /// Open on the first feature the user hasn't explored yet (the natural
    /// "next" nudge), once per appearance.
    private func initPageIfNeeded() {
        guard !didInitPage else { return }
        didInitPage = true
        if let idx = steps.firstIndex(where: { !model.isComplete($0) }) {
            page = idx
        }
    }
}
