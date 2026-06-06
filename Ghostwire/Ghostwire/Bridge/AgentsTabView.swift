import SwiftUI

struct AgentsTabView: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var bridge = GhostwireSessionBridge.shared
    @ObservedObject private var panelVM = GhostwireSessionBridge.shared.panelViewModel
    @ObservedObject private var usageService = UsageService.shared
    @ObservedObject private var codexUsageService = CodexUsageService.shared
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false
    /// GW-151: which agent's usage detail replaces the sessions list (nil = list)
    @State private var usageDetailAgent: String?
    /// GW-151: meter slot order - first agent to come alive keeps slot 1
    @State private var agentOrder: [String] = []

    private var isInChat: Bool {
        if case .chat = panelVM.contentType { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if isInChat, case .chat(let session) = panelVM.contentType {
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: bridge.sessionMonitor,
                    viewModel: panelVM
                )
                .onHover { hovering in
                    updateSuppression(for: hovering)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                homeContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isInChat)
        .onDisappear {
            updateSuppression(for: false)
            panelVM.saveChatState()
            panelVM.exitChat()
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = usageDetailAgent, let display = usageDisplay(for: agent) {
                // GW-203: per-model weeklies + extra-usage spend ride the
                // display enum's .quota case - no agent-name gate, no reach
                // into UsageService.usage. The detail view reads them off
                // `display` directly (same path for any agent / GW-200 Codex).
                AgentUsageDetailView(
                    agent: agent,
                    display: display
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { usageDetailAgent = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                usageSummaryRow

                // GW-207: the alert history rides BELOW the live session rows,
                // inside ClaudeInstancesView's own scroll — reachable only by
                // scrolling past the present into the past. The quick view
                // spends zero pixels on alerts (no footer, no overlay).
                ClaudeInstancesView(
                    sessionMonitor: bridge.sessionMonitor,
                    viewModel: panelVM
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
        .onHover { hovering in
            updateSuppression(for: hovering)
        }
        .onAppear { syncAgentOrder() }
        .onChange(of: claudeMeterVisible) { _ in syncAgentOrder() }
        .onChange(of: codexMeterVisible) { _ in syncAgentOrder() }
    }

    // MARK: - GW-151 usage meters

    /// Visibility = data source rule (GW-151): OAuth quota is server truth
    /// (accurate even while idle) → pinned whenever configured. API-key
    /// spend is locally derived → ages out like Codex: live session or
    /// token activity within 5h.
    private var claudeMeterVisible: Bool {
        guard usageService.isAvailable, let display = usageService.display else { return false }
        switch display {
        case .quota:
            return true
        case .tokens(let tokens):
            if sessions.contains(where: { ($0.agent ?? "claude") == "claude" }) { return true }
            return tokens.hasRecentActivity
        }
    }

    /// Codex meter shows only when relevant: a live Codex session in the
    /// notch, or rollout activity within the current 5H window.
    private var codexMeterVisible: Bool {
        guard codexUsageService.display != nil else { return false }
        if sessions.contains(where: { $0.agent == "codex" }) { return true }
        return AgentActivity.isRecent(codexUsageService.lastActivityDate)
    }

    private func usageDisplay(for agent: String) -> AgentUsageDisplay? {
        agent == "codex" ? codexUsageService.display : usageService.display
    }

    /// First agent to come alive keeps slot 1; slots never reshuffle while
    /// both meters are visible.
    private func syncAgentOrder() {
        for agent in ["claude", "codex"] {
            let visible = agent == "claude" ? claudeMeterVisible : codexMeterVisible
            if visible && !agentOrder.contains(agent) {
                agentOrder.append(agent)
            }
        }
        agentOrder.removeAll { agent in
            agent == "claude" ? !claudeMeterVisible : !codexMeterVisible
        }
    }

    private var visibleAgents: [String] {
        agentOrder.filter { usageDisplay(for: $0) != nil }
    }

    @ViewBuilder
    private var usageSummaryRow: some View {
        let agents = visibleAgents
        if agents.count == 1, let display = usageDisplay(for: agents[0]) {
            // Single agent → today's exact layout: Session left, Weekly right
            singleAgentRow(agent: agents[0], display: display)
        } else if agents.count > 1 {
            // Both agents → per-agent 5H bars, slot-stable, identity-tinted
            HStack(spacing: 12) {
                ForEach(agents, id: \.self) { agent in
                    if let display = usageDisplay(for: agent) {
                        agentSummaryBar(agent: agent, display: display)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // Label = timeframe, color = agent identity (matches the session-row
    // badge tint), number = usage. Names never appear - once you know the
    // color, you know.

    @ViewBuilder
    private func singleAgentRow(agent: String, display: AgentUsageDisplay) -> some View {
        let tint = AgentIdentity.tint(for: agent)
        switch display {
        case .quota(let fiveHour, let sevenDay, _, _):
            HStack(spacing: 12) {
                if let fh = fiveHour {
                    meterButton(agent: agent) {
                        UsageBar(
                            label: "Session",
                            percent: fh.utilization / 100,
                            detail: "\(Int(fh.utilization))%",
                            color: thresholdColor(fh.utilization, base: tint)
                        )
                    }
                    .help(Self.quotaHelp(own: fh, ownVerbose: true, sibling: nil))
                }
                if let sd = sevenDay {
                    meterButton(agent: agent) {
                        UsageBar(
                            label: "Weekly",
                            percent: sd.utilization / 100,
                            detail: "\(Int(sd.utilization))%",
                            color: thresholdColor(sd.utilization, base: tint)
                        )
                    }
                    .help(Self.quotaHelp(own: sd, ownVerbose: false, sibling: nil))
                }
            }
            .padding(.horizontal, 8)
        case .tokens(let tokens):
            tokenBar(agent: agent, tokens: tokens)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func agentSummaryBar(agent: String, display: AgentUsageDisplay) -> some View {
        switch display {
        case .quota(let fiveHour, let sevenDay, _, _):
            // Session normally; switches to Weekly when 7D >=90% (the
            // binding constraint) - the label names the window on screen
            if let selection = UsageFormat.quotaBarSelection(fiveHour: fiveHour, sevenDay: sevenDay) {
                let isWeekly = selection.label == "Weekly"
                meterButton(agent: agent) {
                    UsageBar(
                        label: selection.label,
                        percent: selection.period.utilization / 100,
                        detail: "\(Int(selection.period.utilization))%",
                        color: thresholdColor(selection.period.utilization, base: AgentIdentity.tint(for: agent))
                    )
                }
                // Dual mode hides the other window's bar - the tooltip
                // carries it as the sibling (e.g. "2h 45m · 41% Tue")
                .help(Self.quotaHelp(
                    own: selection.period,
                    ownVerbose: !isWeekly,
                    sibling: isWeekly ? fiveHour : sevenDay
                ))
            }
        case .tokens(let tokens):
            tokenBar(agent: agent, tokens: tokens)
        }
    }

    /// Hover precision for quota bars: only numbers the glance can't show -
    /// own reset time, plus the hidden sibling window's "% reset" in dual
    /// mode. Session gets verbose time ("2h 45m" - the payload); weekly
    /// resets get the compact day ("Tue"), which itself implies weekly.
    /// e.g. "2h 45m · 41% Tue"
    private static func quotaHelp(own: QuotaPeriod, ownVerbose: Bool, sibling: QuotaPeriod?) -> String {
        var parts: [String] = []
        if let resetsAt = own.resetsAt {
            parts.append(ownVerbose ? UsageFormat.resetTime(resetsAt) : UsageFormat.resetTimeCompact(resetsAt))
        }
        if let sibling {
            var part = "\(Int(sibling.utilization))%"
            if let resetsAt = sibling.resetsAt {
                part += " \(UsageFormat.resetTimeCompact(resetsAt))"
            }
            parts.append(part)
        }
        return parts.joined(separator: " · ")
    }

    /// API auth: disabled-button treatment - the track carries the agent
    /// tint dimly (identity without implying a level); no fill until
    /// GW-144 ships user-set spend limits to fill against.
    /// Label system: one word naming the measure (Session/Weekly/Spend, same
    /// register as the Buddi-inherited quota labels); the trailing-7d window
    /// lives in the tooltip + detail view, not the label.
    private func tokenBar(agent: String, tokens: AgentTokenDisplay) -> some View {
        let tint = AgentIdentity.tint(for: agent)
        return meterButton(agent: agent) {
            UsageBar(
                label: "Spend",
                percent: 0,
                detail: UsageFormat.tokenSummary(tokens),
                color: tint,
                trackColor: tint.opacity(0.18)
            )
        }
        .help("API · 7d")
    }

    /// Click target wrapper: whole bar tappable → that agent's detail view.
    /// Vertical padding fattens the hover/click target (the bar block alone
    /// is ~20pt tall, which reads as a tiny tooltip target).
    private func meterButton<Content: View>(agent: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { usageDetailAgent = agent }
        } label: {
            content()
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thresholdColor(_ utilization: Double, base: Color) -> Color {
        utilization > 80 ? .red : utilization > 60 ? .yellow : base
    }

    private var sessions: [SessionState] { bridge.sessionMonitor.instances }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

struct UsageBar: View {
    let label: String
    let percent: Double
    let detail: String
    let color: Color
    /// GW-151: track override - API (token-mode) bars dim-tint the track
    /// itself for identity (disabled-button treatment, no level implied)
    var trackColor: Color = Color.white.opacity(0.08)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(trackColor)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        // Clamp both ends: extra_usage utilization can exceed
                        // 100 when the user overruns the monthly cap - the
                        // fill must not bleed past the track (review GW-201)
                        .frame(width: geo.size.width * min(1, max(0, percent)))
                }
            }
            .frame(height: 4)
        }
    }
}
